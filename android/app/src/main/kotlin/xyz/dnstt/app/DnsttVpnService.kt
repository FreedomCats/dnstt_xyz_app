package xyz.dnstt.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import java.util.concurrent.atomic.AtomicBoolean
import mobile.Mobile

class DnsttVpnService : VpnService() {

    companion object {
        const val TAG = "DnsttVpnService"
        const val NOTIFICATION_CHANNEL_ID = "dnstt_vpn_channel_v2"
        const val NOTIFICATION_ID = 1

        const val ACTION_CONNECT = "xyz.dnstt.app.CONNECT"
        const val ACTION_DISCONNECT = "xyz.dnstt.app.DISCONNECT"

        const val EXTRA_PROXY_HOST = "proxy_host"
        const val EXTRA_PROXY_PORT = "proxy_port"
        const val EXTRA_DNS_SERVER = "dns_server"
        const val EXTRA_TUNNEL_DOMAIN = "tunnel_domain"
        const val EXTRA_PUBLIC_KEY = "public_key"
        const val EXTRA_SSH_MODE = "ssh_mode"
        const val EXTRA_SOCKS_USERNAME = "socks_username"
        const val EXTRA_SOCKS_PASSWORD = "socks_password"
        const val EXTRA_TRANSPORT_TYPE = "transport_type"
        const val EXTRA_CONGESTION_CONTROL = "congestion_control"
        const val EXTRA_KEEP_ALIVE_INTERVAL = "keep_alive_interval"
        const val EXTRA_GSO = "gso"

        var isRunning = AtomicBoolean(false)
        var stateCallback: ((String) -> Unit)? = null
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var proxyHost: String = "127.0.0.1"
    private var proxyPort: Int = 7000
    private var dnsServer: String = "8.8.8.8"
    private var resolverOptions = ResolverOptions()
    private var tunnelDomain: String = ""
    private var publicKey: String = ""
    private var isSshMode: Boolean = false
    private var socksUsername: String? = null
    private var socksPassword: String? = null
    private var transportType: String = "dnstt"
    private var congestionControl: String = "dcubic"
    private var keepAliveInterval: Int = 400
    private var gso: Boolean = false

    // Slipstream bridge for VPN mode
    private var slipstreamBridge: SlipstreamBridge? = null

    // Wake lock to prevent CPU from sleeping
    private var wakeLock: PowerManager.WakeLock? = null

    // Go-based dnstt client from gomobile library
    private var dnsttClient: mobile.DnsttClient? = null

    // Authenticates to the upstream SOCKS5 proxy when credentials are configured
    private var socksRelay: Socks5AuthRelay? = null

    private val useSocksAuth: Boolean get() = !socksUsername.isNullOrEmpty()

    /**
     * Starts the tunnel client (via [startTunnel]) on the address local clients should reach.
     * With upstream SOCKS5 credentials, the tunnel client listens on a free localhost port
     * and [Socks5AuthRelay] takes its place on proxyHost:proxyPort.
     */
    private fun startTunnelWithRelay(startTunnel: (host: String, port: Int) -> Boolean): Boolean {
        if (!useSocksAuth) {
            return startTunnel(proxyHost, proxyPort)
        }

        val tunnelPort = Socks5AuthRelay.findFreePort()
        if (!startTunnel("127.0.0.1", tunnelPort)) {
            return false
        }

        val relay = Socks5AuthRelay(
            proxyHost, proxyPort, "127.0.0.1", tunnelPort,
            socksUsername!!, socksPassword ?: ""
        )
        if (!relay.start()) {
            Log.e(TAG, "Failed to start SOCKS5 auth relay on $proxyHost:$proxyPort")
            return false
        }
        socksRelay = relay
        Log.d(TAG, "SOCKS5 auth relay started on $proxyHost:$proxyPort -> 127.0.0.1:$tunnelPort")
        return true
    }

    private fun stopSocksRelay() {
        socksRelay?.stop()
        socksRelay = null
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return when (intent?.action) {
            ACTION_CONNECT -> {
                proxyHost = intent.getStringExtra(EXTRA_PROXY_HOST) ?: "127.0.0.1"
                proxyPort = intent.getIntExtra(EXTRA_PROXY_PORT, 7000)
                dnsServer = intent.getStringExtra(EXTRA_DNS_SERVER) ?: "8.8.8.8"
                resolverOptions = ResolverOptions.from(intent)
                tunnelDomain = intent.getStringExtra(EXTRA_TUNNEL_DOMAIN) ?: ""
                publicKey = intent.getStringExtra(EXTRA_PUBLIC_KEY) ?: ""
                isSshMode = intent.getBooleanExtra(EXTRA_SSH_MODE, false)
                socksUsername = intent.getStringExtra(EXTRA_SOCKS_USERNAME)
                socksPassword = intent.getStringExtra(EXTRA_SOCKS_PASSWORD)
                transportType = intent.getStringExtra(EXTRA_TRANSPORT_TYPE) ?: "dnstt"
                congestionControl = intent.getStringExtra(EXTRA_CONGESTION_CONTROL) ?: "dcubic"
                keepAliveInterval = intent.getIntExtra(EXTRA_KEEP_ALIVE_INTERVAL, 400)
                gso = intent.getBooleanExtra(EXTRA_GSO, false)
                // Run connect on background thread to avoid ANR
                Thread { connect() }.start()
                START_STICKY
            }
            ACTION_DISCONNECT -> {
                disconnect()
                START_NOT_STICKY
            }
            else -> START_NOT_STICKY
        }
    }

    private fun startDnsttClient(): Boolean {
        if (tunnelDomain.isEmpty() || publicKey.isEmpty()) {
            Log.e(TAG, "Tunnel domain or public key not provided")
            return false
        }

        try {
            // Clean up any previous client
            stopDnsttClient()

            // Wait for port to be available
            if (isPortInUse(proxyPort)) {
                Log.w(TAG, "Port $proxyPort still in use, waiting...")
                waitForPortRelease(proxyPort)
                if (isPortInUse(proxyPort)) {
                    Log.e(TAG, "Port $proxyPort still in use after waiting")
                    return false
                }
            }

            Log.d(TAG, "Starting Go-based DNSTT client")
            Log.d(TAG, "DNS Server: $dnsServer, Domain: $tunnelDomain")
            Log.d(TAG, "Listen address: $proxyHost:$proxyPort")

            val running = startTunnelWithRelay { host, port ->
                // Create the Go dnstt client
                val listenAddr = "$host:$port"
                dnsttClient = Mobile.newClient(dnsServer, tunnelDomain, publicKey, listenAddr)
                dnsttClient?.let { client ->
                    resolverOptions.applyTo(client)
                    // The app is excluded from the VPN; protecting the tunnel's sockets
                    // as well keeps them off the TUN should the exclusion not apply.
                    client.setSocketProtector { fd ->
                        if (!protect(fd.toInt())) Log.w(TAG, "Failed to protect tunnel socket")
                        true
                    }
                }

                // Start the client (this may block while establishing connection)
                dnsttClient?.start()

                Log.d(TAG, "DNSTT client started successfully")

                // Small delay to ensure socket is fully listening
                Thread.sleep(100)

                // Verify it's running
                dnsttClient?.isRunning ?: false
            }
            Log.d(TAG, "DNSTT client running: $running")
            if (!running) {
                stopDnsttClient()
                return false
            }

            if (running) {
                // Try to verify SOCKS5 proxy is actually listening
                if (verifySocks5Listening()) {
                    Log.d(TAG, "SOCKS5 proxy verified listening on $proxyHost:$proxyPort")
                    return true
                } else {
                    Log.w(TAG, "SOCKS5 proxy not responding, but client reports running")
                    return true // Still return true, let connections try
                }
            }

            return running

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start dnstt client", e)
            return false
        }
    }

    private fun verifySocks5Listening(): Boolean {
        return try {
            val socket = java.net.Socket()
            socket.connect(java.net.InetSocketAddress(proxyHost, proxyPort), 2000)
            socket.close()
            true
        } catch (e: Exception) {
            Log.w(TAG, "SOCKS5 verify failed: ${e.message}")
            false
        }
    }

    /**
     * Verifies the tunnel actually works by making an HTTP request through the SOCKS5 proxy.
     * Returns true if the tunnel is working, false otherwise.
     */
    private fun verifyTunnelConnection(timeoutMs: Int = 10000): Boolean {
        return try {
            Log.d(TAG, "Verifying tunnel connection via HTTP request...")

            // Connect to SOCKS5 proxy
            val socket = java.net.Socket()
            socket.soTimeout = timeoutMs
            socket.connect(java.net.InetSocketAddress(proxyHost, proxyPort), 5000)

            val output = socket.getOutputStream()
            val input = socket.getInputStream()

            // SOCKS5 handshake - greeting (no auth)
            output.write(byteArrayOf(0x05, 0x01, 0x00))
            output.flush()

            // Read server response (should be 0x05, 0x00 for no auth)
            val authResponse = ByteArray(2)
            val authRead = input.read(authResponse)
            if (authRead != 2 || authResponse[0] != 0x05.toByte() || authResponse[1] != 0x00.toByte()) {
                Log.w(TAG, "SOCKS5 auth failed: ${authResponse.contentToString()}")
                socket.close()
                return false
            }

            // SOCKS5 connect request to api.ipify.org:80
            val targetHost = "api.ipify.org"
            val targetPort = 80
            val connectRequest = ByteArray(7 + targetHost.length)
            connectRequest[0] = 0x05 // SOCKS version
            connectRequest[1] = 0x01 // CONNECT command
            connectRequest[2] = 0x00 // Reserved
            connectRequest[3] = 0x03 // Domain name address type
            connectRequest[4] = targetHost.length.toByte()
            System.arraycopy(targetHost.toByteArray(), 0, connectRequest, 5, targetHost.length)
            connectRequest[5 + targetHost.length] = ((targetPort shr 8) and 0xFF).toByte()
            connectRequest[6 + targetHost.length] = (targetPort and 0xFF).toByte()

            output.write(connectRequest)
            output.flush()

            // Read SOCKS5 connect response
            val connectResponse = ByteArray(10)
            val responseRead = input.read(connectResponse, 0, 4) // Read first 4 bytes
            if (responseRead < 4) {
                Log.w(TAG, "SOCKS5 connect response too short")
                socket.close()
                return false
            }

            if (connectResponse[1] != 0x00.toByte()) {
                Log.w(TAG, "SOCKS5 connect failed with code: ${connectResponse[1]}")
                socket.close()
                return false
            }

            // Read remaining response based on address type
            when (connectResponse[3]) {
                0x01.toByte() -> input.read(ByteArray(6)) // IPv4 + port
                0x03.toByte() -> {
                    val domainLen = input.read()
                    input.read(ByteArray(domainLen + 2)) // domain + port
                }
                0x04.toByte() -> input.read(ByteArray(18)) // IPv6 + port
            }

            // Send HTTP request
            val httpRequest = "GET /?format=text HTTP/1.1\r\nHost: $targetHost\r\nConnection: close\r\n\r\n"
            output.write(httpRequest.toByteArray())
            output.flush()

            // Read HTTP response (just check for 200 OK)
            val responseBuffer = ByteArray(256)
            val bytesRead = input.read(responseBuffer)
            socket.close()

            if (bytesRead > 0) {
                val response = String(responseBuffer, 0, bytesRead)
                if (response.contains("200 OK") || response.contains("200")) {
                    Log.d(TAG, "Tunnel verification SUCCESS - HTTP response received")
                    return true
                } else {
                    Log.w(TAG, "Tunnel verification got unexpected response: ${response.take(100)}")
                    return false
                }
            }

            Log.w(TAG, "Tunnel verification failed - no HTTP response")
            false
        } catch (e: java.net.SocketTimeoutException) {
            Log.w(TAG, "Tunnel verification timed out")
            false
        } catch (e: Exception) {
            Log.w(TAG, "Tunnel verification error: ${e.message}")
            false
        }
    }

    private fun stopDnsttClient() {
        stopSocksRelay()
        dnsttClient?.let { client ->
            try {
                client.stop()
                Log.d(TAG, "DNSTT client stopped")
                // Wait for port to be released
                Thread.sleep(500)
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping dnstt client", e)
            }
        }
        dnsttClient = null
    }

    private fun startSlipstreamClient(): Boolean {
        if (tunnelDomain.isEmpty()) {
            Log.e(TAG, "Tunnel domain not provided for slipstream")
            return false
        }

        if (!SlipstreamBridge.isAvailable()) {
            Log.e(TAG, "Slipstream library not available")
            return false
        }

        try {
            stopSlipstreamClient()

            if (isPortInUse(proxyPort)) {
                Log.w(TAG, "Port $proxyPort still in use, waiting...")
                waitForPortRelease(proxyPort)
                if (isPortInUse(proxyPort)) {
                    Log.e(TAG, "Port $proxyPort still in use after waiting")
                    return false
                }
            }

            Log.d(TAG, "Starting Slipstream client")
            Log.d(TAG, "DNS Server (resolver): $dnsServer, Domain: $tunnelDomain")
            Log.d(TAG, "Listen address: $proxyHost:$proxyPort")

            val started = startTunnelWithRelay { host, port ->
                slipstreamBridge = SlipstreamBridge()
                val bridgeStarted = slipstreamBridge!!.startClient(
                    domain = tunnelDomain,
                    dnsServer = dnsServer,
                    resolverOptions = resolverOptions,
                    congestionControl = congestionControl,
                    keepAliveInterval = keepAliveInterval,
                    port = port,
                    host = host,
                    gso = gso
                )
                if (!bridgeStarted) {
                    Log.e(TAG, "Slipstream client failed to start: ${slipstreamBridge?.lastError}")
                    slipstreamBridge = null
                }
                bridgeStarted
            }

            if (!started) {
                stopSlipstreamClient()
                return false
            }

            Thread.sleep(100)

            if (verifySocks5Listening()) {
                Log.d(TAG, "Slipstream SOCKS5 proxy verified on $proxyHost:$proxyPort")
                return true
            } else {
                Log.w(TAG, "Slipstream SOCKS5 not responding, but bridge reports started")
                return true
            }

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start slipstream client", e)
            return false
        }
    }

    private fun stopSlipstreamClient() {
        stopSocksRelay()
        slipstreamBridge?.let { bridge ->
            try {
                bridge.stopClient()
                Log.d(TAG, "Slipstream client stopped")
                Thread.sleep(500)
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping slipstream client", e)
            }
        }
        slipstreamBridge = null
    }

    private fun isPortInUse(port: Int): Boolean {
        return try {
            val socket = java.net.ServerSocket(port)
            socket.close()
            false
        } catch (e: Exception) {
            true
        }
    }

    private fun waitForPortRelease(port: Int, maxWaitMs: Int = 3000) {
        val startTime = System.currentTimeMillis()
        while (isPortInUse(port) && (System.currentTimeMillis() - startTime) < maxWaitMs) {
            Log.d(TAG, "Waiting for port $port to be released...")
            Thread.sleep(200)
        }
    }

    private fun connect() {
        if (isRunning.get()) {
            Log.d(TAG, "VPN already running")
            return
        }

        try {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                stateCallback?.invoke("connecting")
            }

            createNotificationChannel()
            startForeground(NOTIFICATION_ID, createNotification("connecting"))

            // Acquire wake lock to prevent CPU from sleeping
            acquireWakeLock()

            // IMPORTANT: Establish VPN interface FIRST with app exclusion
            // This ensures dnstt client's sockets bypass the VPN.
            // IPv4 and IPv6 both go into the TUN, so no traffic bypasses the tunnel; the
            // fd stays non-blocking (the default), as the tun2socks engine expects.
            val builder = Builder()
                .setSession("DNSTT Tunnel")
                .addAddress(Tun2Socks.TUN_IPV4, 32)
                .addAddress(Tun2Socks.TUN_IPV6, 128)
                .addRoute("0.0.0.0", 0)
                .addRoute("::", 0)
                .addDnsServer(Tun2Socks.DNS_ADDRESS)
                .setMtu(Tun2Socks.MTU)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                builder.addDisallowedApplication(packageName)
            }

            vpnInterface = builder.establish()

            if (vpnInterface == null) {
                Log.e(TAG, "Failed to establish VPN interface")
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    stateCallback?.invoke("error")
                }
                releaseWakeLock()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }
            Log.d(TAG, "VPN interface established, app is excluded from routing")

