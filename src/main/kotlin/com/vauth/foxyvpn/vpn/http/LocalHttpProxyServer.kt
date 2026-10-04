package com.vauth.foxyvpn.vpn.http

import com.vauth.foxyvpn.data.AppLogger
import com.vauth.foxyvpn.vpn.RelayDispatchers
import com.vauth.foxyvpn.vpn.upstream.TunneledStream
import com.vauth.foxyvpn.vpn.upstream.UpstreamSession
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.withTimeoutOrNull
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.concurrent.atomic.AtomicLong

private const val TAG = "LocalHttpProxyServer"

private const val SESSION_WAIT_TIMEOUT_MS = 4_000L
private const val SESSION_WAIT_POLL_INTERVAL_MS = 100L
private const val OPEN_STREAM_TIMEOUT_MS = 30_000L
private const val HANDSHAKE_TIMEOUT_MS = 10_000
private const val MAX_CONCURRENT_CLIENT_CONNECTIONS = 512
private const val ACCEPT_BACKLOG = 256
private const val ACCEPT_ERROR_BACKOFF_MS = 100L
private const val RELAY_BUFFER_BYTES = 32 * 1024
private const val MAX_REQUEST_LINE_BYTES = 16 * 1024

/**
 * HTTP/1.1 forwarding proxy for devices that cannot speak SOCKS — iOS configuration
 * profiles only offer an HTTP proxy, so the phone points here and every CONNECT or
 * absolute-URI request is carried through the same [UpstreamSession] the SOCKS5 server uses.
 */
