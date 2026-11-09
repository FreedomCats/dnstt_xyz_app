package xyz.dnstt.app

import android.content.Context
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

/**
 * Instrumentation smoke test for the `libslipstream_client.so` executable
 * packaged into the installed APK.
 *
 * The test proves the local startup contract only: the bridge finds and starts
 * the packaged executable, the subprocess stays alive, and its TCP listener
 * accepts a connection on loopback. The tunnel domain is a documentation value
 * and the resolver is an unreachable loopback sink, so no tunnel server,
 * resolver or external network is involved, and no payload is sent.
 */
@RunWith(AndroidJUnit4::class)
class SlipstreamBridgeInstrumentationTest {

    private companion object {
        const val LOOPBACK = "127.0.0.1"

        // RFC 863 discard port on loopback: parsed as a plain UDP resolver spec, never answered
        const val RESOLVER_SINK = "127.0.0.1:9"

        // Another process may take the reserved port between closing it and the subprocess binding
        const val START_ATTEMPTS = 3
        const val PORT_RETRY_DELAY_MS = 200L

        // Generous bounds: the executable may start slowly on a translated ARM runtime
        const val LISTEN_TIMEOUT_MS = 10_000L
        const val CONNECT_TIMEOUT_MS = 500
        const val CONNECT_RETRY_DELAY_MS = 200L
    }

    private lateinit var bridge: SlipstreamBridge

    @Before
    fun setUp() {
        val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
        val binary = File(context.applicationInfo.nativeLibraryDir, "libslipstream_client.so")
        assertTrue(
            "libslipstream_client.so is missing from the installed APK at ${binary.absolutePath}",
            binary.isFile,
        )
        assertTrue(
            "libslipstream_client.so is not executable at ${binary.absolutePath}",
            binary.canExecute(),
        )

        SlipstreamBridge.init(context)
        assertTrue(
            "SlipstreamBridge reports the packaged slipstream-client binary as unavailable",
            SlipstreamBridge.isAvailable(),
        )
        bridge = SlipstreamBridge()
    }

    @After
    fun tearDown() {
        if (!::bridge.isInitialized) return
        bridge.stopClient()
        assertFalse("slipstream-client is still running after cleanup", bridge.isRunning())
    }

    @Test
    fun packagedExecutableStartsLocalTcpListener() {
        val port = startClientOnFreeLoopbackPort()
        assertTrue(
            "slipstream-client is not running after startClient() reported success: " +
                (bridge.lastError ?: "no error reported"),
            bridge.isRunning(),
        )
        awaitLocalListener(port)
    }

    /**
     * Starts the packaged executable on a fresh loopback port and returns that port.
     * The port reservation is closed immediately before the subprocess starts; if
     * another process wins that race, the failed bridge is stopped and the complete
     * allocation/start sequence is retried with a new port.
     */
    private fun startClientOnFreeLoopbackPort(): Int {
        var lastError: String? = null
        repeat(START_ATTEMPTS) { attempt ->
            val port = freeLoopbackPort()
            val started = bridge.startClient(
                domain = "example.com",
                dnsServer = RESOLVER_SINK,
                resolverOptions = ResolverOptions(),
                congestionControl = "dcubic",
                port = port,
                host = LOOPBACK,
                gso = false,
            )
            if (started) return port

            lastError = bridge.lastError
            bridge.stopClient()
            if (attempt + 1 < START_ATTEMPTS) SystemClock.sleep(PORT_RETRY_DELAY_MS)
        }
        throw AssertionError(
            "slipstream-client did not start on any of $START_ATTEMPTS loopback ports; " +
                "last error: ${lastError ?: "none reported"}",
        )
    }

    /** Reserves a free loopback TCP port and releases it on return. */
    private fun freeLoopbackPort(): Int =
        ServerSocket(0, 1, InetAddress.getByName(LOOPBACK)).use { it.localPort }

    /**
     * Fails when the subprocess exits before the listener comes up or when no
     * connection is accepted within [LISTEN_TIMEOUT_MS]. Listener acceptance is the
     * complete smoke-test result: the connection is closed without any payload.
     */
    private fun awaitLocalListener(port: Int) {
        val deadline = SystemClock.elapsedRealtime() + LISTEN_TIMEOUT_MS
        var lastFailure: String? = null
        while (SystemClock.elapsedRealtime() < deadline) {
            if (!bridge.isRunning()) {
                throw AssertionError(
                    "slipstream-client exited before accepting a connection on $LOOPBACK:$port; " +
                        "last error: ${bridge.lastError ?: "none reported"}",
                )
            }
            try {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress(InetAddress.getByName(LOOPBACK), port), CONNECT_TIMEOUT_MS)
                }
                return
            } catch (e: IOException) {
                lastFailure = e.toString()
            }
            SystemClock.sleep(CONNECT_RETRY_DELAY_MS)
        }
        throw AssertionError(
            "slipstream-client did not accept a TCP connection on $LOOPBACK:$port within " +
                "${LISTEN_TIMEOUT_MS}ms; last connection failure: $lastFailure; " +
                "last error: ${bridge.lastError ?: "none reported"}",
        )
    }
}