            // Wait for VPN routing to be fully active
            Thread.sleep(500)
            Log.d(TAG, "VPN routing settled")

            // In SSH mode, the SOCKS5 proxy is already running (started by MainActivity)
            // In normal mode, start the appropriate tunnel client
            if (!isSshMode) {
                if (transportType == "slipstream") {
                    Log.d(TAG, "Starting slipstream client")
                    if (!startSlipstreamClient()) {
                        Log.e(TAG, "Failed to start slipstream tunnel")
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            stateCallback?.invoke("error")
                        }
                        vpnInterface?.close()
                        vpnInterface = null
                        releaseWakeLock()
                        stopForeground(STOP_FOREGROUND_REMOVE)
                        stopSelf()
                        return
                    }
                    Log.d(TAG, "slipstream tunnel started successfully")
                } else {
                    Log.d(TAG, "Starting dnstt client")
                    if (!startDnsttClient()) {
                        Log.e(TAG, "Failed to start dnstt-client tunnel")
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            stateCallback?.invoke("error")
                        }
                        vpnInterface?.close()
                        vpnInterface = null
                        releaseWakeLock()
                        stopForeground(STOP_FOREGROUND_REMOVE)
                        stopSelf()
                        return
                    }
                    Log.d(TAG, "dnstt-client tunnel started successfully")
                }
            } else {
                Log.d(TAG, "SSH mode - using existing SOCKS5 proxy on port $proxyPort")
            }

            // Verify tunnel actually works by making HTTP request through SOCKS5 proxy
            // Skip verification in SSH mode (proxy managed externally)
            if (!isSshMode) {
                Log.d(TAG, "Verifying tunnel connectivity...")
                // Use longer timeout for DNS tunnels (they're inherently slow)
                val verifyTimeout = if (transportType == "slipstream") 15000 else 20000
                if (!verifyTunnelConnection(verifyTimeout)) {
                    Log.e(TAG, "Tunnel verification failed - connection not working")
                    android.os.Handler(android.os.Looper.getMainLooper()).post {
                        stateCallback?.invoke("error")
                    }
                    // Clean up
                    if (transportType == "slipstream") {
                        stopSlipstreamClient()
                    } else {
                        stopDnsttClient()
                    }
                    vpnInterface?.close()
                    vpnInterface = null
                    releaseWakeLock()
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                    return
                }
                Log.d(TAG, "Tunnel verification passed")
            }

            // Device traffic goes from the TUN into the tunnel's SOCKS5 proxy from here on
            if (!Tun2Socks.start(this, vpnInterface!!.fd, proxyPort)) {
                Log.e(TAG, "Failed to start tun2socks")
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    stateCallback?.invoke("error")
                }
                disconnect()
                return
            }

            isRunning.set(true)

            // Update notification to connected state
            updateNotification("connected")

            android.os.Handler(android.os.Looper.getMainLooper()).post {
                stateCallback?.invoke("connected")
            }

            Log.d(TAG, "VPN connected successfully with ${if (transportType == "slipstream") "slipstream" else "dnstt"} tunnel")

        } catch (e: Exception) {
            Log.e(TAG, "Failed to connect VPN", e)
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                stateCallback?.invoke("error")
            }
            disconnect()
        }
    }

    private fun disconnect() {
        Log.d(TAG, "Disconnecting VPN")

        stateCallback?.invoke("disconnecting")

        // The engine reads the TUN fd: stop it before closing the interface
        Tun2Socks.stop(this)

        try {
            vpnInterface?.close()
        } catch (e: Exception) {
            Log.e(TAG, "Error closing VPN interface", e)
        }
        vpnInterface = null

        // Stop tunnel client (only if not in SSH mode, since SSH mode manages its own)
        if (!isSshMode) {
            if (transportType == "slipstream") {
                stopSlipstreamClient()
            } else {
                stopDnsttClient()
            }
        }

        // Release wake lock
        releaseWakeLock()

        isRunning.set(false)
        isSshMode = false
        stateCallback?.invoke("disconnected")

        // Remove notification and stop service
        stopForeground(STOP_FOREGROUND_REMOVE)

        // Also explicitly cancel the notification
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager?.cancel(NOTIFICATION_ID)

        stopSelf()
        Log.d(TAG, "VPN disconnected and service stopped")
    }

    override fun onDestroy() {
        disconnect()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "DNSTT VPN Connection",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows when VPN is connected"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                enableVibration(false)
                setSound(null, null)
            }

            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun createNotification(state: String = "connecting"): Notification {
        // Intent to open the app when notification is clicked
        val openAppIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        // Intent to disconnect VPN
        val disconnectIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, DnsttVpnService::class.java).apply {
                action = ACTION_DISCONNECT
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        // Use correct protocol name based on transport type
        val protocolName = if (transportType == "slipstream") "Slipstream" else "DNSTT"

        val (title, text, icon) = when (state) {
            "connecting" -> Triple(
                "$protocolName VPN Connecting...",
                "Establishing tunnel via $dnsServer",
                android.R.drawable.ic_popup_sync
            )
            "connected" -> Triple(
                "$protocolName VPN Connected",
                "Tunneling via $dnsServer",
                android.R.drawable.ic_lock_lock
            )
            "disconnecting" -> Triple(
                "$protocolName VPN Disconnecting...",
                "Closing tunnel",
                android.R.drawable.ic_popup_sync
            )
            else -> Triple(
                "$protocolName VPN",
                "Status: $state",
                android.R.drawable.ic_lock_lock
            )
        }

        val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(icon)
            .setContentIntent(openAppIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setAutoCancel(false)
            .setSilent(true)

        // Add disconnect action only when connected
        if (state == "connected") {
            builder.addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Disconnect",
                disconnectIntent
            )
        }

        return builder.build()
    }

    private fun updateNotification(state: String) {
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.notify(NOTIFICATION_ID, createNotification(state))
    }

    private fun acquireWakeLock() {
        if (wakeLock == null) {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "DnsttVpnService::WakeLock"
            )
        }
        wakeLock?.let {
            if (!it.isHeld) {
                it.acquire()
                Log.d(TAG, "Wake lock acquired")
            }
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
                Log.d(TAG, "Wake lock released")
            }
        }
        wakeLock = null
    }

    override fun onRevoke() {
        disconnect()
        super.onRevoke()
    }
}
