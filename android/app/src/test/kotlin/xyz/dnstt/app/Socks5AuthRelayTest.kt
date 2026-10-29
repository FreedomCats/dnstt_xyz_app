package xyz.dnstt.app

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.DataInputStream
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

class Socks5AuthRelayTest {

    /** Minimal SOCKS5 server that requires username/password auth and echoes data after CONNECT. */
    private class FakeUpstream(private val username: String, private val password: String) {
        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val authAttempts: MutableList<Pair<String, String>> = Collections.synchronizedList(mutableListOf())
        val connectTargets: MutableList<String> = Collections.synchronizedList(mutableListOf())

        init {
            thread(isDaemon = true) {
                while (!server.isClosed) {
                    val socket = try {
                        server.accept()
                    } catch (e: IOException) {
                        break
                    }
                    thread(isDaemon = true) { handle(socket) }
                }
            }
        }

        private fun handle(socket: Socket) {
            socket.use {
                val input = DataInputStream(it.getInputStream())
                val output = it.getOutputStream()
                try {
                    input.readByte()
                    val methods = ByteArray(input.readUnsignedByte()).also { m -> input.readFully(m) }
                    if (!methods.contains(0x02.toByte())) {
                        output.write(byteArrayOf(0x05, 0xFF.toByte()))
                        return
                    }
                    output.write(byteArrayOf(0x05, 0x02))

                    input.readByte()
                    val user = ByteArray(input.readUnsignedByte()).also { u -> input.readFully(u) }
                    val pass = ByteArray(input.readUnsignedByte()).also { p -> input.readFully(p) }
                    authAttempts.add(String(user, Charsets.UTF_8) to String(pass, Charsets.UTF_8))
                    if (String(user, Charsets.UTF_8) != username || String(pass, Charsets.UTF_8) != password) {
                        output.write(byteArrayOf(0x01, 0x01))
                        return
                    }
                    output.write(byteArrayOf(0x01, 0x00))

                    val request = ByteArray(4).also { r -> input.readFully(r) }
                    assertArrayEquals(byteArrayOf(0x05, 0x01, 0x00, 0x03), request)
                    val host = ByteArray(input.readUnsignedByte()).also { h -> input.readFully(h) }
                    val port = input.readUnsignedShort()
                    connectTargets.add("${String(host)}:$port")
                    output.write(byteArrayOf(0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0))

                    // Echo everything else
                    val buffer = ByteArray(1024)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        output.write(buffer, 0, n)
                    }
                } catch (e: IOException) {
                    // Connection closed
                }
            }
        }

