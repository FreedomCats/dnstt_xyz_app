package xyz.dnstt.app

import android.util.Log
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Local SOCKS5 relay that authenticates to the upstream SOCKS5 proxy on behalf of its clients.
 *
 * The tunnel client (dnstt or slipstream) forwards raw TCP to the server, which forwards it to
 * a SOCKS5 proxy. When that proxy requires username/password authentication (RFC 1929), local
 * clients (the VPN TCP stack, the tunnel verification, OkHttp tests, other apps in proxy mode)
 * connect to this relay instead. The relay accepts them without auth (or with any credentials),
 * reads the client's request, performs the handshake with the upstream proxy and then passes
 * the rest of the stream through unchanged.
 *
 * The upstream greeting, credentials and the client's request are sent in one write, so the
 * extra authentication step costs no additional round trip through the DNS tunnel. Some proxies
 * (microsocks, for example) handle each read as one message and drop the bytes that follow it.
 * When the proxy accepts username/password auth but the pipelined handshake does not complete,
 * the relay retries the connection step by step, and keeps doing so for later connections once
 * that works.
 */
class Socks5AuthRelay(
    private val bindHost: String,
    private val bindPort: Int,
    private val upstreamHost: String,
    private val upstreamPort: Int,
    username: String,
    password: String,
    private val handshakeTimeoutMs: Int = HANDSHAKE_TIMEOUT_MS,
    private val pipelineGraceMs: Int = PIPELINE_GRACE_MS
) {
    companion object {
        private const val TAG = "Socks5AuthRelay"
        private const val SOCKS_VERSION = 0x05
        private const val AUTH_NONE = 0x00
        private const val AUTH_USERNAME = 0x02
        private const val AUTH_NO_ACCEPTABLE = 0xFF
        private const val AUTH_SUBNEGOTIATION_VERSION = 0x01
        private const val ATYP_IPV4 = 0x01
        private const val ATYP_DOMAIN = 0x03
        private const val ATYP_IPV6 = 0x04
        private const val REPLY_GENERAL_FAILURE = 0x01
        private const val REPLY_ADDRESS_TYPE_NOT_SUPPORTED = 0x08
        private const val CONNECT_TIMEOUT_MS = 10000
        // The upstream replies travel through the DNS tunnel, which can be slow
        private const val HANDSHAKE_TIMEOUT_MS = 60000
        // A pipelined auth reply follows the method reply almost at once; a proxy that dropped
        // the credentials sends nothing, so stop waiting after this (or 3x the method reply time)
        private const val PIPELINE_GRACE_MS = 3000
        private const val BUFFER_SIZE = 32768

        /** Finds a free TCP port on localhost for the tunnel client to listen on behind the relay. */
        fun findFreePort(): Int {
            ServerSocket(0, 0, InetAddress.getByName("127.0.0.1")).use { return it.localPort }
        }
    }

    /** Upstream handshake failure. [methodAccepted]: the proxy had chosen username/password auth. */
    private class HandshakeException(message: String, val methodAccepted: Boolean) : IOException(message)

    private class UpstreamConnection(val socket: Socket, val reply: ByteArray)

    // Greeting offering only username/password auth: VER(5) NMETHODS(1) METHOD(2)
    private val greeting = byteArrayOf(SOCKS_VERSION.toByte(), 1, AUTH_USERNAME.toByte())
    // RFC 1929 request: VER(1) ULEN UNAME PLEN PASSWD
    private val credentials: ByteArray
    private var serverSocket: ServerSocket? = null
    private var executor: ExecutorService? = null
    private val openSockets: MutableSet<Socket> = ConcurrentHashMap.newKeySet()

    @Volatile
    private var running = false

    // Cleared once the upstream proxy turns out to need a step-by-step handshake
    @Volatile
    private var pipelining = true

    init {
        val usernameBytes = username.toByteArray(Charsets.UTF_8)
        val passwordBytes = password.toByteArray(Charsets.UTF_8)
        require(usernameBytes.isNotEmpty() && usernameBytes.size <= 255) { "Invalid SOCKS5 username length" }
        require(passwordBytes.size <= 255) { "Invalid SOCKS5 password length" }

        credentials = byteArrayOf(AUTH_SUBNEGOTIATION_VERSION.toByte(), usernameBytes.size.toByte()) +
            usernameBytes +
            byteArrayOf(passwordBytes.size.toByte()) +
            passwordBytes
    }

    val isRunning: Boolean get() = running

    fun start(): Boolean {
        if (running) return true
        return try {
            val server = ServerSocket()
            server.reuseAddress = true
            server.bind(InetSocketAddress(InetAddress.getByName(bindHost), bindPort))
            serverSocket = server
            executor = Executors.newCachedThreadPool()
            running = true
            executor?.execute { acceptLoop(server) }
            Log.i(TAG, "Relay listening on $bindHost:$bindPort, upstream $upstreamHost:$upstreamPort")
            true
        } catch (e: IOException) {
            Log.e(TAG, "Failed to start relay on $bindHost:$bindPort", e)
            stop()
            false
        }
    }

    fun stop() {
        running = false
        try {
            serverSocket?.close()
        } catch (e: IOException) {
            // Ignore
        }
        serverSocket = null
        openSockets.forEach { closeQuietly(it) }
        openSockets.clear()
        executor?.shutdownNow()
        executor = null
    }

    private fun acceptLoop(server: ServerSocket) {
        while (running) {
            try {
                val client = server.accept()
                openSockets.add(client)
                try {
                    executor?.execute { handleClient(client) } ?: closeQuietly(client)
                } catch (e: Exception) {
                    closeQuietly(client)
                }
            } catch (e: IOException) {
                if (running) Log.e(TAG, "Accept failed", e)
            }
        }
    }

    private fun handleClient(client: Socket) {
        var upstream: Socket? = null
        try {
            client.tcpNoDelay = true
            client.soTimeout = handshakeTimeoutMs
            val clientIn = client.getInputStream()
            val clientOut = client.getOutputStream()

            if (!negotiateWithClient(clientIn, clientOut)) {
                close(client)
                return
            }

            val request = readSocksMessage(clientIn)
            if (request == null || request[0].toInt() != SOCKS_VERSION) {
                Log.w(TAG, "Unsupported SOCKS5 request from client")
                sendFailure(clientOut, REPLY_ADDRESS_TYPE_NOT_SUPPORTED)
                close(client)
                return
            }

            val connection = try {
                connectUpstream(request)
            } catch (e: IOException) {
                if (running) Log.e(TAG, "Upstream SOCKS5 ${e.message}")
                sendFailure(clientOut, REPLY_GENERAL_FAILURE)
                close(client)
                return
            }
            val sock = connection.socket
            upstream = sock

            clientOut.write(connection.reply)
            clientOut.flush()
            if (connection.reply[1].toInt() != 0x00) {
                // The upstream proxy refused the request; it has already told the client why
                close(client, sock)
                return
            }

            // The handshake is over: no read timeouts while relaying
            client.soTimeout = 0
            sock.soTimeout = 0

            val upstreamIn = sock.getInputStream()
            val upstreamOut = sock.getOutputStream()
            val pending = AtomicInteger(2)
            val executor = executor ?: throw IOException("Relay stopped")
            executor.execute {
                pump(clientIn, upstreamOut, sock)
                if (pending.decrementAndGet() == 0) close(client, sock)
            }
            pump(upstreamIn, clientOut, client)
            if (pending.decrementAndGet() == 0) close(client, sock)
        } catch (e: Exception) {
            // Any exception escaping a pool thread would crash the app
            if (running) Log.w(TAG, "Relay connection failed: ${e.message}")
            close(client, upstream)
        }
    }

    /** Accepts the local client without auth, or with any credentials if it only offers username/password. */
    private fun negotiateWithClient(input: InputStream, output: OutputStream): Boolean {
        val header = readFully(input, 2)
        if (header[0].toInt() != SOCKS_VERSION) {
            Log.w(TAG, "Unsupported SOCKS version from client: ${header[0]}")
            return false
        }
        val methods = readFully(input, header[1].toInt() and 0xFF).map { it.toInt() and 0xFF }

        when {
            AUTH_NONE in methods -> {
                output.write(byteArrayOf(SOCKS_VERSION.toByte(), AUTH_NONE.toByte()))
                output.flush()
            }
            AUTH_USERNAME in methods -> {
                output.write(byteArrayOf(SOCKS_VERSION.toByte(), AUTH_USERNAME.toByte()))
                output.flush()
                // Read and discard the client's credentials: the relay uses the configured ones
                readFully(input, 1)
                readFully(input, readFully(input, 1)[0].toInt() and 0xFF)
                readFully(input, readFully(input, 1)[0].toInt() and 0xFF)
                output.write(byteArrayOf(AUTH_SUBNEGOTIATION_VERSION.toByte(), 0x00))
                output.flush()
            }
            else -> {
                output.write(byteArrayOf(SOCKS_VERSION.toByte(), AUTH_NO_ACCEPTABLE.toByte()))
                output.flush()
                return false
            }
        }
        return true
    }

    /** Opens an authenticated upstream connection and sends [request] on it. */
    private fun connectUpstream(request: ByteArray): UpstreamConnection {
        if (!pipelining) return handshake(request, pipelined = false)
        try {
            return handshake(request, pipelined = true)
        } catch (e: HandshakeException) {
            if (!e.methodAccepted) throw e
            if (running) Log.w(TAG, "Pipelined SOCKS5 handshake failed (${e.message}), retrying step by step")
        }
        val connection = handshake(request, pipelined = false)
        if (pipelining) {
            pipelining = false
            Log.i(TAG, "Upstream SOCKS5 proxy needs a step-by-step handshake, pipelining disabled")
        }
        return connection
    }

    private fun handshake(request: ByteArray, pipelined: Boolean): UpstreamConnection {
        val socket = Socket()
        openSockets.add(socket)
        var methodAccepted = false
        try {
            socket.tcpNoDelay = true
            socket.connect(InetSocketAddress(upstreamHost, upstreamPort), CONNECT_TIMEOUT_MS)
            socket.soTimeout = handshakeTimeoutMs
            val input = socket.getInputStream()
            val output = socket.getOutputStream()

            val startTime = System.currentTimeMillis()
            output.write(if (pipelined) greeting + credentials + request else greeting)
            output.flush()

            val methodReply = readFully(input, 2)
            val method = methodReply[1].toInt() and 0xFF
            if (methodReply[0].toInt() != SOCKS_VERSION || method != AUTH_USERNAME) {
                throw HandshakeException("proxy did not accept username/password auth (method=$method)", false)
            }
            methodAccepted = true

            if (pipelined) {
                val elapsed = (System.currentTimeMillis() - startTime).toInt()
                socket.soTimeout = minOf(handshakeTimeoutMs, maxOf(pipelineGraceMs, elapsed * 3))
            } else {
                output.write(credentials)
                output.flush()
            }
            val authReply = readFully(input, 2)
            if (authReply[1].toInt() != 0x00) {
                throw HandshakeException("authentication failed (status=${authReply[1]})", true)
            }
            socket.soTimeout = handshakeTimeoutMs

            if (!pipelined) {
                output.write(request)
                output.flush()
            }
            val reply = readSocksMessage(input)
            if (reply == null || reply[0].toInt() != SOCKS_VERSION) {
                throw HandshakeException("proxy sent an invalid reply", true)
            }
            return UpstreamConnection(socket, reply)
        } catch (e: IOException) {
            close(socket)
            if (e is HandshakeException) throw e
            throw HandshakeException("handshake failed: ${e.message}", methodAccepted)
        }
    }

    /** Reads a SOCKS5 request or reply (both share one layout); null for an unknown address type. */
    private fun readSocksMessage(input: InputStream): ByteArray? {
        val header = readFully(input, 4)
        val address = when (header[3].toInt()) {
            ATYP_IPV4 -> readFully(input, 4)
            ATYP_IPV6 -> readFully(input, 16)
            ATYP_DOMAIN -> {
                val length = readFully(input, 1)
                length + readFully(input, length[0].toInt() and 0xFF)
            }
            else -> return null
        }
        return header + address + readFully(input, 2)
    }

    private fun sendFailure(output: OutputStream, reply: Int) {
        try {
            output.write(byteArrayOf(SOCKS_VERSION.toByte(), reply.toByte(), 0x00, ATYP_IPV4.toByte(), 0, 0, 0, 0, 0, 0))
            output.flush()
        } catch (e: IOException) {
            // The client is gone
        }
    }

    private fun pump(input: InputStream, output: OutputStream, destination: Socket) {
        val buffer = ByteArray(BUFFER_SIZE)
        try {
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                output.write(buffer, 0, n)
                output.flush()
            }
            // Propagate EOF so half-closed connections keep working
            destination.shutdownOutput()
        } catch (e: Exception) {
            closeQuietly(destination)
        }
    }

    private fun readFully(input: InputStream, length: Int): ByteArray {
        val data = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val n = input.read(data, offset, length - offset)
            if (n < 0) throw IOException("Unexpected end of stream")
            offset += n
        }
        return data
    }

    private fun close(vararg sockets: Socket?) {
        sockets.forEach { socket ->
            if (socket != null) {
                closeQuietly(socket)
                openSockets.remove(socket)
            }
        }
    }

    private fun closeQuietly(socket: Socket) {
        try {
            socket.close()
        } catch (e: IOException) {
            // Ignore
        }
    }
}
