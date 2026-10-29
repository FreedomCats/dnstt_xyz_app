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
 * performs the username/password sub-negotiation with the upstream proxy and then passes the
 * rest of the stream (the client's request and all data) through unchanged.
 *
 * The upstream greeting and credentials are sent together right after accepting a client, and
 * the client's request is forwarded without waiting for the upstream auth reply, so the extra
 * authentication step costs no additional round trip through the DNS tunnel.
 */
class Socks5AuthRelay(
    private val bindHost: String,
    private val bindPort: Int,
    private val upstreamHost: String,
    private val upstreamPort: Int,
    username: String,
    password: String
) {
    companion object {
        private const val TAG = "Socks5AuthRelay"
        private const val SOCKS_VERSION = 0x05
        private const val AUTH_NONE = 0x00
        private const val AUTH_USERNAME = 0x02
        private const val AUTH_NO_ACCEPTABLE = 0xFF
        private const val AUTH_SUBNEGOTIATION_VERSION = 0x01
        private const val CONNECT_TIMEOUT_MS = 10000
        // The upstream auth reply travels through the DNS tunnel, which can be slow
        private const val HANDSHAKE_TIMEOUT_MS = 60000
        private const val BUFFER_SIZE = 32768

        /** Finds a free TCP port on localhost for the tunnel client to listen on behind the relay. */
        fun findFreePort(): Int {
            ServerSocket(0, 0, InetAddress.getByName("127.0.0.1")).use { return it.localPort }
        }
    }

    private val authRequest: ByteArray
    private var serverSocket: ServerSocket? = null
    private var executor: ExecutorService? = null
    private val openSockets: MutableSet<Socket> = ConcurrentHashMap.newKeySet()

    @Volatile
    private var running = false

    init {
        val usernameBytes = username.toByteArray(Charsets.UTF_8)
        val passwordBytes = password.toByteArray(Charsets.UTF_8)
        require(usernameBytes.isNotEmpty() && usernameBytes.size <= 255) { "Invalid SOCKS5 username length" }
        require(passwordBytes.size <= 255) { "Invalid SOCKS5 password length" }

        // Greeting offering only username/password auth, followed by the RFC 1929 request:
        // VER(5) NMETHODS(1) METHOD(2) | VER(1) ULEN UNAME PLEN PASSWD
        authRequest = byteArrayOf(SOCKS_VERSION.toByte(), 1, AUTH_USERNAME.toByte()) +
            byteArrayOf(AUTH_SUBNEGOTIATION_VERSION.toByte(), usernameBytes.size.toByte()) +
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
            client.soTimeout = HANDSHAKE_TIMEOUT_MS

            val sock = Socket()
            upstream = sock
            openSockets.add(sock)
            sock.tcpNoDelay = true
            sock.connect(InetSocketAddress(upstreamHost, upstreamPort), CONNECT_TIMEOUT_MS)
            sock.soTimeout = HANDSHAKE_TIMEOUT_MS

            val upstreamIn = sock.getInputStream()
            val upstreamOut = sock.getOutputStream()
            val clientIn = client.getInputStream()
            val clientOut = client.getOutputStream()

            // Start upstream authentication while negotiating with the local client
            upstreamOut.write(authRequest)
            upstreamOut.flush()

            if (!negotiateWithClient(clientIn, clientOut)) {
                close(client, sock)
                return
            }

            // Forward the client's request (and any data) right away
            val pending = AtomicInteger(2)
            executor?.execute {
                pump(clientIn, upstreamOut, sock)
                if (pending.decrementAndGet() == 0) close(client, sock)
            } ?: run {
                close(client, sock)
                return
            }

            if (!readUpstreamAuthReply(upstreamIn)) {
                close(client, sock)
                return
            }

            client.soTimeout = 0
            sock.soTimeout = 0
            pump(upstreamIn, clientOut, client)
            if (pending.decrementAndGet() == 0) close(client, sock)
        } catch (e: IOException) {
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

    private fun readUpstreamAuthReply(input: InputStream): Boolean {
        val methodReply = readFully(input, 2)
        val method = methodReply[1].toInt() and 0xFF
        if (methodReply[0].toInt() != SOCKS_VERSION || method != AUTH_USERNAME) {
            Log.e(TAG, "Upstream SOCKS5 proxy did not accept username/password auth (method=$method)")
            return false
        }
        val authReply = readFully(input, 2)
        if (authReply[1].toInt() != 0x00) {
            Log.e(TAG, "Upstream SOCKS5 authentication failed (status=${authReply[1]})")
            return false
        }
        return true
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
        } catch (e: IOException) {
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
