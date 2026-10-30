package xyz.dnstt.app

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Runs hev-socks5-tunnel on the VPN's TUN fd: TCP from the device becomes SOCKS5 CONNECT
 * to the local tunnel proxy, DNS to [DNS_ADDRESS] is answered with fake addresses (mapdns)
 * so that connections reach the proxy by host name and the server side resolves them.
 * The engine is one instance per process; start and stop are serialized here.
 */
object Tun2Socks {
    private const val TAG = "Tun2Socks"

    // Addresses from the benchmarking range 198.18.0.0/15 (never routed on the Internet)
    // and the ULA range; the VPN Builder uses the same values.
    const val TUN_IPV4 = "198.18.0.1"
    const val TUN_IPV6 = "fc00::1"
    const val DNS_ADDRESS = "198.18.0.2"
    const val MTU = 8500

    // Fake addresses for host names: 198.18.128.0/17 (32767 names, more than the cache)
    private const val MAPPED_NETWORK = "198.18.128.0"
    private const val MAPPED_NETMASK = "255.255.128.0"
    private const val MAPPED_CACHE_SIZE = 10000

    // A CONNECT crosses the DNS tunnel and the server's own connect
    private const val CONNECT_TIMEOUT_MS = 30000

    private const val CONFIG_FILE = "tun2socks.yml"
    private const val LOG_FILE = "tun2socks.log"
    private const val LOG_LINES = 50

    private var running = false

    /**
     * The engine config. Handshake pipelining stays off: some proxies (microsocks) drop
     * bytes that arrive with the greeting; with upstream auth the engine talks to
     * [Socks5AuthRelay], which pipelines when the proxy allows it.
     */
    fun config(socksPort: Int, logFile: String? = null): String = buildString {
        appendLine("tunnel:")
        appendLine("  mtu: $MTU")
        appendLine("  ipv4: $TUN_IPV4")
        appendLine("  ipv6: '$TUN_IPV6'")
        // No offloads: the VPN fd has no vnet header (so no TSO/USO), and segments larger
        // than the MTU ("jumbo", on by default) gain nothing at DNS tunnel speeds
        appendLine("  offload:")
        appendLine("    tso: false")
        appendLine("    uso: false")
        appendLine("    jumbo: false")
        appendLine("socks5:")
        appendLine("  address: 127.0.0.1")
        appendLine("  port: $socksPort")
        appendLine("  udp: 'udp'")
        appendLine("  pipeline: false")
        appendLine("mapdns:")
        appendLine("  address: $DNS_ADDRESS")
        appendLine("  port: 53")
        appendLine("  network: $MAPPED_NETWORK")
        appendLine("  netmask: $MAPPED_NETMASK")
        appendLine("  cache-size: $MAPPED_CACHE_SIZE")
        appendLine("misc:")
        appendLine("  connect-timeout: $CONNECT_TIMEOUT_MS")
        appendLine("  log-file: '${logFile ?: "null"}'")
        appendLine("  log-level: warn")
    }

    /**
     * Starts the engine on [fd] (the VPN interface, which stays owned by the caller) with
     * the SOCKS5 proxy on 127.0.0.1:[socksPort]. A running engine is stopped first.
     */
    @Synchronized
    fun start(context: Context, fd: Int, socksPort: Int): Boolean {
        stop()
        return try {
            val log = File(context.cacheDir, LOG_FILE)
            log.delete()
            val configFile = File(context.cacheDir, CONFIG_FILE)
            configFile.writeText(config(socksPort, log.absolutePath))
            TProxyService.TProxyStartService(configFile.absolutePath, fd)
            running = true
            Log.d(TAG, "Started on fd $fd, SOCKS5 127.0.0.1:$socksPort")
            true
        } catch (e: Throwable) {
            // UnsatisfiedLinkError when the library is missing
            Log.e(TAG, "Failed to start", e)
            false
        }
    }

    /** Stops the engine; copies its counters and the end of its log to logcat. */
    @Synchronized
    fun stop(context: Context? = null) {
        if (!running) return
        try {
            val stats = TProxyService.TProxyGetStats()
            TProxyService.TProxyStopService()
            Log.d(TAG, "Stopped: tx ${stats[0]} packets / ${stats[1]} bytes, rx ${stats[2]} packets / ${stats[3]} bytes")
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to stop", e)
        }
        running = false
        context?.let { dumpLog(File(it.cacheDir, LOG_FILE)) }
    }

    private fun dumpLog(log: File) {
        try {
            if (!log.exists()) return
            log.readLines().takeLast(LOG_LINES).forEach { Log.d(TAG, "engine: $it") }
        } catch (e: Exception) {
            Log.w(TAG, "Cannot read engine log", e)
        }
    }
}
