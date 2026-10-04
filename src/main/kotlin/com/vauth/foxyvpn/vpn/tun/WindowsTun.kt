package com.vauth.foxyvpn.vpn.tun

import com.vauth.foxyvpn.data.AppLogger
import com.vauth.foxyvpn.platform.FoxyPaths
import java.io.File
import java.util.UUID

private const val TAG = "WindowsTun"
private const val TASK_NAME = "VulpineVPNHelper"

/**
 * Windows full-tunnel backend. An elevated watcher (a hidden PowerShell loop started
 * through a one-time-registered scheduled task) applies system-wide changes the app
 * cannot do itself: sing-box TUN, bypass host routes and the WinINet/WinHTTP proxy.
 * The task is registered once with a UAC prompt; every later connect is silent.
 */
object WindowsTun {

    private val dir: File get() = FoxyPaths.helperDir
    private val cmdFile get() = File(dir, "cmd")
    private val doneFile get() = File(dir, "cmd.done")
    private val stopFile get() = File(dir, "stop")
    private val startedFile get() = File(dir, "watcher.started")
    private val heartbeatFile get() = File(dir, "heartbeat")
    private val scriptFile get() = File(dir, "foxy-helper.ps1")
    private val registerFile get() = File(dir, "register-task.ps1")
    private val configPathFile get() = File(dir, "current_config")
    private val bypassFile get() = File(dir, "bypass_ips")
    private val addIpsFile get() = File(dir, "add_ips")
    private val proxyPortFile get() = File(dir, "proxy_port")

    @Volatile
    private var promptedForAdmin = false

    // The watcher deletes watcher.started when it exits, so its presence means it runs.
    private fun watcherAlive(): Boolean = startedFile.exists()

