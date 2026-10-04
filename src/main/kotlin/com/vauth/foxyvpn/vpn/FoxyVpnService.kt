package com.vauth.foxyvpn.vpn

import com.vauth.foxyvpn.FoxyVpnApp
import com.vauth.foxyvpn.data.AppLogger
import com.vauth.foxyvpn.data.ControlPlaneHttp
import com.vauth.foxyvpn.data.FxaAuthRepository
import com.vauth.foxyvpn.data.GUARDIAN_ENDPOINT_DEFAULT
import com.vauth.foxyvpn.data.GuardianClient
import com.vauth.foxyvpn.data.ProxyPass
import com.vauth.foxyvpn.data.ProxyStateStore
import com.vauth.foxyvpn.data.QuotaExceededError
import com.vauth.foxyvpn.data.RECOMMENDED_COUNTRY_CODE
import com.vauth.foxyvpn.data.ServerListClient
import com.vauth.foxyvpn.data.SettingsStore
import com.vauth.foxyvpn.data.TokenInvalidError
import com.vauth.foxyvpn.data.TokenStore
import com.vauth.foxyvpn.data.formatBytesPerSecond
import com.vauth.foxyvpn.data.model.ConnectionState
import com.vauth.foxyvpn.data.model.ProxyCandidate
import com.vauth.foxyvpn.data.model.RuntimeAuth
import com.vauth.foxyvpn.platform.AppHolder
import com.vauth.foxyvpn.vpn.http.LocalHttpProxyServer
import com.vauth.foxyvpn.vpn.socks.LocalSocks5Server
import com.vauth.foxyvpn.vpn.tun.SystemProxy
import com.vauth.foxyvpn.vpn.tun.TunBackend
import com.vauth.foxyvpn.vpn.tun.WindowsTunConfig
import com.vauth.foxyvpn.vpn.upstream.EdgeAddressResolver
import com.vauth.foxyvpn.vpn.upstream.UpstreamProxyConfig
import com.vauth.foxyvpn.vpn.upstream.UpstreamSession
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout

import kotlinx.coroutines.withContext
import java.net.InetAddress

private const val TAG = "FoxyVpnService"
private const val CONNECT_TIMEOUT_MS = 20_000L
private const val SERVER_LIST_FETCH_TIMEOUT_MS = 15_000L

private const val UPSTREAM_WATCHDOG_INTERVAL_MS = 2_000L

private const val RECONNECT_FAILURES_BEFORE_WARNING = 5
private const val RECONNECT_BACKOFF_BASE_MS = 3_000L
private const val RECONNECT_BACKOFF_CAP_MS = 60_000L

private const val RECONNECT_FAILURES_BEFORE_EDGE_ROTATION = 2

private const val MAX_ALTERNATE_EDGES = 3

private const val UNHEALTHY_REDIAL_COOLDOWN_MS = 30_000L

private const val PROXY_PASS_RENEWAL_FRACTION = 0.5
private const val PROXY_PASS_RENEWAL_SAFETY_MARGIN_MS = 30_000L

private const val PROXY_PASS_RENEWAL_FLOOR_MS = 15_000L

private const val PROXY_PASS_RENEWAL_CEILING_MS = 30 * 60_000L

private const val PROXY_PASS_RENEWAL_FALLBACK_MS = 4 * 60_000L

private const val PROXY_PASS_RENEWAL_RETRY_MS = 30_000L

private const val POST_TUN_SETTLE_MS = 1_000L

private const val INITIAL_DIAL_SETTLE_MS = 600L

private const val INITIAL_DIAL_MAX_ATTEMPTS = MAX_ALTERNATE_EDGES + 1
private const val INITIAL_DIAL_BACKOFF_BASE_MS = 2_000L
private const val INITIAL_DIAL_BACKOFF_CAP_MS = 8_000L

private const val SPEED_UPDATE_INTERVAL_MS = 2_000L

private fun fullJitterBackoffMs(attempt: Int, baseMs: Long, capMs: Long): Long {
    val exponential = baseMs * (1L shl attempt.coerceIn(0, 10))
    val upperBound = exponential.coerceAtMost(capMs)
    return (upperBound.toDouble() * Math.random()).toLong().coerceAtLeast(baseMs / 4)
}

