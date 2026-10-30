package xyz.dnstt.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class Tun2SocksTest {

    /** Reads the block YAML that [Tun2Socks.config] writes into "section.key" -> value. */
    private fun parse(yaml: String): Map<String, String> {
        val result = mutableMapOf<String, String>()
        val path = mutableListOf<String>()
        for (line in yaml.lines().filter { it.isNotBlank() }) {
            val indent = line.takeWhile { it == ' ' }.length
            assertEquals("indentation: $line", 0, indent % 2)
            assertTrue("indentation: $line", indent / 2 <= path.size)
            while (path.size > indent / 2) path.removeAt(path.size - 1)
            val text = line.trim()
            if (text.endsWith(":")) {
                path.add(text.dropLast(1))
                continue
            }
            assertTrue("value outside a section: $line", path.isNotEmpty())
            val key = (path + text.substringBefore(": ")).joinToString(".")
            result[key] = text.substringAfter(": ").removeSurrounding("'")
        }
        return result
    }

    @Test
    fun configPointsTheEngineAtTheLocalProxy() {
        val config = parse(Tun2Socks.config(7000))
        assertEquals("127.0.0.1", config["socks5.address"])
        assertEquals("7000", config["socks5.port"])
        assertEquals("false", config["socks5.pipeline"])
        assertEquals("udp", config["socks5.udp"])
    }

    @Test
    fun configMatchesTheVpnInterface() {
        val config = parse(Tun2Socks.config(7000))
        assertEquals(Tun2Socks.MTU.toString(), config["tunnel.mtu"])
        assertEquals(Tun2Socks.TUN_IPV4, config["tunnel.ipv4"])
        assertEquals(Tun2Socks.TUN_IPV6, config["tunnel.ipv6"])
        assertEquals(Tun2Socks.DNS_ADDRESS, config["mapdns.address"])
        assertEquals("53", config["mapdns.port"])
    }

    @Test
    fun offloadsAreOff() {
        val config = parse(Tun2Socks.config(7000))
        for (offload in listOf("tso", "uso", "jumbo")) {
            assertEquals(offload, "false", config["tunnel.offload.$offload"])
        }
    }

    @Test
    fun mappedNetworkDoesNotOverlapTheTunAddresses() {
        val config = parse(Tun2Socks.config(7000))
        fun ip(s: String) = s.split('.').fold(0L) { acc, part -> acc * 256 + part.toLong() }
        val network = ip(config.getValue("mapdns.network"))
        val mask = ip(config.getValue("mapdns.netmask"))
        assertEquals("network is aligned to its mask", network, network and mask)
        for (address in listOf(Tun2Socks.TUN_IPV4, Tun2Socks.DNS_ADDRESS)) {
            assertTrue("$address is inside the mapped network", ip(address) and mask != network)
        }
        val size = (mask xor 0xffffffffL) + 1
        assertTrue("cache larger than the network", config.getValue("mapdns.cache-size").toLong() < size)
    }

    @Test
    fun logGoesToTheGivenFileOrNowhere() {
        assertEquals("null", parse(Tun2Socks.config(7000))["misc.log-file"])
        assertEquals("/cache/tun2socks.log", parse(Tun2Socks.config(7000, "/cache/tun2socks.log"))["misc.log-file"])
    }
}