    private fun writeScript() {
        val singBox = FoxyPaths.bundledResource("sing-box.exe")?.absolutePath ?: ""
        scriptFile.writeText(
            """
            ${'$'}ErrorActionPreference='SilentlyContinue'
            ${'$'}DIR = '${dir.absolutePath}'
            ${'$'}SINGBOX = '$singBox'
            ${'$'}TUNADDR = '${WindowsTunConfig.TUN_ADDRESS}'

            function Find-Gateway {
              ${'$'}r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
              if (${'$'}r) { return @(${'$'}r.NextHop, ${'$'}r.InterfaceIndex) }
              return @(${'$'}null, ${'$'}null)
            }

            function Add-Bypass([string[]]${'$'}ips) {
              ${'$'}g = Find-Gateway
              if (-not ${'$'}g[0]) { return }
              foreach (${'$'}ip in ${'$'}ips) {
                if (-not ${'$'}ip) { continue }
                New-NetRoute -DestinationPrefix "${'$'}ip/32" -NextHop ${'$'}g[0] -InterfaceIndex ${'$'}g[1] -ErrorAction SilentlyContinue | Out-Null
                Add-Content -Path "${'$'}DIR\added_routes" -Value ${'$'}ip
              }
            }

            function Remove-Bypass {
              if (-not (Test-Path "${'$'}DIR\added_routes")) { return }
              foreach (${'$'}ip in (Get-Content "${'$'}DIR\added_routes")) {
                Remove-NetRoute -DestinationPrefix "${'$'}ip/32" -Confirm:${'$'}false -ErrorAction SilentlyContinue
              }
              Remove-Item "${'$'}DIR\added_routes" -Force
            }

            function Stop-Tun {
              if (Test-Path "${'$'}DIR\singbox.pid") {
                Stop-Process -Id (Get-Content "${'$'}DIR\singbox.pid") -Force -ErrorAction SilentlyContinue
                Remove-Item "${'$'}DIR\singbox.pid" -Force
              }
              foreach (${'$'}r in (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)) {
                ${'$'}ours = Get-NetIPAddress -InterfaceIndex ${'$'}r.InterfaceIndex -ErrorAction SilentlyContinue | Where-Object { ${'$'}_.IPAddress -eq ${'$'}TUNADDR }
                if (${'$'}ours) { Remove-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex ${'$'}r.InterfaceIndex -Confirm:${'$'}false -ErrorAction SilentlyContinue }
              }
              Remove-Bypass
            }

            function Start-Tun {
              Stop-Tun
              Start-Sleep -Seconds 1
              ${'$'}ips = @()
              if (Test-Path "${'$'}DIR\bypass_ips") { ${'$'}ips = @(Get-Content "${'$'}DIR\bypass_ips") }
              Add-Bypass ${'$'}ips
              ${'$'}cfg = (Get-Content "${'$'}DIR\current_config") -join ''
              if (${'$'}cfg -and (Test-Path ${'$'}cfg) -and (Test-Path ${'$'}SINGBOX)) {
                ${'$'}p = Start-Process -FilePath ${'$'}SINGBOX -ArgumentList 'run','-c',${'$'}cfg -WindowStyle Hidden -PassThru
                ${'$'}p.Id | Set-Content "${'$'}DIR\singbox.pid"
              }
            }

            function Set-Proxy([bool]${'$'}on) {
              ${'$'}ie = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
              if (${'$'}on) {
                ${'$'}port = (Get-Content "${'$'}DIR\proxy_port") -join ''
                Set-ItemProperty -Path ${'$'}ie -Name ProxyEnable -Value 1
                Set-ItemProperty -Path ${'$'}ie -Name ProxyServer -Value "127.0.0.1:${'$'}port"
                netsh winhttp import proxy source=ie | Out-Null
              } else {
                Set-ItemProperty -Path ${'$'}ie -Name ProxyEnable -Value 0
                netsh winhttp reset proxy | Out-Null
              }
              ${'$'}sig = '[DllImport("wininet.dll")] public static extern bool InternetSetOption(IntPtr h,int dw,IntPtr v,int l);'
              ${'$'}t = Add-Type -MemberDefinition ${'$'}sig -Name WinInet -Namespace Native -PassThru
              [void]${'$'}t::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0)
              [void]${'$'}t::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0)
            }

            function Cleanup {
              Stop-Tun
              Set-Proxy ${'$'}false
              Remove-Item "${'$'}DIR\cmd","${'$'}DIR\cmd.done","${'$'}DIR\stop","${'$'}DIR\watcher.started","${'$'}DIR\heartbeat" -Force -ErrorAction SilentlyContinue
              exit
            }

            if (Test-Path "${'$'}DIR\stop") { Cleanup }
            'started' | Set-Content "${'$'}DIR\watcher.started"
            while (${'$'}true) {
              if (Test-Path "${'$'}DIR\stop") { Cleanup }
              if ((Test-Path "${'$'}DIR\singbox.pid") -and (Get-Process -Id (Get-Content "${'$'}DIR\singbox.pid") -ErrorAction SilentlyContinue)) {
                if ((Test-Path "${'$'}DIR\heartbeat") -and (((Get-Date) - (Get-Item "${'$'}DIR\heartbeat").LastWriteTime).TotalSeconds -gt 180)) { Cleanup }
              }
              if ((Test-Path "${'$'}DIR\cmd") -and -not (Test-Path "${'$'}DIR\cmd.done")) {
                ${'$'}lines = Get-Content "${'$'}DIR\cmd"
                ${'$'}nonce = ${'$'}lines[0]
                ${'$'}action = ${'$'}lines[1]
                switch (${'$'}action) {
                  'start_tun' { Start-Tun }
                  'stop_tun' { Stop-Tun }
                  'add_bypass' { Add-Bypass @(Get-Content "${'$'}DIR\add_ips") }
                  'start_proxy' { Set-Proxy ${'$'}true }
                  'stop_proxy' { Set-Proxy ${'$'}false }
                }
                ${'$'}nonce | Set-Content "${'$'}DIR\cmd.done"
              }
              Start-Sleep -Milliseconds 300
            }
            """.trimIndent() + "\n",
        )
    }

