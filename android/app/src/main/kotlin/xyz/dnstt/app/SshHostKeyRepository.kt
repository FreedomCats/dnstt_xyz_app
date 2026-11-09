package xyz.dnstt.app

import com.jcraft.jsch.HostKey
import com.jcraft.jsch.HostKeyRepository
import com.jcraft.jsch.UserInfo
import java.security.MessageDigest
import kotlin.io.encoding.Base64

/**
 * Trust-on-first-use check of the SSH server host key for [SshTunnelClient].
 *
 * The repository receives the expected fingerprint of the config and compares it with the
 * key the server presents. No stored fingerprint means the key is accepted and remembered
 * for this connection; a different key is refused with both fingerprints in
 * [changedMessage]. The format is `SHA256:` plus unpadded standard base64 of the SHA-256
 * of the public key blob, the format of `ssh-keygen -lf`, so users can compare it.
 *
 * The instance is created per connection and belongs to one config: it keeps no global
 * state, so two configs for different servers cannot see each other's keys. Persisting
 * the accepted value is the config's job.
 */
class SshHostKeyRepository(expectedFingerprint: String?) : HostKeyRepository {

    /** Fingerprint stored in the config, trimmed; null or empty means trust on first use. */
    val storedFingerprint: String? = expectedFingerprint?.trim()?.takeIf { it.isNotEmpty() }

    /** Fingerprint of the key presented by the server in [check]. */
    var presentedFingerprint: String? = null
        private set

    /** True when [check] saw a key different from the expected fingerprint. */
    var keyChanged: Boolean = false
        private set

    /** Fingerprint accepted for this connection: the stored one or the first key seen. */
    var acceptedFingerprint: String? = null
        private set

    /**
     * Compares the presented key with the expected fingerprint: the config value, or the
     * first key accepted on this connection when the config has none. The host is ignored:
     * JSch sees `127.0.0.1:<tunnel port>` through the tunnel, while the fingerprint belongs
     * to the config and to the server behind it.
     */
    override fun check(host: String, key: ByteArray): Int {
        val presented = fingerprintOf(key)
        presentedFingerprint = presented

        // The first key seen is remembered for this connection, so a later different key is
        // still refused; with a stored fingerprint the config value is the reference.
        val expected = storedFingerprint ?: acceptedFingerprint
        if (expected == null || expected == presented) {
            acceptedFingerprint = presented
            return HostKeyRepository.OK
        }

        keyChanged = true
        return HostKeyRepository.CHANGED
    }

    /** No-op: [check] has already accepted the key, so there is nothing to store. */
    override fun add(hostkey: HostKey?, userinfo: UserInfo?) {}

    /** No-op: forgetting a key is a config action, not a repository action. */
    override fun remove(host: String?, type: String?) {}

    /** No-op: forgetting a key is a config action, not a repository action. */
    override fun remove(host: String?, type: String?, key: ByteArray?) {}

    /** Short label of the store the keys logically live in. */
    override fun getKnownHostsRepositoryID(): String = "config"

    /** Empty: the repository holds no known-hosts list, only the config fingerprint. */
    override fun getHostKey(): Array<HostKey> = emptyArray()

    /** Empty: the repository holds no known-hosts list, only the config fingerprint. */
    override fun getHostKey(host: String?, type: String?): Array<HostKey> = emptyArray()

    companion object {
        private const val FINGERPRINT_PREFIX = "SHA256:"

        /**
         * Computes the fingerprint of a public key blob in `ssh-keygen -lf` form: `SHA256:`,
         * then standard base64 of the SHA-256 digest without padding.
         */
        fun fingerprintOf(key: ByteArray): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(key)
            return FINGERPRINT_PREFIX +
                Base64.Default.withPadding(Base64.PaddingOption.ABSENT).encode(digest)
        }

        /** Error text for a changed key; both fingerprints are named so the user can compare. */
        fun changedMessage(stored: String, presented: String): String =
            "SSH host key changed: stored $stored, server presented $presented. " +
                "If the server really changed, forget the host key in the config."
    }
}
