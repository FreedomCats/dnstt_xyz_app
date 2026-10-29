package xyz.dnstt.app

import android.content.Intent
import io.flutter.plugin.common.MethodCall

/**
 * How the tunnel client reaches a DoH or DoT resolver; ignored for plain UDP.
 * The resolver itself is the `dnsServer` spec passed next to it.
 *
 * @property bootstrap IP address dialed instead of resolving the resolver's
 *   host name, "" to resolve it
 * @property tlsFingerprint uTLS fingerprint distribution ("Chrome", "none", …),
 *   "" for the library default
 */
data class ResolverOptions(val bootstrap: String = "", val tlsFingerprint: String = "") {

    /** Sets the options on a client; call before `start()`. */
    fun applyTo(client: mobile.DnsttClient) {
        client.setBootstrap(bootstrap)
        client.setTLSFingerprint(tlsFingerprint)
    }

    fun putInto(intent: Intent): Intent = intent.apply {
        putExtra(EXTRA_DNS_BOOTSTRAP, bootstrap)
        putExtra(EXTRA_TLS_FINGERPRINT, tlsFingerprint)
    }

    companion object {
        const val EXTRA_DNS_BOOTSTRAP = "dns_bootstrap"
        const val EXTRA_TLS_FINGERPRINT = "tls_fingerprint"

        /** Reads the `dnsBootstrap` and `tlsFingerprint` arguments of a platform channel call. */
        fun from(call: MethodCall) = ResolverOptions(
            call.argument<String>("dnsBootstrap") ?: "",
            call.argument<String>("tlsFingerprint") ?: "",
        )

        fun from(intent: Intent) = ResolverOptions(
            intent.getStringExtra(EXTRA_DNS_BOOTSTRAP) ?: "",
            intent.getStringExtra(EXTRA_TLS_FINGERPRINT) ?: "",
        )
    }
}