private fun proxyPassRenewalDelayMs(expiresAtEpochSeconds: Long?): Long {
    if (expiresAtEpochSeconds == null) return PROXY_PASS_RENEWAL_FALLBACK_MS
    val remainingMs = expiresAtEpochSeconds * 1_000L - System.currentTimeMillis()
    if (remainingMs <= 0L) return PROXY_PASS_RENEWAL_FLOOR_MS
    val atHalfLife = (remainingMs * PROXY_PASS_RENEWAL_FRACTION).toLong()
    val beforeExpiry = remainingMs - PROXY_PASS_RENEWAL_SAFETY_MARGIN_MS
    return minOf(atHalfLife, beforeExpiry)
        .coerceAtMost(PROXY_PASS_RENEWAL_CEILING_MS)
        .coerceAtLeast(PROXY_PASS_RENEWAL_FLOOR_MS)
}

/**
 * macOS port of the Android foreground VPN service. The connection state machine,
 * proxy-pass renewal, edge failover and upstream watchdog are carried over unchanged;
 * the platform plumbing (VpnService TUN, notifications, wake locks) is replaced by the
 * [MacHelper]-driven sing-box tunnel and the system proxy.
 */
object FoxyVpnService {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val opMutex = Mutex()

    private var socksServer: LocalSocks5Server? = null
    private var httpServer: LocalHttpProxyServer? = null
    private var upstreamSession: UpstreamSession? = null
    private var connectJob: Job? = null
    private var watchdogJob: Job? = null
    private var speedJob: Job? = null
    private var tokenRenewalJob: Job? = null

    @Volatile private var tunActive = false
    @Volatile private var systemProxyActive = false

    @Volatile private var lastUnhealthyRedialAt = 0L

    @Volatile private var statusLabel: String = "Connecting…"

    private class SessionResources(
        val socksServer: LocalSocks5Server?,
        val httpServer: LocalHttpProxyServer?,
        val upstreamSession: UpstreamSession?,
    ) {
        val isEmpty: Boolean get() = socksServer == null && httpServer == null && upstreamSession == null
    }

    @Volatile
    private var connectionGeneration = 0

    private val _state = kotlinx.coroutines.flow.MutableStateFlow(ConnectionState.DISCONNECTED)
    val state: kotlinx.coroutines.flow.StateFlow<ConnectionState> = _state