class LocalHttpProxyServer(
    private val bindAddress: String,
    private val port: Int,
    private val sessionProvider: () -> UpstreamSession?,
) {
    private var serverSocket: ServerSocket? = null

    private val exceptionHandler = CoroutineExceptionHandler { _, throwable ->
        AppLogger.w(TAG, "unhandled exception in an HTTP proxy coroutine (connection dropped)", throwable)
    }
    private val scope = CoroutineScope(RelayDispatchers.relay + SupervisorJob() + exceptionHandler)
    private val connectionSlots = Semaphore(MAX_CONCURRENT_CLIENT_CONNECTIONS)

    val bytesWritten = AtomicLong(0)
    val bytesRead = AtomicLong(0)

    fun start() {
        val server = ServerSocket()
        runCatching { server.reuseAddress = true }
        server.bind(InetSocketAddress(InetAddress.getByName(bindAddress), port), ACCEPT_BACKLOG)
        serverSocket = server
        scope.launch {
            while (!server.isClosed) {
                val accepted = runCatching { server.accept() }
                val client = accepted.getOrNull()
                if (client == null) {
                    if (server.isClosed) break
                    AppLogger.d(TAG, "accept() failed on an open listening socket: ${accepted.exceptionOrNull()?.message}")
                    delay(ACCEPT_ERROR_BACKOFF_MS)
                    continue
                }
                runCatching { client.tcpNoDelay = true }
                if (!connectionSlots.tryAcquire()) {
                    AppLogger.w(TAG, "rejecting HTTP client: connection limit ($MAX_CONCURRENT_CLIENT_CONNECTIONS) reached")
                    runCatching { client.close() }
                    continue
                }
                scope.launch {
                    try {
                        handleClient(client)
                    } finally {
                        connectionSlots.release()
                    }
                }
            }
        }
    }

    fun stop() {
        runCatching { serverSocket?.close() }
        scope.cancel()
    }

    private suspend fun handleClient(client: Socket) {
        try {
            handleClientOrThrow(client)
        } catch (e: EOFException) {
            AppLogger.d(TAG, "HTTP client disconnected before completing its request (EOF)")
        } catch (e: SocketException) {
            AppLogger.d(TAG, "HTTP client socket closed unexpectedly: ${e.message}")
        } catch (e: IOException) {
            AppLogger.d(TAG, "I/O error handling HTTP client: ${e.message}")
        }
    }

    private suspend fun handleClientOrThrow(client: Socket) {
        client.use { socket ->
            socket.soTimeout = HANDSHAKE_TIMEOUT_MS
            val input = DataInputStream(socket.getInputStream())
            val output = socket.getOutputStream()

            val requestLine = readLine(input) ?: return
            if (requestLine.isBlank()) return
            val parts = requestLine.split(" ")
            if (parts.size < 3) {
                respond(output, 400, "Bad Request")
                return
            }
            val method = parts[0].uppercase()
            val target = parts[1]
            val headers = readHeaders(input)

            if (method == "CONNECT") {
                val endpoint = parseAuthority(target, defaultPort = 443)
                if (endpoint == null) {
                    respond(output, 400, "Bad Request")
                    return
                }
                socket.soTimeout = 0
                val stream = openTunneledStream(endpoint) ?: run {
                    respond(output, 502, "Bad Gateway")
                    return
                }
                relayTunnel(socket, output, stream)
                return
            }

            val request = parseForwardableRequest(method, target)
            if (request == null) {
                AppLogger.d(TAG, "refusing non-proxy request line: $method $target")
                respond(output, 400, "Bad Request")
                return
            }
            socket.soTimeout = 0
            val stream = openTunneledStream(request.endpoint) ?: run {
                respond(output, 502, "Bad Gateway")
                return
            }
            relayPlainRequest(request.method, request.originForm, headers, socket, output, stream)
        }
    }

    private data class ForwardableRequest(
        val method: String,
        val originForm: String,
        val endpoint: Pair<String, Int>,
    )

    private suspend fun openTunneledStream(endpoint: Pair<String, Int>): TunneledStream? {
        val session = awaitUsableSession() ?: return null
        return runCatching {
            withTimeoutOrNull(OPEN_STREAM_TIMEOUT_MS) { session.openStream(endpoint.first, endpoint.second) }
        }.getOrNull().also {
            if (it == null) AppLogger.d(TAG, "upstream open failed for ${endpoint.first}:${endpoint.second}")
        }
    }

    private suspend fun awaitUsableSession(): UpstreamSession? {
        val deadline = System.currentTimeMillis() + SESSION_WAIT_TIMEOUT_MS
        while (true) {
            val session = sessionProvider()
            if (session != null && session.isConnected) return session
            if (System.currentTimeMillis() >= deadline) return null
            delay(SESSION_WAIT_POLL_INTERVAL_MS)
        }
    }

    /** HTTPS: answer 200 and blind-pipe TLS bytes in both directions. */
    private suspend fun relayTunnel(
        socket: Socket,
        output: OutputStream,
        stream: TunneledStream,
    ) {
        output.write("HTTP/1.1 200 Connection established\r\n\r\n".toByteArray(Charsets.US_ASCII))
        output.flush()

        val clientToUpstream = scope.launch {
            runCatching { countCopy(socket.getInputStream(), stream.output, bytesWritten) }
            runCatching { stream.output.close() }
        }
        runCatching { countCopy(stream.input, output, bytesRead) }
        runCatching { socket.shutdownOutput() }
        if (clientToUpstream.isActive) {
            val drained = withTimeoutOrNull(120_000L) { clientToUpstream.join() }
            if (drained == null) {
                runCatching { socket.close() }
                runCatching { stream.close() }
            }
        }
        stream.close()
    }

    /** Plain HTTP: rewrite the absolute URI to origin-form, drop hop-by-hop headers, pipe. */
    private suspend fun relayPlainRequest(
        method: String,
        originForm: String,
        headers: List<String>,
        socket: Socket,
        output: OutputStream,
        stream: TunneledStream,
    ) {
        val builder = StringBuilder()
        builder.append(method).append(' ').append(originForm).append(" HTTP/1.1\r\n")
        for (header in headers) {
            val name = header.substringBefore(':')
            if (name.equals("Proxy-Connection", ignoreCase = true)) continue
            builder.append(header).append("\r\n")
        }
        builder.append("\r\n")
        runCatching { stream.output.write(builder.toString().toByteArray(Charsets.UTF_8)) }
        runCatching { stream.output.flush() }

        val clientToUpstream = scope.launch {
            runCatching { countCopy(socket.getInputStream(), stream.output, bytesWritten) }
            runCatching { stream.output.close() }
        }
        runCatching { countCopy(stream.input, output, bytesRead) }
        runCatching { socket.shutdownOutput() }
        if (clientToUpstream.isActive) {
            withTimeoutOrNull(120_000L) { clientToUpstream.join() }
        }
        stream.close()
    }

    private fun readHeaders(input: DataInputStream): List<String> {
        val headers = mutableListOf<String>()
        while (true) {
            val line = readLine(input) ?: break
            if (line.isEmpty()) break
            headers.add(line)
        }
        return headers
    }

    private fun readLine(input: DataInputStream): String? {
        val bytes = ByteArrayOutputStream(MAX_REQUEST_LINE_BYTES)
        var consumed = 0
        while (true) {
            val b = input.read()
            if (b < 0) {
                if (consumed == 0) return null
                break
            }
            consumed++
            if (b == '\r'.code) continue
            if (b == '\n'.code) break
            if (consumed > MAX_REQUEST_LINE_BYTES) {
                AppLogger.d(TAG, "HTTP request line exceeds ${MAX_REQUEST_LINE_BYTES} bytes")
                return null
            }
            bytes.write(b)
        }
        return String(bytes.buf, 0, bytes.count, Charsets.ISO_8859_1)
    }

    private class ByteArrayOutputStream(private val limit: Int) {
        var buf = ByteArray(1024)
        var count = 0
        fun write(b: Int) {
            if (count + 1 > buf.size) buf = buf.copyOf(minOf(buf.size * 2, limit + 1))
            buf[count++] = b.toByte()
        }
    }

    private fun respond(output: OutputStream, status: Int, reason: String) {
        runCatching {
            val body = "<html><body>$reason</body></html>".toByteArray(Charsets.UTF_8)
            val head = "HTTP/1.1 $status $reason\r\nContent-Type: text/html\r\n" +
                "Content-Length: ${body.size}\r\nConnection: close\r\n\r\n"
            output.write(head.toByteArray(Charsets.US_ASCII))
            output.write(body)
            output.flush()
        }
    }

    private fun countCopy(from: java.io.InputStream, to: OutputStream, counter: AtomicLong): Long {
        val buffer = ByteArray(RELAY_BUFFER_BYTES)
        var total = 0L
        while (true) {
            val read = from.read(buffer)
            if (read < 0) break
            to.write(buffer, 0, read)
            total += read
        }
        to.flush()
        counter.addAndGet(total)
        return total
    }

    private fun parseAuthority(value: String, defaultPort: Int): Pair<String, Int>? {
        val rest = value.removePrefix("//")
        if (rest.startsWith("[")) {
            val close = rest.indexOf(']')
            if (close < 0) return null
            val host = rest.substring(1, close)
            val tail = rest.substring(close + 1)
            val port = if (tail.startsWith(":")) tail.substring(1).toIntOrNull() else defaultPort
            if (host.isBlank() || port == null || port !in 1..65_535) return null
            return host to port
        }
        val colon = rest.lastIndexOf(':')
        if (colon >= 0) {
            val host = rest.substring(0, colon)
            val port = rest.substring(colon + 1).toIntOrNull()
            if (host.isBlank() || port == null || port !in 1..65_535) return null
            return host to port
        }
        if (rest.isBlank()) return null
        return rest to defaultPort
    }

    private fun parseForwardableRequest(method: String, target: String): ForwardableRequest? {
        if (!target.regionMatches(0, "http://", 0, 7, ignoreCase = true) &&
            !target.regionMatches(0, "https://", 0, 8, ignoreCase = true)
        ) {
            return null
        }
        val schemeEnd = target.indexOf(':')
        val scheme = target.substring(0, schemeEnd).lowercase()
        val defaultPort = if (scheme == "http") 80 else 443
        val afterScheme = target.substring(schemeEnd + 1).removePrefix("//")
        val slash = afterScheme.indexOf('/')
        val authority = if (slash < 0) afterScheme else afterScheme.substring(0, slash)
        val originForm = if (slash < 0) "/" else afterScheme.substring(slash)
        val endpoint = parseAuthority(authority, defaultPort) ?: return null
        return ForwardableRequest(method, originForm, endpoint)
    }
}
