package xyz.dnstt.app

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
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
import java.util.Collections

/**
 * Instrumentation smoke test for the `libslipstream_client.so` executable
 * packaged into the installed APK, launched directly instead of through
 * [SlipstreamBridge].
 *
 * This is the narrowed acceptance check for the ARMv7 ABI: the accepted
 * x86_64 runtime with ARM translation cannot load the app's Go JNI library, so
 * on that runtime the bridge cannot reach the subprocess. This test keeps the
 * subprocess contract covered there by starting the same packaged executable
 * with the same documentation-only values and proving that it stays alive and
 * listens on loopback. The resolver is an unreachable loopback sink, so no
 * tunnel server, resolver or external network is involved, and no payload is
 * sent.
 */
@RunWith(AndroidJUnit4::class)
class SlipstreamExecutableInstrumentationTest {

    private companion object {
        const val TAG = "SlipstreamExecutableTest"
        const val LOOPBACK = "127.0.0.1"

        // RFC 863 discard port on loopback: parsed as a plain UDP resolver spec, never answered
        const val RESOLVER_SINK = "127.0.0.1:9"

        // Generous bounds: the executable may start slowly on a translated ARM runtime
        const val LISTEN_TIMEOUT_MS = 10_000L
        const val CONNECT_TIMEOUT_MS = 500
        const val CONNECT_RETRY_DELAY_MS = 200L
        const val STOP_TIMEOUT_MS = 5_000L
        const val STOP_POLL_MS = 100L
        const val OUTPUT_LINE_LIMIT = 20
    }

    private lateinit var binary: File

    @Before
    fun setUp() {
        val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
        binary = File(context.applicationInfo.nativeLibraryDir, "libslipstream_client.so")
        assertTrue(
            "libslipstream_client.so is missing from the installed APK at ${binary.absolutePath}",
            binary.isFile,
        )
        assertTrue(
            "libslipstream_client.so is not executable at ${binary.absolutePath}",
            binary.canExecute(),
        )
    }

    @Test
    fun directExecutableStartsLocalTcpListener() {
        val port = freeLoopbackPort()
        val output = Collections.synchronizedList(mutableListOf<String>())
        val process = try {
            ProcessBuilder(
                binary.absolutePath,
                "--tcp-listen-port", port.toString(),
                "--tcp-listen-host", LOOPBACK,
                "--domain", "example.com",
                "--resolver", RESOLVER_SINK,
                "--congestion-control", "dcubic",
                "--keep-alive-interval", "400",
            )
                .redirectErrorStream(true)
                .start()
        } catch (e: IOException) {
            throw AssertionError("failed to start ${binary.absolutePath}: $e")
        }

        try {
            drainOutput(process, output)
            assertTrue(
                "slipstream-client exited immediately: ${diagnostics(process, output)}",
                isAlive(process),
            )
            awaitLocalListener(process, port, output)
        } finally {
            stopProcess(process)
        }
        assertFalse("slipstream-client is still alive after cleanup", isAlive(process))
    }

    /** Reserves a free loopback TCP port and releases it on return. */
    private fun freeLoopbackPort(): Int =
        ServerSocket(0, 1, InetAddress.getByName(LOOPBACK)).use { it.localPort }

    /** Keeps the merged stdout/stderr pipe drained and available for failure diagnostics. */
    private fun drainOutput(process: Process, output: MutableList<String>) {
        Thread {
            try {
                process.inputStream.bufferedReader().forEachLine { line ->
                    Log.d(TAG, line)
                    output.add(line)
                }
            } catch (e: IOException) {
                // Process output closed
            }
        }.also {
            it.isDaemon = true
            it.start()
        }
    }

    /**
     * Fails when the process exits before the listener comes up or when no
     * connection is accepted within [LISTEN_TIMEOUT_MS]. Listener acceptance is the
     * complete smoke-test result: the connection is closed without any payload.
     */
    private fun awaitLocalListener(process: Process, port: Int, output: List<String>) {
        val deadline = SystemClock.elapsedRealtime() + LISTEN_TIMEOUT_MS
        var lastFailure: String? = null
        while (SystemClock.elapsedRealtime() < deadline) {
            if (!isAlive(process)) {
                throw AssertionError(
                    "slipstream-client exited before accepting a connection on $LOOPBACK:$port: " +
                        diagnostics(process, output),
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
                diagnostics(process, output),
        )
    }

    /** True while the subprocess has not exited; uses the same check as [SlipstreamBridge.isRunning]. */
    private fun isAlive(process: Process): Boolean = try {
        process.exitValue()
        false
    } catch (e: IllegalThreadStateException) {
        true
    }

    /** Destroys the process gracefully and kills it forcibly when it does not exit in time. */
    private fun stopProcess(process: Process) {
        process.destroy()
        awaitExit(process)
        if (isAlive(process)) {
            // Process.destroyForcibly() is public API 26; below it repeat destroy() instead and let
            // the final liveness assertion fail the test rather than leave the process behind.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                process.destroyForcibly()
            } else {
                process.destroy()
            }
            awaitExit(process)
        }
    }

    private fun awaitExit(process: Process) {
        val deadline = SystemClock.elapsedRealtime() + STOP_TIMEOUT_MS
        while (isAlive(process) && SystemClock.elapsedRealtime() < deadline) {
            SystemClock.sleep(STOP_POLL_MS)
        }
    }

    private fun diagnostics(process: Process, output: List<String>): String {
        val state = if (isAlive(process)) "process still alive" else "exit code ${process.exitValue()}"
        val lines = synchronized(output) { output.takeLast(OUTPUT_LINE_LIMIT) }
        return "$state; last output: ${lines.ifEmpty { listOf("none") }.joinToString(" | ")}"
    }
}