        fun close() = server.close()
    }

    /**
     * SOCKS5 server that handles each read as one message and drops the bytes after it, as
     * microsocks does. A pipelined handshake loses the credentials and stalls on it.
     */
    private class MessagePerReadUpstream(private val username: String, private val password: String) {
        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val connections = AtomicInteger()
        val connectTargets: MutableList<String> = Collections.synchronizedList(mutableListOf())

        init {
            thread(isDaemon = true) {
                while (!server.isClosed) {
                    val socket = try {
                        server.accept()
                    } catch (e: IOException) {
                        break
                    }
                    connections.incrementAndGet()
                    thread(isDaemon = true) { handle(socket) }
                }
            }
        }

        private fun handle(socket: Socket) {
            socket.use {
                val input = it.getInputStream()
                val output = it.getOutputStream()
                val buffer = ByteArray(1024)
                var state = 0
                try {
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        when (state) {
                            0 -> {
                                val methods = buffer.copyOfRange(2, 2 + (buffer[1].toInt() and 0xFF))
                                if (!methods.contains(0x02.toByte())) {
                                    output.write(byteArrayOf(0x05, 0xFF.toByte()))
                                    return
                                }
                                output.write(byteArrayOf(0x05, 0x02))
                                state = 1
                            }
                            1 -> {
                                val userLength = buffer[1].toInt() and 0xFF
                                val user = String(buffer, 2, userLength, Charsets.UTF_8)
                                val pass = String(buffer, 3 + userLength, buffer[2 + userLength].toInt() and 0xFF, Charsets.UTF_8)
                                if (buffer[0].toInt() != 0x01 || user != username || pass != password) {
                                    output.write(byteArrayOf(0x01, 0x01))
                                    return
                                }
                                output.write(byteArrayOf(0x01, 0x00))
                                state = 2
                            }
                            2 -> {
                                val hostLength = buffer[4].toInt() and 0xFF
                                val port = (buffer[5 + hostLength].toInt() and 0xFF) shl 8 or (buffer[6 + hostLength].toInt() and 0xFF)
                                connectTargets.add("${String(buffer, 5, hostLength)}:$port")
                                output.write(byteArrayOf(0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
                                state = 3
                            }
                            else -> output.write(buffer, 0, n)
                        }
                    }
                } catch (e: Exception) {
                    // Malformed message or connection closed
                }
            }
        }

        fun close() = server.close()
    }

    private lateinit var upstream: FakeUpstream
    private var relay: Socks5AuthRelay? = null
    private var relayPort = 0

    private fun startRelay(
        username: String,
        password: String,
        upstreamPort: Int = upstream.server.localPort,
        handshakeTimeoutMs: Int = 60000,
        pipelineGraceMs: Int = 3000
    ) {
        relayPort = Socks5AuthRelay.findFreePort()
        relay = Socks5AuthRelay(
            "127.0.0.1", relayPort, "127.0.0.1", upstreamPort, username, password,
            handshakeTimeoutMs, pipelineGraceMs
        )
        assertTrue(relay!!.start())
    }

    /** Connects through the relay without auth and checks that data is echoed back. */
    private fun connectAndPing(host: String, port: Int) {
        Socket("127.0.0.1", relayPort).use { client ->
            client.soTimeout = 5000
            val input = DataInputStream(client.getInputStream())
            val output = client.getOutputStream()

            output.write(byteArrayOf(0x05, 0x01, 0x00))
            assertArrayEquals(byteArrayOf(0x05, 0x00), input.readBytes(2))
            output.write(connectRequest(host, port))
            assertArrayEquals(byteArrayOf(0x05, 0x00), input.readBytes(10).copyOf(2))
            output.write("ping".toByteArray())
            assertEquals("ping", String(input.readBytes(4)))
        }
    }

    private fun connectRequest(host: String, port: Int): ByteArray =
        byteArrayOf(0x05, 0x01, 0x00, 0x03, host.length.toByte()) + host.toByteArray() +
            byteArrayOf((port shr 8).toByte(), (port and 0xFF).toByte())

    private fun DataInputStream.readBytes(n: Int): ByteArray = ByteArray(n).also { readFully(it) }

    @Before
    fun setUp() {
        upstream = FakeUpstream("user", "pässword")
    }

    @After
    fun tearDown() {
        relay?.stop()
        upstream.close()
    }

    @Test
    fun clientWithoutAuthIsAuthenticatedUpstreamAndDataPassesThrough() {
        startRelay("user", "pässword")
        Socket("127.0.0.1", relayPort).use { client ->
            client.soTimeout = 5000
            val input = DataInputStream(client.getInputStream())
            val output = client.getOutputStream()

            output.write(byteArrayOf(0x05, 0x01, 0x00))
            assertArrayEquals(byteArrayOf(0x05, 0x00), input.readBytes(2))

            output.write(connectRequest("example.com", 443))
            assertArrayEquals(byteArrayOf(0x05, 0x00), input.readBytes(10).copyOf(2))

            output.write("ping".toByteArray())
            assertEquals("ping", String(input.readBytes(4)))
        }
        assertEquals(listOf("user" to "pässword"), upstream.authAttempts)
        assertEquals(listOf("example.com:443"), upstream.connectTargets)
    }

    @Test
    fun requestPipelinedWithGreetingIsForwarded() {
        startRelay("user", "pässword")
        Socket("127.0.0.1", relayPort).use { client ->
            client.soTimeout = 5000
            val input = DataInputStream(client.getInputStream())

            client.getOutputStream().write(
                byteArrayOf(0x05, 0x01, 0x00) + connectRequest("example.com", 80) + "data".toByteArray()
            )
            assertArrayEquals(byteArrayOf(0x05, 0x00), input.readBytes(2))
            assertArrayEquals(byteArrayOf(0x05, 0x00), input.readBytes(10).copyOf(2))
            assertEquals("data", String(input.readBytes(4)))
        }
    }

    @Test
    fun clientOfferingOnlyUsernameAuthIsAcceptedWithAnyCredentials() {
        startRelay("user", "pässword")
        Socket("127.0.0.1", relayPort).use { client ->
            client.soTimeout = 5000
            val input = DataInputStream(client.getInputStream())
            val output = client.getOutputStream()

            output.write(byteArrayOf(0x05, 0x01, 0x02))
            assertArrayEquals(byteArrayOf(0x05, 0x02), input.readBytes(2))
            output.write(byteArrayOf(0x01, 1, 'x'.code.toByte(), 1, 'y'.code.toByte()))
            assertArrayEquals(byteArrayOf(0x01, 0x00), input.readBytes(2))

            output.write(connectRequest("example.com", 443))
            assertArrayEquals(byteArrayOf(0x05, 0x00), input.readBytes(10).copyOf(2))
        }
        assertEquals(listOf("user" to "pässword"), upstream.authAttempts)
    }

    @Test
    fun wrongUpstreamCredentialsCloseTheClientConnection() {
        startRelay("user", "wrong")
        Socket("127.0.0.1", relayPort).use { client ->
            client.soTimeout = 5000
            val input = client.getInputStream()
            val output = client.getOutputStream()

            output.write(byteArrayOf(0x05, 0x01, 0x00))
            assertEquals(0x05, input.read())
            assertEquals(0x00, input.read())
            output.write(connectRequest("example.com", 443))
            // General SOCKS server failure, then the relay closes the connection
            assertEquals(0x05, input.read())
            assertEquals(0x01, input.read())
            input.skip(8)

            val closed = try {
                input.read() == -1
            } catch (e: IOException) {
                true // Connection reset
            }
            assertTrue(closed)
        }
        assertTrue(upstream.connectTargets.isEmpty())
    }

    @Test
    fun upstreamDroppingPipelinedDataGetsStepByStepHandshake() {
        val strictUpstream = MessagePerReadUpstream("user", "pässword")
        try {
            startRelay("user", "pässword", upstreamPort = strictUpstream.server.localPort, pipelineGraceMs = 200)

            // The pipelined attempt stalls, the step-by-step retry on a new connection succeeds
            connectAndPing("example.com", 443)
            assertEquals(2, strictUpstream.connections.get())

            // Later connections go step by step right away
            connectAndPing("example.org", 80)
            assertEquals(3, strictUpstream.connections.get())
            assertEquals(listOf("example.com:443", "example.org:80"), strictUpstream.connectTargets)
        } finally {
            strictUpstream.close()
        }
    }

    @Test
    fun connectionIdleLongerThanHandshakeTimeoutStaysOpen() {
        startRelay("user", "pässword", handshakeTimeoutMs = 2000)
        Socket("127.0.0.1", relayPort).use { client ->
            client.soTimeout = 5000
            val input = DataInputStream(client.getInputStream())
            val output = client.getOutputStream()

            output.write(byteArrayOf(0x05, 0x01, 0x00))
            assertArrayEquals(byteArrayOf(0x05, 0x00), input.readBytes(2))
            output.write(connectRequest("example.com", 443))
            assertArrayEquals(byteArrayOf(0x05, 0x00), input.readBytes(10).copyOf(2))

            Thread.sleep(4000)
            output.write("ping".toByteArray())
            assertEquals("ping", String(input.readBytes(4)))
        }
    }
}