    private fun runPowershell(vararg args: String): Boolean = runCatching {
        ProcessBuilder(listOf("powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass") + args)
            .redirectOutput(ProcessBuilder.Redirect.DISCARD)
            .redirectError(ProcessBuilder.Redirect.INHERIT)
            .start().waitFor() == 0
    }.getOrDefault(false)

    private fun taskRegistered(): Boolean = runCatching {
        ProcessBuilder("schtasks", "/Query", "/TN", TASK_NAME)
            .redirectOutput(ProcessBuilder.Redirect.DISCARD)
            .redirectError(ProcessBuilder.Redirect.DISCARD)
            .start().waitFor() == 0
    }.getOrDefault(false)

    private fun registerTask(): Boolean {
        registerFile.writeText(
            """
            ${'$'}Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "${scriptFile.absolutePath}"'
            ${'$'}Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName '$TASK_NAME' -Action ${'$'}Action -Settings ${'$'}Settings -RunLevel Highest -Force | Out-Null
            """.trimIndent() + "\n",
        )
        AppLogger.i(TAG, "registering the privileged helper task — accept the UAC prompt (only ever asked once)")
        promptedForAdmin = true
        // Elevate once to register the task; later runs go through the task scheduler silently.
        val command =
            "Start-Process powershell -Verb RunAs -Wait -ArgumentList " +
                "'-NoProfile','-ExecutionPolicy','Bypass','-File',\"${registerFile.absolutePath}\""
        val ok = runPowershell("-Command", command)
        val deadline = System.currentTimeMillis() + 60_000
        var registered = false
        while (System.currentTimeMillis() < deadline) {
            registered = taskRegistered()
            if (registered) break
            Thread.sleep(1_000)
        }
        return registered
    }

    private fun ensureWatcher(): Boolean {
        if (watcherAlive()) return true
        writeScript()
        runCatching { startedFile.delete(); stopFile.delete() }
        if (!taskRegistered() && !registerTask()) {
            AppLogger.w(TAG, "the helper task could not be registered (UAC declined); full tunnel unavailable")
            return false
        }
        runCatching { ProcessBuilder("schtasks", "/Run", "/TN", TASK_NAME).start().waitFor() }
        val deadline = System.currentTimeMillis() + 15_000
        while (System.currentTimeMillis() < deadline) {
            if (watcherAlive()) return true
            Thread.sleep(300)
        }
        return watcherAlive()
    }

    private fun sendCommand(action: String, timeoutMs: Long = 45_000): Boolean {
        dir.mkdirs()
        if (!ensureWatcher()) return false
        runCatching { doneFile.delete() }
        val nonce = UUID.randomUUID().toString()
        cmdFile.writeText("$nonce\n$action\n")
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (doneFile.exists() && doneFile.readText().trim() == nonce) {
                runCatching { cmdFile.delete(); doneFile.delete() }
                return true
            }
            Thread.sleep(150)
        }
        AppLogger.w(TAG, "the privileged watcher did not answer '$action' in time")
        return false
    }

    fun startTun(configPath: String, bypassIps: List<String>): Boolean {
        configPathFile.writeText(configPath)
        bypassFile.writeText(bypassIps.joinToString("\n") + "\n")
        return sendCommand("start_tun")
    }

    fun stopTun(): Boolean = sendCommand("stop_tun")

    fun addBypassIps(ips: List<String>): Boolean {
        if (ips.isEmpty()) return true
        addIpsFile.writeText(ips.joinToString("\n") + "\n")
        return sendCommand("add_bypass")
    }

    fun startSystemProxy(port: Int): Boolean {
        proxyPortFile.writeText(port.toString())
        return sendCommand("start_proxy")
    }

    fun stopSystemProxy(): Boolean = sendCommand("stop_proxy")

    fun beat() {
        runCatching { heartbeatFile.writeText(System.currentTimeMillis().toString()) }
    }

    /** App quit: tear the tunnel down but keep the scheduled task for next time. */
    fun releaseSystem() {
        if (watcherAlive()) {
            runCatching { stopTun() }
            runCatching { stopSystemProxy() }
        }
    }
}