    private val _lastError = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)
    val lastError: kotlinx.coroutines.flow.StateFlow<String?> = _lastError

    private fun app(): FoxyVpnApp = AppHolder.context as FoxyVpnApp

    fun start(context: android.content.Context) {
        if (_state.value != ConnectionState.DISCONNECTED) {
            AppLogger.d(TAG, "ignoring duplicate connect request while ${_state.value}")
            return
        }
        _state.value = ConnectionState.CONNECTING
        _lastError.value = null
        statusLabel = "Connecting…"
        connectJob = scope.launch { opMutex.withLock { connect() } }
    }

    fun stop(context: android.content.Context) {
        requestDisconnect("requested by the user")
    }

    /**
     * Applies the phone-sharing switch without waiting for the next dial, so a connected
     * tunnel starts answering HTTP proxies the moment the user flips it on.
     */
    fun applyIosShare(enabled: Boolean) {
        if (!enabled) {
            val server = httpServer ?: return
            httpServer = null
            runCatching { server.stop() }
                .onFailure { AppLogger.w(TAG, "error stopping the iOS/LAN HTTP share proxy", it) }
            AppLogger.i(TAG, "iOS/LAN HTTP share proxy stopped")
            return
        }
        if (httpServer != null || _state.value == ConnectionState.DISCONNECTED) return
        val generation = connectionGeneration
        val port = app().settingsStore.iosSharePort
        val server = LocalHttpProxyServer("0.0.0.0", port) { upstreamSession }
        if (runCatching { server.start() }.isFailure) {
            runCatching { server.stop() }
            AppLogger.w(TAG, "could not bind the iOS/LAN HTTP share proxy on port $port")
            _lastError.value = "iOS share proxy could not start on port $port (already in use?)."
            return
        }
        if (connectionGeneration != generation) {
            runCatching { server.stop() }
            return
        }
        httpServer = server
        AppLogger.i(TAG, "iOS/LAN HTTP share proxy started on 0.0.0.0:$port")
    }

    private fun requestDisconnect(reason: String) {
        val idle = _state.value == ConnectionState.DISCONNECTED && connectJob == null && watchdogJob == null
        if (idle) return
        AppLogger.i(TAG, "disconnect: $reason")

        val endedGeneration = ++connectionGeneration
        _state.value = ConnectionState.DISCONNECTED
        connectJob?.cancel()
        connectJob = null
        watchdogJob?.cancel()
        watchdogJob = null

        val doomed = detachResources()
        scope.launch {
            opMutex.withLock {
                val stillOurs = connectionGeneration == endedGeneration
                releaseResources(doomed, stopSystemTunnel = stillOurs)
            }
        }
    }

    private fun onUpstreamSessionUnhealthy() {
        if (_state.value != ConnectionState.CONNECTED) return
        val session = upstreamSession ?: return
        val now = System.currentTimeMillis()
        val sinceLast = now - lastUnhealthyRedialAt
        if (lastUnhealthyRedialAt != 0L && sinceLast < UNHEALTHY_REDIAL_COOLDOWN_MS) {
            AppLogger.d(
                TAG,
                "ignoring an unhealthy-session verdict ${sinceLast}ms after the last rebuild " +
                    "(cooldown ${UNHEALTHY_REDIAL_COOLDOWN_MS}ms)",
            )
            return
        }
        lastUnhealthyRedialAt = now
        AppLogger.w(
            TAG,
            "the local proxy reports the upstream session is failing as a whole rather than for one destination; " +
                "closing it so the watchdog redials",
        )
        runCatching { session.close() }
    }

    private fun ensureGenerationCurrent(myGeneration: Int) {
        if (myGeneration != connectionGeneration) {
            throw CancellationException("connect was superseded by a newer request")
        }
    }

    private fun isFatalUpstreamError(error: Throwable): Boolean =
        error is TokenInvalidError || error is QuotaExceededError

    private suspend fun mintProxyPass(tokenStore: TokenStore): ProxyPass {
        var auth = tokenStore.loadAuth() ?: throw TokenInvalidError("Not signed in")

        if (!tokenStore.hasValidSession()) {
            val renewed = renewAccessToken(tokenStore)
            if (renewed != null) {
                auth = renewed
                AppLogger.i(TAG, "the account's access token had expired and was renewed")
            } else {
                AppLogger.w(
                    TAG,
                    "the account's access token is past its expiry and could not be renewed automatically; " +
                        "you may need to sign in again",
                )
            }
        }
        val guardian = GuardianClient()

        return try {
            guardian.fetchProxyPass(GUARDIAN_ENDPOINT_DEFAULT, auth.accessToken)
        } catch (invalid: TokenInvalidError) {
            AppLogger.w(TAG, "proxy pass rejected, activating Guardian entitlement and retrying", invalid)
            guardian.activateGuardian(GUARDIAN_ENDPOINT_DEFAULT, auth.accessToken)
            guardian.fetchProxyPass(GUARDIAN_ENDPOINT_DEFAULT, auth.accessToken)
        }
    }

    private suspend fun renewAccessToken(tokenStore: TokenStore): RuntimeAuth? {
        val attempt = runCatching { FxaAuthRepository(tokenStore).refreshAccessToken() }
        val failure = attempt.exceptionOrNull()
        if (failure is CancellationException) throw failure
        if (failure != null) {
            AppLogger.w(TAG, "renewing the account's access token failed", failure)
            return null
        }
        return attempt.getOrNull()
    }

    private suspend fun resolveIpsFor(hosts: List<String>): List<String> = withContext(Dispatchers.IO) {
        hosts.filter { it.isNotBlank() }.flatMap { host ->
            runCatching {
                InetAddress.getAllByName(host).map { it.hostAddress.substringBefore('%') }
            }.getOrDefault(emptyList())
        }.distinct()
    }

    private suspend fun startProxyPassRenewal(
        myGeneration: Int,
        tokenStore: TokenStore,
        initialExpiry: Long?,
    ) {
        tokenRenewalJob?.cancel()
        tokenRenewalJob = scope.launch {
            var expiry = initialExpiry
            AppLogger.i(
                TAG,
                "proxy pass renewal scheduled in ${proxyPassRenewalDelayMs(expiry) / 1_000}s " +
                    (if (expiry == null) "(pass lifetime unknown; using a fixed interval)" else "(at half of its remaining life)"),
            )
            while (scope.isActive) {
                delay(proxyPassRenewalDelayMs(expiry))
                if (myGeneration != connectionGeneration) return@launch

                val session = upstreamSession
                if (session == null || !session.isConnected) {
                    AppLogger.d(TAG, "skipping proxy pass renewal: no live session (the watchdog's redial mints its own)")
                    continue
                }

                val attempt = runCatching { mintProxyPass(tokenStore) }
                val pass = attempt.getOrNull()
                if (pass == null) {
                    val error = attempt.exceptionOrNull()
                    if (error is CancellationException) throw error
                    if (error != null && isFatalUpstreamError(error)) {
                        AppLogger.e(
                            TAG,
                            "proxy pass renewal failed for a reason retrying cannot fix; leaving the session to the watchdog",
                            error,
                        )
                        return@launch
                    }
                    AppLogger.w(TAG, "proxy pass renewal failed; retrying shortly: ${error?.message}")

                    expiry = null
                    delay(PROXY_PASS_RENEWAL_RETRY_MS)
                    continue
                }

                if (myGeneration != connectionGeneration) return@launch

                val live = upstreamSession
                if (live == null || !live.isConnected) {
                    AppLogger.d(
                        TAG,
                        "minted a fresh proxy pass but the session went down meanwhile; the watchdog's redial " +
                            "will mint its own",
                    )
                    expiry = pass.expiresAtEpochSeconds
                    continue
                }

                val lifetimeNote = pass.expiresAtEpochSeconds?.let { expiresAt ->
                    val seconds = (expiresAt * 1_000L - System.currentTimeMillis()) / 1_000L
                    " (valid for ${seconds}s)"
                } ?: " (lifetime not stated)"
                live.updateBearerToken(pass.token)
                AppLogger.i(TAG, "proxy pass renewed in place$lifetimeNote; the tunnel was not rebuilt")

                expiry = pass.expiresAtEpochSeconds
            }
        }
    }

    private suspend fun connect() {
        val myGeneration = ++connectionGeneration

        lastUnhealthyRedialAt = 0L

        EdgeAddressResolver.invalidate()
        runCatching {
            AppLogger.i(TAG, "connect: starting")
            val application = app()
            val tokenStore = application.tokenStore
            if (tokenStore.loadAuth() == null) error("Not signed in")
            val proxyStateStore = application.proxyStateStore
            val settingsStore = application.settingsStore

            val primaryCandidate = resolveConnectCandidate(proxyStateStore)
            ensureGenerationCurrent(myGeneration)

            var candidates = listOf(primaryCandidate)
            var candidateIndex = 0
            var alternatesDiscovered = false

            fun activeCandidate(): ProxyCandidate = candidates[candidateIndex.coerceIn(0, candidates.lastIndex)]

            suspend fun rotateCandidate(): Boolean {
                if (candidateIndex + 1 >= candidates.size && !alternatesDiscovered) {
                    alternatesDiscovered = true
                    val fresh = discoverAlternateCandidates(primaryCandidate)
                        .filter { discovered -> candidates.none { known -> known.authority == discovered.authority } }
                        .take(MAX_ALTERNATE_EDGES)
                    if (fresh.isNotEmpty()) {
                        candidates = candidates + fresh
                        AppLogger.i(
                            TAG,
                            "found ${fresh.size} alternate edge(s) in ${primaryCandidate.countryCode} to fail over to",
                        )
                    }
                }
                if (candidateIndex + 1 >= candidates.size) return false
                candidateIndex++
                AppLogger.i(
                    TAG,
                    "failing over to edge ${activeCandidate().authority} " +
                        "(${candidateIndex + 1} of ${candidates.size})",
                )
                return true
            }

            val upstreamProxyConfig = if (settingsStore.upstreamProxyEnabled && settingsStore.upstreamProxyHost.isNotBlank()) {
                UpstreamProxyConfig(
                    type = when (settingsStore.upstreamProxyType) {
                        SettingsStore.UpstreamProxyType.SOCKS5 -> UpstreamProxyConfig.Type.SOCKS5
                        SettingsStore.UpstreamProxyType.HTTP -> UpstreamProxyConfig.Type.HTTP
                    },
                    host = settingsStore.upstreamProxyHost,
                    port = settingsStore.upstreamProxyPort,
                    username = settingsStore.upstreamProxyUsername.ifBlank { null },
                    password = settingsStore.upstreamProxyPassword.ifBlank { null },
                )
            } else {
                null
            }
            val chainSuffix = if (upstreamProxyConfig != null) {
                " via ${upstreamProxyConfig.type} proxy ${upstreamProxyConfig.host}:${upstreamProxyConfig.port}"
            } else {
                ""
            }

            val customEdgeAddress = settingsStore.effectiveCustomEdgeAddress
            val edgeSuffix = if (customEdgeAddress != null) {
                " via pinned edge $customEdgeAddress:${primaryCandidate.port}"
            } else {
                ""
            }

            val dohEndpointAddresses = settingsStore.dohProvider.addresses

            AppLogger.i(
                TAG,
                "connect: target=${primaryCandidate.authority} country=${primaryCandidate.countryCode}$chainSuffix$edgeSuffix",
            )

            val socksPort = settingsStore.socksPort
            val socksBindAddress = settingsStore.socksBindAddress
            var trafficMode = settingsStore.macTrafficMode
            val customDnsServer = settingsStore.effectiveCustomDnsServer

            // In full-tunnel mode the whole machine's traffic (including our own control-plane
            // and upstream sockets) is captured, so every host we dial gets an explicit bypass
            // route; pre-collect the alternates so failover never loops.
            if (trafficMode == SettingsStore.MacTrafficMode.GLOBAL_TUN) {
                alternatesDiscovered = true
                val fresh = discoverAlternateCandidates(primaryCandidate)
                    .filter { discovered -> candidates.none { known -> known.authority == discovered.authority } }
                    .take(MAX_ALTERNATE_EDGES)
                if (fresh.isNotEmpty()) candidates = candidates + fresh
            }

            fun connectedLabel(): String = when (trafficMode) {
                SettingsStore.MacTrafficMode.LOCAL_PROXY ->
                    "Proxy active \u2022 $socksBindAddress:$socksPort"
                SettingsStore.MacTrafficMode.SYSTEM_PROXY ->
                    "System proxy active \u2022 $socksBindAddress:$socksPort"
                SettingsStore.MacTrafficMode.GLOBAL_TUN -> {
                    val target = activeCandidate()
                    "Connected \u2022 ${target.countryName.ifBlank { target.countryCode }}"
                }
            }

            ControlPlaneHttp.socketProtector = null

            val socks = LocalSocks5Server(
                socksBindAddress,
                socksPort,
                false,
                { upstreamSession },
            ) {
                onUpstreamSessionUnhealthy()
            }
            socks.start()
            socksServer = socks
            if (settingsStore.iosShareEnabled) applyIosShare(true)
            ensureGenerationCurrent(myGeneration)

            suspend fun bringUpSystemTunnel(): Unit = when (trafficMode) {
                SettingsStore.MacTrafficMode.LOCAL_PROXY -> {
                    AppLogger.i(
                        TAG,
                        "connect: local proxy mode enabled; nothing is captured system-wide, " +
                            "point apps at the proxy at $socksBindAddress:$socksPort",
                    )
                }
                SettingsStore.MacTrafficMode.SYSTEM_PROXY -> {
                    if (SystemProxy.start(socksPort)) {
                        systemProxyActive = true
                        AppLogger.i(TAG, "connect: macOS SOCKS system proxy enabled on 127.0.0.1:$socksPort")
                    } else {
                        AppLogger.w(
                            TAG,
                            "could not enable the system proxy (needs administrator access on macOS); " +
                                "falling back to local proxy only",
                        )
                        _lastError.value =
                            "System proxy could not be enabled. Running local-proxy only " +
                            "($socksBindAddress:$socksPort)."
                    }
                }
                SettingsStore.MacTrafficMode.GLOBAL_TUN -> {
                    val bypassHosts = buildList {
                        addAll(candidates.map { it.host })
                        add("vpn.mozilla.org")
                        add("firefox.settings.services.mozilla.com")
                        add("api.accounts.firefox.com")
                        add("accounts.firefox.com")
                        add("identity.mozilla.com")
                        add("www.cloudflare.com")
                        addAll(dohEndpointAddresses)
                        customDnsServer?.let { add(it) }
                    }
                    val bypassIps = resolveIpsFor(bypassHosts) + dohEndpointAddresses
                    val configPath = WindowsTunConfig.write(socksPort, dohEndpointAddresses, bypassIps)
                    if (TunBackend.start(configPath, bypassIps)) {
                        tunActive = true
                        AppLogger.i(TAG, "connect: TUN interface up, sing-box tun2socks started")
                        delay(POST_TUN_SETTLE_MS)
                    } else {
                        AppLogger.w(
                            TAG,
                            "the TUN backend is unavailable (UAC declined or sing-box missing); " +
                                "falling back to system proxy mode",
                        )
                        tunActive = false
                        trafficMode = SettingsStore.MacTrafficMode.SYSTEM_PROXY
                        bringUpSystemTunnel()
                    }
                }
            }
            bringUpSystemTunnel()
            ensureGenerationCurrent(myGeneration)

            suspend fun dialUpstream(): Pair<com.vauth.foxyvpn.vpn.upstream.H2UpstreamSession, Long?> {
                val target = activeCandidate()
                val pass = mintProxyPass(tokenStore)
                val lifetimeNote = pass.expiresAtEpochSeconds?.let { expiresAt ->
                    val seconds = (expiresAt * 1_000L - System.currentTimeMillis()) / 1_000L
                    " (valid for ${seconds}s)"
                } ?: " (lifetime not stated)"
                AppLogger.i(TAG, "connect: acquired Guardian proxy pass$lifetimeNote")

                val dialTunMode = trafficMode == SettingsStore.MacTrafficMode.GLOBAL_TUN && tunActive
                // While the TUN captures the whole machine the edge must be dialed by IP: the
                // hostname would resolve to a fake IP through the tunnel and loop.
                val effectiveDoh = dohEndpointAddresses.ifEmpty {
                    if (dialTunMode) listOf("1.1.1.1", "8.8.8.8") else emptyList()
                }
                val edgeAddress = customEdgeAddress
                    ?: resolveEdgeAddress(target.host, upstreamProxyConfig, effectiveDoh)

                val session = com.vauth.foxyvpn.vpn.upstream.H2UpstreamSession(
                    target.host,
                    target.port,
                    pass.token,
                    upstreamProxyConfig,
                    edgeAddress,
                )
                try {
                    session.connect()
                } catch (failure: Throwable) {
                    runCatching { session.close() }
                    throw failure
                }
                if (dialTunMode) {
                    val dialedIp = edgeAddress
                        ?: runCatching { EdgeAddressResolver.resolve(target.host, effectiveDoh) }.getOrNull()
                    val extra = buildList {
                        dialedIp?.let { add(it) }
                        upstreamProxyConfig?.let { p ->
                            runCatching { EdgeAddressResolver.resolve(p.host, effectiveDoh) }.getOrNull()?.let { add(it) }
                        }
                    }
                    if (extra.isNotEmpty() && TunBackend.addBypass(extra)) {
                        AppLogger.i(TAG, "added bypass routes for the dialed edge: $extra")
                    }
                }
                AppLogger.i(TAG, "connect: upstream HTTP/2 tunnel established to ${target.authority}")
                return session to pass.expiresAtEpochSeconds
            }

            var currentPassExpiry: Long? = null
            var dialAttempt = 0
            var lastDialFailure: Throwable? = null
            while (true) {
                dialAttempt++
                ensureGenerationCurrent(myGeneration)
                val target = activeCandidate()

                val dialResult = try {
                    withTimeout(CONNECT_TIMEOUT_MS) { dialUpstream() }
                } catch (cancellation: CancellationException) {
                    if (cancellation !is TimeoutCancellationException) throw cancellation
                    lastDialFailure = cancellation
                    AppLogger.w(TAG, "dial to ${target.authority} timed out (attempt $dialAttempt)")
                    null
                } catch (error: Throwable) {
                    if (isFatalUpstreamError(error)) throw error
                    lastDialFailure = error
                    AppLogger.w(TAG, "dial to ${target.authority} failed (attempt $dialAttempt): ${error.message}")
                    null
                }

                val session = dialResult?.first
                currentPassExpiry = dialResult?.second

                if (session != null) {
                    if (myGeneration != connectionGeneration) {
                        runCatching { session.close() }
                        ensureGenerationCurrent(myGeneration)
                    }
                    upstreamSession = session
                    delay(INITIAL_DIAL_SETTLE_MS)
                    if (upstreamSession?.isConnected == true) break
                    AppLogger.w(
                        TAG,
                        "upstream tunnel to ${target.authority} died immediately after connecting " +
                            "(attempt $dialAttempt/$INITIAL_DIAL_MAX_ATTEMPTS)",
                    )
                    runCatching { upstreamSession?.close() }
                    upstreamSession = null

                    lastDialFailure = null
                }

                if (dialAttempt >= INITIAL_DIAL_MAX_ATTEMPTS) {
                    val (failures, cleared) = proxyStateStore.recordFailure()
                    if (cleared) {
                        AppLogger.w(
                            TAG,
                            "the saved location failed $failures connects in a row; clearing it so the next " +
                                "connect auto-selects a location",
                        )
                    }
                    val failure = lastDialFailure
                    if (failure != null) {
                        error(
                            "Could not reach a VPN server after $dialAttempt attempts across " +
                                "${candidates.size} server(s). Last error: ${friendlyErrorMessage(failure)}",
                        )
                    }
                    error(
                        "The VPN server closed the connection immediately, $dialAttempt times in a row. " +
                            "Try again shortly or pick a different location.",
                    )
                }

                rotateCandidate()
                delay(fullJitterBackoffMs(dialAttempt - 1, INITIAL_DIAL_BACKOFF_BASE_MS, INITIAL_DIAL_BACKOFF_CAP_MS))
            }

            ensureGenerationCurrent(myGeneration)

            val establishedCandidate = activeCandidate()

            if (establishedCandidate.authority == primaryCandidate.authority) {
                proxyStateStore.save(primaryCandidate)
            }

            val connectedText = connectedLabel()
            _state.value = ConnectionState.CONNECTED
            statusLabel = connectedText
            AppLogger.i(TAG, "connect: CONNECTED via ${establishedCandidate.authority}")

            startProxyPassRenewal(myGeneration, tokenStore, currentPassExpiry)

            if (settingsStore.exitCheckEnabled) {
                scope.launch {
                    ExitCheck().verifyExitCountry(socksPort, establishedCandidate.countryCode)
                        .onSuccess { observed ->
                            if (myGeneration == connectionGeneration) {
                                AppLogger.i(TAG, "exit check: observed country=$observed")
                            }
                        }
                        .onFailure { AppLogger.w(TAG, "exit check failed (non-fatal)", it) }
                }
            }

            startSpeedUpdates()

            watchdogJob = scope.launch {
                var consecutiveFailures = 0

                suspend fun stopWithFatalError(message: String) {
                    AppLogger.e(TAG, "unrecoverable upstream failure; disconnecting: $message")
                    _lastError.value = message
                    connectionGeneration++
                    watchdogJob = null
                    _state.value = ConnectionState.DISCONNECTED
                    val doomed = detachResources()
                    opMutex.withLock { releaseResources(doomed, stopSystemTunnel = true) }
                }

                while (scope.isActive) {
                    delay(UPSTREAM_WATCHDOG_INTERVAL_MS)
                    val current = upstreamSession
                    if (current != null && current.isConnected) {
                        if (consecutiveFailures > 0) {
                            AppLogger.i(TAG, "upstream tunnel is healthy again")
                            _lastError.value = null
                            statusLabel = connectedLabel()
                        }
                        consecutiveFailures = 0
                        continue
                    }

                    AppLogger.w(TAG, "upstream tunnel is down; attempting to reconnect")
                    runCatching { current?.close() }
                    statusLabel = "Reconnecting…"

                    val dialResult = try {
                        withTimeout(CONNECT_TIMEOUT_MS) { dialUpstream() }
                    } catch (cancellation: CancellationException) {
                        if (cancellation !is TimeoutCancellationException) throw cancellation
                        consecutiveFailures++
                        AppLogger.w(TAG, "upstream reconnect attempt $consecutiveFailures timed out")
                        null
                    } catch (error: Throwable) {
                        if (isFatalUpstreamError(error)) {
                            stopWithFatalError(friendlyErrorMessage(error))
                            return@launch
                        }
                        consecutiveFailures++
                        AppLogger.w(TAG, "upstream reconnect attempt $consecutiveFailures failed: ${error.message}")
                        null
                    }
                    val fresh = dialResult?.first
                    currentPassExpiry = dialResult?.second

                    if (fresh == null) {
                        if (consecutiveFailures % RECONNECT_FAILURES_BEFORE_EDGE_ROTATION == 0) {
                            rotateCandidate()
                        }

                        if (consecutiveFailures == RECONNECT_FAILURES_BEFORE_WARNING) {
                            _lastError.value =
                                "Still trying to reconnect to the VPN server. Press Disconnect to stop."
                            AppLogger.e(
                                TAG,
                                "$consecutiveFailures consecutive reconnect failures; continuing to retry with backoff " +
                                    "(capped at ${RECONNECT_BACKOFF_CAP_MS / 1_000}s between attempts)",
                            )
                        }
                        delay(fullJitterBackoffMs(consecutiveFailures - 1, RECONNECT_BACKOFF_BASE_MS, RECONNECT_BACKOFF_CAP_MS))
                        continue
                    }

                    if (myGeneration != connectionGeneration) {
                        AppLogger.i(TAG, "discarding stale reconnect from a torn-down session generation")
                        runCatching { fresh.close() }
                        return@launch
                    }
                    upstreamSession = fresh
                    consecutiveFailures = 0
                    _lastError.value = null

                    statusLabel = connectedLabel()
                    AppLogger.i(TAG, "upstream tunnel reconnected via ${activeCandidate().authority}")

                    startProxyPassRenewal(myGeneration, tokenStore, currentPassExpiry)
                }
            }
        }.onFailure { failure ->
            if (failure is CancellationException) {
                AppLogger.i(TAG, "connect: aborted because the connection was cancelled")
                releaseResources(detachResources(), stopSystemTunnel = true)
                return@onFailure
            }
            val message = if (failure is TimeoutCancellationException) {
                "Connection timed out. Check your network and try again."
            } else {
                friendlyErrorMessage(failure)
            }
            AppLogger.e(TAG, "connect failed", failure)
            _lastError.value = message
            connectionGeneration++
            releaseResources(detachResources(), stopSystemTunnel = true)
            _state.value = ConnectionState.DISCONNECTED
        }
        connectJob = null
    }

    private suspend fun resolveConnectCandidate(proxyStateStore: ProxyStateStore): ProxyCandidate {
        proxyStateStore.load()?.let { return it }
        AppLogger.i(TAG, "connect: no server previously selected; auto-selecting recommended location")
        val countries = withTimeout(SERVER_LIST_FETCH_TIMEOUT_MS) { ServerListClient().fetchCountries() }
        val recommended = ServerListClient.candidatesForCountry(countries, RECOMMENDED_COUNTRY_CODE).randomOrNull()
        val chosen = recommended ?: countries.firstOrNull { it.code.isNotBlank() }?.let { country ->
            ServerListClient.candidatesForCountry(countries, country.code).randomOrNull()
        } ?: error("No server selected and no servers are available. Choose a location first.")
        proxyStateStore.save(chosen)
        AppLogger.i(TAG, "connect: auto-selected ${chosen.authority} country=${chosen.countryCode}")
        return chosen
    }

    private suspend fun discoverAlternateCandidates(primary: ProxyCandidate): List<ProxyCandidate> {
        val attempt = runCatching {
            val countries = withTimeout(SERVER_LIST_FETCH_TIMEOUT_MS) { ServerListClient().fetchCountries() }
            val sameCity = ServerListClient.candidatesForCity(countries, primary.countryCode, primary.cityCode)
            val sameCountry = ServerListClient.candidatesForCountry(countries, primary.countryCode)
            (sameCity + sameCountry)
                .distinctBy { it.authority }
                .filter { it.authority != primary.authority }
        }
        val failure = attempt.exceptionOrNull()
        if (failure is CancellationException && failure !is TimeoutCancellationException) throw failure
        if (failure != null) {
            AppLogger.w(TAG, "could not fetch alternate edges; staying with ${primary.authority}", failure)
            return emptyList()
        }
        return attempt.getOrDefault(emptyList())
    }

    private suspend fun resolveEdgeAddress(
        host: String,
        upstreamProxy: UpstreamProxyConfig?,
        dohEndpointAddresses: List<String>,
    ): String? {
        if (upstreamProxy != null) return null
        if (dohEndpointAddresses.isEmpty()) return null
        return EdgeAddressResolver.resolve(host, dohEndpointAddresses)
    }

    private fun friendlyErrorMessage(error: Throwable): String = when (error) {
        is QuotaExceededError -> "Your VPN quota is exhausted. Try again later."
        is TokenInvalidError -> "Your session was rejected. Please sign in again."
        is TimeoutCancellationException -> "the connection timed out"
        else -> error.message ?: (error::class.simpleName ?: "Connection failed")
    }

    private fun detachResources(): SessionResources {
        speedJob?.cancel()
        speedJob = null

        tokenRenewalJob?.cancel()
        tokenRenewalJob = null
        val detached = SessionResources(socksServer, httpServer, upstreamSession)
        socksServer = null
        httpServer = null
        upstreamSession = null
        return detached
    }

    private fun releaseResources(resources: SessionResources, stopSystemTunnel: Boolean) {
        if (resources.isEmpty && !stopSystemTunnel) return
        if (stopSystemTunnel) {
            if (tunActive) {
                runCatching { TunBackend.stop() }
                    .onFailure { AppLogger.w(TAG, "error stopping tun2socks tunnel", it) }
                tunActive = false
            }
            if (systemProxyActive) {
                runCatching { SystemProxy.stop() }
                    .onFailure { AppLogger.w(TAG, "error clearing the system proxy", it) }
                systemProxyActive = false
            }
        }
        runCatching { resources.socksServer?.stop() }.onFailure { AppLogger.w(TAG, "error stopping local SOCKS5 server", it) }
        runCatching { resources.httpServer?.stop() }.onFailure { AppLogger.w(TAG, "error stopping local HTTP proxy server", it) }
        runCatching { resources.upstreamSession?.close() }.onFailure { AppLogger.w(TAG, "error closing upstream session", it) }
    }

    private fun startSpeedUpdates() {
        speedJob?.cancel()
        speedJob = scope.launch {
            var lastTx = 0L
            var lastRx = 0L
            var lastSampleAt = System.currentTimeMillis()
            while (scope.isActive) {
                delay(SPEED_UPDATE_INTERVAL_MS)
                TunBackend.beat()
                val socks = socksServer ?: break
                val now = System.currentTimeMillis()
                val elapsedSeconds = ((now - lastSampleAt).coerceAtLeast(1)).toDouble() / 1_000.0
                val tx = socks.bytesWritten.get()
                val rx = socks.bytesRead.get()
                val txRate = ((tx - lastTx).coerceAtLeast(0) / elapsedSeconds).toLong()
                val rxRate = ((rx - lastRx).coerceAtLeast(0) / elapsedSeconds).toLong()
                lastTx = tx
                lastRx = rx
                lastSampleAt = now
                if (_state.value != ConnectionState.CONNECTED) continue
                AppLogger.d(TAG, "$statusLabel \u2193 ${formatBytesPerSecond(rxRate)} \u2191 ${formatBytesPerSecond(txRate)}")
            }
        }
    }
}
