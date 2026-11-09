package xyz.dnstt.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SshConnectResultTest {

    // Documentation values only: the SHA-256 fingerprint of the empty input, the
    // same value the Kotlin repository test uses.
    private val fingerprint = "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU"

    @Test
    fun keySetIsExactlyTheWireContract() {
        val result = SshConnectResult.of(true, null, null)

        assertEquals(setOf("connected", "hostKeyFingerprint", "error"), result.keys)
    }

    @Test
    fun connectedResultCarriesTheFingerprintAndNoError() {
        val result = SshConnectResult.of(true, fingerprint, null)

        assertEquals(true, result[SshConnectResult.KEY_CONNECTED])
        assertEquals(fingerprint, result[SshConnectResult.KEY_HOST_KEY_FINGERPRINT])
        assertNull(result[SshConnectResult.KEY_ERROR])
    }

    @Test
    fun failedResultCarriesTheErrorAndNoFingerprint() {
        val message = "SSH host key changed: stored $fingerprint, server presented another. " +
            "If the server really changed, forget the host key in the config."
        val result = SshConnectResult.of(false, null, message)

        assertEquals(false, result[SshConnectResult.KEY_CONNECTED])
        assertNull(result[SshConnectResult.KEY_HOST_KEY_FINGERPRINT])
        assertEquals(message, result[SshConnectResult.KEY_ERROR])
    }
}
