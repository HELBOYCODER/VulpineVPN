package com.vauth.foxyvpn.vpn.tun

import com.vauth.foxyvpn.data.AppLogger

private const val TAG = "WinHelper"

/**
 * Windows system-proxy backend. Writes the per-user (HKCU) WinINet proxy settings,
 * which Chrome, Edge and Firefox ("use system settings") pick up; no elevation needed.
 */
object WinHelper {

    private const val IE_SETTINGS = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings"

    @Volatile
    private var proxyApplied = false

    private fun reg(args: List<String>): Boolean = runCatching {
        ProcessBuilder(buildList {
            add("reg")
            addAll(args)
        }).redirectErrorStream(true).start().waitFor() == 0
    }.getOrElse {
        AppLogger.w(TAG, "reg command failed", it)
        false
    }

    private fun notifyWinInet() {
        // Broadcast INTERNET_OPTION_SETTINGS_CHANGED (39) + INTERNET_OPTION_REFRESH (37)
        val ps =
            "\$sig='[DllImport(\"wininet.dll\")] public static extern bool InternetSetOption(IntPtr h,int dw,IntPtr v,int l);'; " +
            "\$t=Add-Type -MemberDefinition \$sig -Name WinInet -Namespace Native -PassThru; " +
            "[void]\$t::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0); " +
            "[void]\$t::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0)"
        runCatching {
            ProcessBuilder("powershell", "-NoProfile", "-NonInteractive", "-Command", ps)
                .redirectErrorStream(true).start().waitFor()
        }.onFailure { AppLogger.w(TAG, "could not notify WinINet of the proxy change", it) }
    }

    fun startSystemProxy(port: Int): Boolean {
        val enabled = reg(listOf("add", IE_SETTINGS, "/v", "ProxyEnable", "/t", "REG_DWORD", "/d", "1", "/f"))
        val server = reg(listOf("add", IE_SETTINGS, "/v", "ProxyServer", "/t", "REG_SZ", "/d", "127.0.0.1:$port", "/f"))
        val ok = enabled && server
        notifyWinInet()
        if (ok) {
            proxyApplied = true
            AppLogger.i(TAG, "Windows system proxy enabled: 127.0.0.1:$port")
        }
        return ok
    }

    fun stopSystemProxy(): Boolean {
        val ok = reg(listOf("add", IE_SETTINGS, "/v", "ProxyEnable", "/t", "REG_DWORD", "/d", "0", "/f"))
        notifyWinInet()
        if (ok) {
            proxyApplied = false
            AppLogger.i(TAG, "Windows system proxy disabled")
        }
        return ok
    }

    fun releaseSystem() {
        if (proxyApplied) stopSystemProxy()
    }
}
