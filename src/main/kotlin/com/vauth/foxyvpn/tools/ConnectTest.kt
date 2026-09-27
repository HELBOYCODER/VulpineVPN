package com.vauth.foxyvpn.tools

import com.vauth.foxyvpn.FoxyVpnApp
import com.vauth.foxyvpn.data.model.ConnectionState
import com.vauth.foxyvpn.vpn.FoxyVpnService
import com.vauth.foxyvpn.vpn.tun.MacHelper

/**
 * Manual harness: `gradle connectTest` signs in with the stored session, connects the
 * engine (system-proxy mode), verifies the SOCKS listener and the system proxy state,
 * then disconnects and restores the machine.
 */
fun main() {
    val app = FoxyVpnApp().apply { onCreate() }
    if (app.tokenStore.loadAuth() == null) {
        println("NO_SESSION — sign in through the app first")
        return
    }
    val shareWasEnabled = app.settingsStore.iosShareEnabled
    val sharePort = app.settingsStore.iosSharePort
    app.settingsStore.iosShareEnabled = true
    FoxyVpnService.start(app)
    var waited = 0
    while (FoxyVpnService.state.value == ConnectionState.CONNECTING && waited < 45) {
        Thread.sleep(1_000)
        waited++
    }
    println("STATE=${FoxyVpnService.state.value} err=${FoxyVpnService.lastError.value}")

    if (FoxyVpnService.state.value == ConnectionState.CONNECTED) {
        println("--- scutil --proxy (SOCKS lines) ---")
        ProcessBuilder("scutil", "--proxy").redirectErrorStream(true)
            .start().inputStream.bufferedReader().readLines()
            .filter { it.contains("SOCKS") }.forEach { println(it.trim()) }

        val viaSocks = runProcess("curl", "-s", "--max-time", "10", "--socks5-hostname", "127.0.0.1:1080", "https://api.ipify.org")
        val direct = runProcess("curl", "-s", "--max-time", "10", "https://api.ipify.org")
        println("EXIT_VIA_SOCKS=$viaSocks")
        println("EXIT_DIRECT(during proxy-on)=$direct")

        val httpsViaShare = runProcess(
            "curl", "-s", "--max-time", "15", "-x", "http://127.0.0.1:$sharePort", "https://api.ipify.org",
        )
        val httpViaShare = runProcess(
            "curl", "-s", "--max-time", "15", "-x", "http://127.0.0.1:$sharePort", "http://example.com/",
        ).lineSequence().firstOrNull { it.isNotBlank() }.orEmpty().take(60)
        println("EXIT_VIA_SHARE_HTTPS=$httpsViaShare")
        println("BODY_VIA_SHARE_HTTP=$httpViaShare")

        Thread.sleep(2_000)
        FoxyVpnService.stop(app)
        Thread.sleep(4_000)
    }
    app.settingsStore.iosShareEnabled = shareWasEnabled
    MacHelper.releaseSystem()
    println("STATE_AFTER_STOP=${FoxyVpnService.state.value}")
    println("PROXY_AFTER_STOP=" + runProcess("sh", "-c", "scutil --proxy | grep SOCKSEnabled || echo none"))
}

private fun runProcess(vararg cmd: String): String = runCatching {
    ProcessBuilder(*cmd).redirectErrorStream(true).start().inputStream.bufferedReader().readText().trim()
}.getOrElse { "failed: ${it.message}" }
