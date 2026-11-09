package xyz.dnstt.app

/**
 * The single reply shape of the `connectSshTunnel` and `connectSshTunnelVpn`
 * method channel cases.
 *
 * The three keys are the wire contract with `lib/services/vpn_service.dart`:
 * [KEY_CONNECTED] is the outcome, [KEY_HOST_KEY_FINGERPRINT] the fingerprint the
 * SSH client accepted, [KEY_ERROR] the refusal text. Every result path of both
 * channel methods goes through [of]; on failure the caller passes `null` for
 * the fingerprint and the already-captured error text, never a field read from a
 * client that was cleared.
 *
 * A map rather than a boolean: the outcome, the accepted fingerprint and the
 * refusal text must reach Dart in one reply. A second
 * `getSshHostKeyFingerprint` call would race with `disconnectSshTunnel` and
 * with the already-running early return, and a `PlatformException` cannot
 * carry a success fingerprint. Exactly these three keys, no nesting.
 *
 * The separate file exists so a plain JVM test pins the format without
 * Robolectric or a `MainActivity` instance.
 */
object SshConnectResult {
    const val KEY_CONNECTED = "connected"
    const val KEY_HOST_KEY_FINGERPRINT = "hostKeyFingerprint"
    const val KEY_ERROR = "error"

    fun of(
        connected: Boolean,
        hostKeyFingerprint: String?,
        error: String?
    ): Map<String, Any?> = mapOf(
        KEY_CONNECTED to connected,
        KEY_HOST_KEY_FINGERPRINT to hostKeyFingerprint,
        KEY_ERROR to error
    )
}
