package xyz.dnstt.app

import org.junit.Assert.assertEquals
import org.junit.Test

class SshTunnelPortTest {

    // The constant is the single source of truth for the SSH listener and the VPN intent.
    // 1080 is also the app's default proxy port (lib/services/vpn_service.dart:50), so
    // changing it is a deliberate act that must update this pin.
    @Test
    fun socks5ProxyPortIsPinned() {
        assertEquals(1080, SshTunnelClient.SOCKS5_PROXY_PORT)
    }
}
