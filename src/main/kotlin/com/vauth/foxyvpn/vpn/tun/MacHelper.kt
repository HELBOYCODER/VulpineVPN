package com.vauth.foxyvpn.vpn.tun

import com.vauth.foxyvpn.data.AppLogger
import com.vauth.foxyvpn.platform.FoxyPaths
import java.io.File
import java.util.UUID

private const val TAG = "MacHelper"
private const val DAEMON_LABEL = "com.vauth.foxyvpn.helper"

/**
 * A root-owned helper (installed as a LaunchDaemon after one admin prompt) that toggles
 * the macOS SOCKS system proxy. The daemon stays installed across app restarts and
 * reinstalls, so the administrator approval is given once.
 */
object MacHelper {

    private const val DAEMON_PLIST_PATH = "/Library/LaunchDaemons/$DAEMON_LABEL.plist"

    private val dir: File get() = FoxyPaths.helperDir
    private val cmdFile get() = File(dir, "cmd")
    private val doneFile get() = File(dir, "cmd.done")
    private val stopFile get() = File(dir, "stop")
    private val startedFile get() = File(dir, "watcher.started")
    private val scriptFile get() = File(dir, "foxy-helper.sh")
    private val plistStagingFile get() = File(dir, "foxy-helper.plist")
    private val proxyPortFile get() = File(dir, "proxy_port")

    @Volatile
    private var promptedForAdmin = false

    @Volatile
    private var shuttingDown = false

    private fun commandNonce(): String = UUID.randomUUID().toString()

    private fun watcherAlive(): Boolean {
        val printOut = runCatching {
            ProcessBuilder("launchctl", "print", "system/$DAEMON_LABEL")
                .redirectErrorStream(true).start().inputStream.bufferedReader().readText()
        }.getOrDefault("")
        if ("state = running" in printOut) return true
        return ProcessHandle.allProcesses()
            .anyMatch { h -> h.info().commandLine().orElse("").contains("foxy-helper.sh") }
    }

    private fun writeScript(): Boolean {
        val desired = """
            #!/bin/sh
            # FoxyVPN privileged helper - generated, do not edit.
            PATH="/usr/bin:/bin:/usr/sbin:/sbin"; export PATH
            DIR="${dir.absolutePath}"

            active_service() {
              # macOS has no ipconfig getrouter; read the default route from netstat,
              # preferring a physical en* interface.
              eval `netstat -rn -f inet | awk '$1=="default" && ${'$'}NF ~ /^en/ {print "GW="${'$'}2"; PIF="${'$'}NF; exit}'`
              [ -z "${'$'}PIF" ] && eval `netstat -rn -f inet | awk '$1=="default" {print "GW="${'$'}2"; PIF="${'$'}NF; exit}'`
              [ -z "${'$'}PIF" ] && return
              networksetup -listnetworkserviceorder | awk -v ifc="${'$'}PIF" '
                /^\([0-9]+\)/ { name=${'$'}0; sub(/^[^)]*\) */, "", name) }
                index(${'$'}0, "Device: " ifc) > 0 { print name; exit }
              '
            }

            handle() {
              case "${'$'}1" in
                start_proxy)
                  SVC=`active_service`
                  PORT=`cat "${'$'}DIR/proxy_port" 2>/dev/null`
                  [ -n "${'$'}SVC" ] && [ -n "${'$'}PORT" ] || return
                  networksetup -setsocksfirewallproxy "${'$'}SVC" 127.0.0.1 "${'$'}PORT" >/dev/null 2>&1
                  networksetup -setsocksfirewallproxystate "${'$'}SVC" on >/dev/null 2>&1
                  ;;
                stop_proxy)
                  SVC=`active_service`
                  [ -n "${'$'}SVC" ] && networksetup -setsocksfirewallproxystate "${'$'}SVC" off >/dev/null 2>&1
                  ;;
              esac
            }

            uninstall() {
              handle stop_proxy
              rm -f "${'$'}DIR/cmd" "${'$'}DIR/cmd.done" "${'$'}DIR/stop" "${'$'}DIR/watcher.started" "${'$'}DIR/heartbeat"
              launchctl bootout system/$DAEMON_LABEL 2>/dev/null
              rm -f "$DAEMON_PLIST_PATH"
              exit 0
            }

            [ -f "${'$'}DIR/stop" ] && uninstall
            touch "${'$'}DIR/watcher.started"
            while :; do
              [ -f "${'$'}DIR/stop" ] && uninstall
              if [ -f "${'$'}DIR/cmd" ] && [ ! -f "${'$'}DIR/cmd.done" ]; then
                nonce=`head -1 "${'$'}DIR/cmd"`
                action=`sed -n 2p "${'$'}DIR/cmd"`
                handle "${'$'}action"
                echo "${'$'}nonce" > "${'$'}DIR/cmd.done"
              fi
              sleep 0.3
            done
            """.trimIndent() + "\n"
        val previous = scriptFile.takeIf { it.exists() }?.readText()
        if (previous == desired) return false
        scriptFile.writeText(desired)
        scriptFile.setReadable(true, false)
        return true
    }

