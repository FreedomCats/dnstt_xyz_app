package xyz.dnstt.app

import com.jcraft.jsch.HostKey
import com.jcraft.jsch.HostKeyRepository
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SshHostKeyRepositoryTest {

    // Arbitrary distinct byte strings, not key material: the repository only hashes the blob.
    private val blobA = "first host key blob".toByteArray()
    private val blobB = "second host key blob".toByteArray()

    // Exercises JSch's own key type; the blob content itself is never parsed here.
    private val hostKeyA = HostKey("host", HostKey.ED25519, blobA, null)

    @Test
    fun fingerprintPinsSha256StandardBase64AndPrefix() {
        assertEquals(
            "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU",
            SshHostKeyRepository.fingerprintOf(ByteArray(0))
        )
    }

    @Test
    fun firstKeyIsAcceptedAndRemembered() {
        val repository = SshHostKeyRepository(null)

        assertEquals(HostKeyRepository.OK, repository.check(hostKeyA.host, blobA))
        assertEquals(SshHostKeyRepository.fingerprintOf(blobA), repository.acceptedFingerprint)
        assertEquals(SshHostKeyRepository.fingerprintOf(blobA), repository.presentedFingerprint)
        assertFalse(repository.keyChanged)

        assertEquals(HostKeyRepository.OK, repository.check(hostKeyA.host, blobA))
        assertEquals(SshHostKeyRepository.fingerprintOf(blobA), repository.acceptedFingerprint)
    }

    @Test
    fun changedKeyIsRefusedWithBothFingerprints() {
        val repository = SshHostKeyRepository(null)
        val first = SshHostKeyRepository.fingerprintOf(blobA)
        val second = SshHostKeyRepository.fingerprintOf(blobB)
        assertEquals(HostKeyRepository.OK, repository.check(hostKeyA.host, blobA))

        assertEquals(HostKeyRepository.CHANGED, repository.check(hostKeyA.host, blobB))
        assertTrue(repository.keyChanged)
        assertEquals(first, repository.acceptedFingerprint)
        assertEquals(second, repository.presentedFingerprint)

        val message = SshHostKeyRepository.changedMessage(first, second)
        assertEquals(
            "SSH host key changed: stored $first, server presented $second. " +
                "If the server really changed, forget the host key in the config.",
            message
        )
    }

    @Test
    fun storedFingerprintAcceptsItsKeyAndRefusesAnother() {
        val repository = SshHostKeyRepository(SshHostKeyRepository.fingerprintOf(blobA))

        assertEquals(HostKeyRepository.OK, repository.check("host", blobA))
        assertEquals(SshHostKeyRepository.fingerprintOf(blobA), repository.acceptedFingerprint)
        assertFalse(repository.keyChanged)

        assertEquals(HostKeyRepository.CHANGED, repository.check("host", blobB))
        assertTrue(repository.keyChanged)
    }

    @Test
    fun fingerprintIsTrimmedAndEmptyMeansTrustOnFirstUse() {
        assertEquals(
            SshHostKeyRepository.fingerprintOf(blobA),
            SshHostKeyRepository("  ${SshHostKeyRepository.fingerprintOf(blobA)}  ").storedFingerprint
        )
        assertNull(SshHostKeyRepository("   ").storedFingerprint)
    }

    @Test
    fun forgottenKeyIsAcceptedAgain() {
        val repository = SshHostKeyRepository(null)
        assertEquals(HostKeyRepository.OK, repository.check("host", blobB))
        assertEquals(SshHostKeyRepository.fingerprintOf(blobB), repository.acceptedFingerprint)
        assertFalse(repository.keyChanged)
    }
}
