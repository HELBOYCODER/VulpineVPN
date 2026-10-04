package com.vauth.foxyvpn

import android.util.Log
import com.vauth.foxyvpn.data.CrashReporter
import com.vauth.foxyvpn.data.FxaAuthRepository
import com.vauth.foxyvpn.data.GuardianClient
import com.vauth.foxyvpn.data.ProxyStateStore
import com.vauth.foxyvpn.data.ServerListClient
import com.vauth.foxyvpn.data.SettingsStore
import com.vauth.foxyvpn.data.TokenStore
import com.vauth.foxyvpn.platform.AppHolder
import com.vauth.foxyvpn.vpn.upstream.NettyLoggingBridge
import org.conscrypt.Conscrypt
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.security.Security

/**
 * Desktop replacement for the Android [Application]. Same member surface so the
 * navigation graph and screens compile unchanged.
 */
class FoxyVpnApp : android.content.Context() {

    lateinit var tokenStore: TokenStore
    lateinit var proxyStateStore: ProxyStateStore
    lateinit var settingsStore: SettingsStore
    lateinit var guardianClient: GuardianClient
    lateinit var serverListClient: ServerListClient
    lateinit var authRepository: FxaAuthRepository

    override val applicationContext: android.content.Context get() = this

    fun onCreate() {
        AppHolder.context = this
        // The engine's own control-plane traffic must never follow the macOS system proxy
        // (which is the app's own SOCKS server while connected) or every request loops.
        ProxySelector.setDefault(object : ProxySelector() {
            override fun select(uri: java.net.URI): List<Proxy> = listOf(Proxy.NO_PROXY)
            override fun connectFailed(uri: java.net.URI, sa: SocketAddress, failure: java.io.IOException) {}
        })
        CrashReporter.install(this)
        CrashReporter.replayLastCrashIfAny(this)

        NettyLoggingBridge.install()
        installConscrypt()
        tokenStore = TokenStore(this)
        proxyStateStore = ProxyStateStore(this)
        settingsStore = SettingsStore(this)
        guardianClient = GuardianClient()
        serverListClient = ServerListClient()
        authRepository = FxaAuthRepository(tokenStore)
    }

    private fun installConscrypt() {
        runCatching {
            Security.insertProviderAt(Conscrypt.newProvider(), 1)
        }.onFailure {
            Log.w("FoxyVpnApp", "failed to install Conscrypt security provider; falling back to the JDK TLS stack", it)
        }
    }

    companion object {
        const val VPN_NOTIFICATION_CHANNEL_ID = "foxyvpn_status"
    }
}