    private fun writePlist() {
        plistStagingFile.writeText(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>$DAEMON_LABEL</string>
              <key>ProgramArguments</key>
              <array><string>/bin/sh</string><string>${scriptFile.absolutePath}</string></array>
              <key>RunAtLoad</key><true/>
              <key>KeepAlive</key><true/>
              <key>StandardOutPath</key><string>${File(dir, "launchd.out").absolutePath}</string>
              <key>StandardErrorPath</key><string>${File(dir, "launchd.err").absolutePath}</string>
            </dict>
            </plist>
            """.trimIndent() + "\n",
        )
    }

    private fun startDaemon(): Boolean {
        writeScript()
        writePlist()
        runCatching { stopFile.delete() }
        runCatching { startedFile.delete() }

        val installCommand =
            "cp '${plistStagingFile.absolutePath}' '$DAEMON_PLIST_PATH' && " +
                "chown root:wheel '$DAEMON_PLIST_PATH' && chmod 644 '$DAEMON_PLIST_PATH' && " +
                "launchctl bootout system/$DAEMON_LABEL 2>/dev/null; " +
                "launchctl bootstrap system '$DAEMON_PLIST_PATH'"
        val promptScript =
            "do shell script \"$installCommand\" " +
                "with prompt \"Vulpine VPN needs administrator access once to manage the system proxy. This is the last time it will ask.\" " +
                "with administrator privileges"
        val result = runCatching {
            ProcessBuilder("osascript", "-e", promptScript)
                .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .redirectError(ProcessBuilder.Redirect.INHERIT)
                .start()
                .waitFor()
        }
        if (result.getOrDefault(1) != 0) {
            AppLogger.w(TAG, "the administrator prompt was declined or failed; the system proxy is unavailable")
            return false
        }
        val deadline = System.currentTimeMillis() + 15_000
        while (System.currentTimeMillis() < deadline) {
            if (startedFile.exists() && watcherAlive()) {
                AppLogger.i(TAG, "the privileged helper (LaunchDaemon) is up and running")
                return true
            }
            Thread.sleep(250)
        }
        return watcherAlive()
    }

    private fun ensureWatcher(): Boolean {
        if (shuttingDown) return false
        val scriptChanged = writeScript()
        if (watcherAlive()) {
            if (!scriptChanged) return true
            AppLogger.i(TAG, "the helper script was updated; restarting the privileged helper")
            runCatching { stopFile.createNewFile() }
            val stopDeadline = System.currentTimeMillis() + 10_000
            while (System.currentTimeMillis() < stopDeadline && watcherAlive()) {
                Thread.sleep(300)
            }
            return startDaemon()
        }
        promptedForAdmin = true
        return startDaemon()
    }

    private fun sendCommand(action: String, timeoutMs: Long = 30_000): Boolean {
        if (shuttingDown) return false
        dir.mkdirs()
        if (!ensureWatcher()) return false
        runCatching { doneFile.delete() }
        val nonce = commandNonce()
        cmdFile.writeText("$nonce\n$action\n")
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (doneFile.exists() && doneFile.readText().trim() == nonce) {
                runCatching { cmdFile.delete(); doneFile.delete() }
                return true
            }
            Thread.sleep(150)
        }
        AppLogger.w(TAG, "the privileged helper did not answer the '$action' command in time")
        return false
    }

    val isAdminAvailable: Boolean get() = watcherAlive() || !promptedForAdmin

    fun startSystemProxy(port: Int): Boolean {
        proxyPortFile.writeText(port.toString())
        return sendCommand("start_proxy")
    }

    fun stopSystemProxy(): Boolean = sendCommand("stop_proxy")

    /**
     * App quit path: clear the system proxy but keep the LaunchDaemon installed, so the
     * administrator approval is given once and survives app restarts and reinstalls.
     */
    fun releaseSystem() {
        if (watcherAlive()) {
            runCatching { stopSystemProxy() }
        }
        shuttingDown = true
    }
}
