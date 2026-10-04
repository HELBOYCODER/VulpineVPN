package com.vauth.foxyvpn.vpn.tun

import com.vauth.foxyvpn.platform.Os

/** Platform dispatch for the full-tunnel backend (Windows only). */
object TunBackend {
    val supported: Boolean get() = Os.isWindows

    fun start(configPath: String, bypassIps: List<String>): Boolean =
        if (supported) WindowsTun.startTun(configPath, bypassIps) else false

    fun stop() {
        if (supported) WindowsTun.stopTun()
    }

    fun addBypass(ips: List<String>): Boolean = supported && WindowsTun.addBypassIps(ips)

    fun beat() {
        if (supported) WindowsTun.beat()
    }
}
