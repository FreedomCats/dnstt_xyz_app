---
kind: task
status: todo
depends: [01-tofu-host-key-repository, 03-config-fingerprint]
---

# Pass the stored fingerprint to the SSH client and persist the accepted one

## Task

Connect the two halves: the config field from
[03-config-fingerprint](../03-config-fingerprint/plan.md) and the Kotlin
repository from [01-tofu-host-key-repository](../01-tofu-host-key-repository/plan.md).
The method channel must pass the expected fingerprint to
`SshTunnelClient.connect`, return the fingerprint the client accepted, and
return the changed-key error text so the existing snackbar can show both
fingerprints. Dart must persist the accepted fingerprint into the active config
right after a successful connection, otherwise the next connection would
accept the key again and the refusal would never happen.

The SSH proxy and SSH VPN flows both use the same client; the VPN permission
round trip must not drop the fingerprint. Desktop SSH uses the system `ssh`
and its own `known_hosts`, so the new parameter is accepted there and ignored.

## Steps

1. `android/app/src/main/kotlin/xyz/dnstt/app/MainActivity.kt`:
   - In the `"connectSshTunnel"` channel case (lines 142-153) and the
     `"connectSshTunnelVpn"` case (lines 154-165), read
     `call.argument<String>("sshHostKeyFingerprint")` and pass it to
     `connectSshTunnel` / `connectSshTunnelWithVpn`.
   - Add the field to `SshVpnParams` (lines 785-793), fill it where the pending
     parameters are stored (line 776) and pass it in `onActivityResult`
     (lines 905-918), so the VPN permission dialog does not lose it.
2. `connectSshTunnel` (lines 640-717): add the parameter, call
   `SshTunnelClient.connect(..., expectedFingerprint = sshHostKeyFingerprint)`,
   and replace every `result.success(true/false)` with one result map:
   `{"connected": Boolean, "hostKeyFingerprint": String?, "error": String?}`.
   A small private helper takes the error text explicitly. On success
   `"hostKeyFingerprint"` is `sshTunnelClient?.acceptedFingerprint`; on failure
   the helper receives `sshTunnelClient?.lastError` captured *before*
   `sshTunnelClient = null` (lines 685-692), or `e.message` in the outer catch
   (lines 699-715), falling back to `"SSH connection failed"`. The
   already-running early return (lines 650-653) returns the same map with the
   current fingerprint. Keep the `eventSink` notifications unchanged.
3. `startSshTunnelWithVpn` (lines 797-870): the same parameter, the same
   `connect` argument and the same result map, including the early return at
   lines 807-810. Capture `lastError` before the failure branch clears
   `sshTunnelClient` (lines 842-848).
4. `lib/services/vpn_service.dart`:
   - Add `String? _lastSshHostKeyFingerprint` with a public getter.
   - Add `String? sshHostKeyFingerprint` to `connectSshTunnel` (line 1171) and
     `connectSshTunnelVpn` (line 1248), pass it in the method arguments, and
     parse the returned map instead of a `bool` (`invokeMethod<dynamic>`).
   - At the start of each attempt reset both the error and the observed
     fingerprint. On success store `hostKeyFingerprint` and keep
     `_lastError` null; on failure set `_lastError` from `error` and leave the
     observed fingerprint null. Return the `connected` value.
   - The desktop branch of `connectSshTunnel` accepts the argument and ignores
     it; do not add `-o StrictHostKeyChecking` options to the system `ssh`
     command.
5. `lib/screens/home_screen.dart`:
   - Pass `sshHostKeyFingerprint: config.sshHostKeyFingerprint` in the SSH
     proxy call (lines 886-895) and the SSH VPN call (lines 899-908).
   - After the calls, before the success/failure snackbar (around line 963),
     persist the observed value: if `success && isSshTunnel`, read
     `_vpnService.lastSshHostKeyFingerprint` and `state.activeConfig`; when both
     are non-null and the value differs from
     `state.activeConfig!.sshHostKeyFingerprint`, set the field and
     `await state.updateDnsttConfig(state.activeConfig!)`. Do not write anything
     on failure; the existing snackbar prints `_vpnService.lastError`, which now
     contains both fingerprints and the "forget" hint.
6. Verify:
   - `flutter analyze`, `flutter test`.
   - `(cd android && ./gradlew :app:testDebugUnitTest)`.
   - `flutter build apk --debug --target-platform android-arm64` for the
     channel compile; the AAR and jniLibs must already be present.
   - Grep the three map keys in `MainActivity.kt` and `vpn_service.dart` and
     confirm the spellings match exactly.

## Done when

- A config with no fingerprint connects, and the accepted `SHA256:` value is
  written to the active config; a config with the matching value connects
  without changing it; a different value fails and the UI shows the stored and
  the presented fingerprints with the "forget the host key" hint.
- The VPN permission round trip preserves the expected fingerprint.
- The accepted fingerprint is persisted only after a successful connection;
  the failure path never stores the presented key.
- Non-SSH modes and desktop SSH behavior are unchanged; no Go file changes.
- `flutter analyze`, `flutter test`, `:app:testDebugUnitTest` and the debug APK
  build pass.

## Risks and what is needed from the user

- The channel result changes from a boolean to a map. Every `result.success`
  path must use the new shape, including the already-running branches and both
  failure paths; a missed path becomes a Dart cast error at runtime.
- The failure branches null `sshTunnelClient` before they call
  `result.success`. Capture `lastError` first, otherwise the refusal message
  with both fingerprints is replaced by a generic error.
- The map keys are stringly typed across Kotlin and Dart. Keep
  `connected`, `hostKeyFingerprint` and `error` identical in both files and
  check them with grep; there is no automated cross-language test here.
- The fingerprint is written to the config object captured at connect time.
  If the user edits the config concurrently, the last save wins; this matches
  the existing active-config behavior.
- A crash between a successful connect and the Dart save loses the fingerprint;
  the next connect treats the key as first use again. This is the accepted TOFU
  window and is not retried here.
- No live server is used; the full flow is checked in
  [06-live-check](../06-live-check/plan.md). No user action is needed for the
  local checks.
