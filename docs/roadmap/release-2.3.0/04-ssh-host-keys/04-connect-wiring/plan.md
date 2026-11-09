---
kind: task
status: done
detailed: true
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

1. `android/app/src/main/kotlin/xyz/dnstt/app/MainActivity.kt`, the two
   channel cases:
   - In `"connectSshTunnel"` (lines 142-153) read
     `val sshHostKeyFingerprint = call.argument<String>("sshHostKeyFingerprint")`
     and pass it to `connectSshTunnel` after `sshPrivateKey`.
   - In `"connectSshTunnelVpn"` (lines 154-165) read the same argument and pass
     it to `connectSshTunnelWithVpn`.
   - The channel argument name is `sshHostKeyFingerprint`, identical to the
     config JSON key from [03-config-fingerprint](../03-config-fingerprint/plan.md);
     do not add a second spelling.

2. Create
   `android/app/src/main/kotlin/xyz/dnstt/app/SshConnectResult.kt` with the
   single result shape used by both channel methods:
   - `object SshConnectResult` with
     `const val KEY_CONNECTED = "connected"`,
     `const val KEY_HOST_KEY_FINGERPRINT = "hostKeyFingerprint"`,
     `const val KEY_ERROR = "error"` and
     `fun of(connected: Boolean, hostKeyFingerprint: String?, error: String?): Map<String, Any?>`.
   - KDoc: the three keys are the wire contract with
     `lib/services/vpn_service.dart`; every result path of `connectSshTunnel`
     and `connectSshTunnelVpn` goes through `of`; on failure the caller passes
     `null` for the fingerprint and the already-captured error text, never a
     field read from a client that was cleared.
   - Why a map and not a boolean: the outcome, the accepted fingerprint and
     the refusal text must reach Dart in one reply. A second
     `getSshHostKeyFingerprint` call would race with `disconnectSshTunnel` and
     with the already-running early return, and a `PlatformException` cannot
     carry a success fingerprint. Exactly these three keys, no nesting.
   - The separate file exists so a plain JVM test pins the format without
     Robolectric or a `MainActivity` instance.

3. `MainActivity.connectSshTunnel` (lines 640-717):
   - Add `sshHostKeyFingerprint: String?` after `sshPrivateKey` and pass
     `expectedFingerprint = sshHostKeyFingerprint` to `SshTunnelClient.connect`
     (lines 671-675). `SshTunnelClient` already accepts null or empty and
     treats it as trust on first use.
   - The already-running early return (lines 650-653) becomes
     `result.success(SshConnectResult.of(true, sshTunnelClient?.acceptedFingerprint, null))`.
     The client that is running is the one a previous call stored.
   - Success branch (lines 677-684): build the response in the coroutine,
     before the `runOnUiThread` block:
     `val response = SshConnectResult.of(true, sshTunnelClient?.acceptedFingerprint, null)`.
     Post that value; do not read `acceptedFingerprint` inside the UI lambda,
     because `runOnUiThread` runs later and `sshTunnelClient` can be cleared by
     a concurrent disconnect. `connected` is set before the posting, so a
     disconnect between the two does not change the reply to this call.
   - Failure branch (lines 685-698): keep the existing
     `val error = sshTunnelClient?.lastError ?: "SSH connection failed"` and
     build `val response = SshConnectResult.of(false, null, error)` **before**
     `sshDnsttClient?.stop()` and `sshTunnelClient = null`:
     `lastError` is read through the client field, and the branch nulls it
     before posting the result. Pass `null` as the fingerprint on failure even
     if some field were set; a refused key must never look accepted.
   - Outer catch (lines 699-715): capture
     `val error = sshTunnelClient?.lastError ?: e.message ?: "SSH connection failed"`
     first, build `SshConnectResult.of(false, null, error)`, then run the
     existing cleanup.
   - Keep the `eventSink?.success("ssh_tunnel_connected" / "ssh_tunnel_error")`
     calls and their order around `result.success` unchanged.
   - While here, the success log line (line 679) may name
     `SshTunnelClient.SOCKS5_PROXY_PORT` instead of the literal 1080, matching
     the VPN path at line 835; no behavior change.

4. SSH VPN path in the same file:
   - `connectSshTunnelWithVpn` (lines 762-783): add `sshHostKeyFingerprint:
     String?` after `sshPrivateKey`, put it into
     `SshVpnParams` at line 776 and pass it on the direct call at line 782.
   - `SshVpnParams` (lines 785-793): add `val sshHostKeyFingerprint: String?`
     after `sshPrivateKey`.
   - `onActivityResult` (lines 905-918): pass
     `params.sshHostKeyFingerprint` to `startSshTunnelWithVpn` after
     `params.sshPrivateKey`, so the permission dialog does not lose it.
   - Permission-denied branch of `onActivityResult` (lines 935-940): capture
     `val sshPending = pendingSshVpnParams != null` before the fields are
     cleared. Respond with
     `SshConnectResult.of(false, null, "VPN permission denied")` when
     `sshPending`, otherwise keep the current `pendingResult?.success(false)`:
     the shared branch also answers `requestPermission`, Slipstream and the
     regular VPN call, whose Dart side still expects a boolean.
   - `startSshTunnelWithVpn` (lines 797-870) gets the same treatment as step 3:
     parameter, `expectedFingerprint = sshHostKeyFingerprint` (lines 827-831),
     map on the early return (lines 807-810), on success (lines 833-841, built
     before `runOnUiThread`) and on both failure paths (lines 842-854 and
     855-868, error captured before `sshTunnelClient` is nulled).
   - `startVpnServiceForSsh` (lines 872-883) does not change.

5. `lib/services/vpn_service.dart`:
   - Next to `_lastError` (line 33) add
     `String? _lastSshHostKeyFingerprint;` with a public getter, and private
     string constants for the three wire keys (`_keyConnected`,
     `_keyHostKeyFingerprint`, `_keyError`) so the spellings live in one place.
   - Add `String? sshHostKeyFingerprint` after `sshPrivateKey` in
     `connectSshTunnel` (line 1171) and `connectSshTunnelVpn` (line 1248).
   - In `connectSshTunnel`, next to `_lastError = null` (line 1195) also clear
     `_lastSshHostKeyFingerprint = null`. The desktop branch returns before
     this point, so the field stays null there; do not add a platform check.
   - Send `'sshHostKeyFingerprint': sshHostKeyFingerprint` in the method
     arguments (line 1211 block) and switch to `invokeMethod<dynamic>`.
   - Add a private parser returning a record
     `({bool connected, String? fingerprint, String? error})`:
     a `Map` yields `connected == true`, the string values of
     `hostKeyFingerprint` and `error` (non-string values read as null); a bare
     `bool` yields `(connected: value, fingerprint: null, error: null)` so a
     missed native path cannot crash the UI; anything else yields
     `(connected: false, fingerprint: null, error: 'Unexpected SSH channel response')`.
   - On success store `_lastSshHostKeyFingerprint = parsed.fingerprint` and
     keep `_lastError = null`; on failure set
     `_lastSshHostKeyFingerprint = null` and `_lastError = parsed.error`
     (null is allowed; the snackbar then falls back to its generic text).
     Return `parsed.connected`.
   - `connectSshTunnelVpn` gets the same resets, argument and parsing
     (line 1274 and the call at line 1290); its desktop delegation passes
     `sshHostKeyFingerprint` to `connectSshTunnel`, where it is ignored.
   - The desktop branch of `connectSshTunnel` accepts the parameter and ignores
     it; do not add `-o StrictHostKeyChecking` or `-o UserKnownHostsFile`
     options to the system `ssh` command, and do not change its argument lists.
   - `disconnectSshTunnel` (lines 1326-1364) clears
     `_lastSshHostKeyFingerprint` in both the Android path and the desktop
     delegation, so the getter never reports the key of a closed connection.

6. `lib/screens/home_screen.dart`:
   - Pass `sshHostKeyFingerprint: config.sshHostKeyFingerprint` in the SSH
     proxy call (lines 886-895) and the SSH VPN call (lines 899-908).
   - Before the `bool success;` branch chain (around line 881) capture
     `final sshConfigId = isSshTunnel ? state.activeConfig?.id : null;`.
   - After the chain and before the snackbar (around line 965) add
     `if (success && sshConfigId != null) { await state.rememberSshHostKeyFingerprint(configId: sshConfigId, fingerprint: _vpnService.lastSshHostKeyFingerprint); }`.
     This persists on both SSH modes, writes nothing on failure, and is a no-op
     on desktop (the fingerprint is null there).
   - Do not change the snackbar code: `_vpnService.lastError` already reaches it
     (lines 983-993), and the changed-key text now contains both fingerprints
     and the "forget the host key" hint. Do not add a dialog, a banner or a
     fingerprint input field.

7. `lib/providers/app_state.dart`, next to `updateDnsttConfig` (line 229):
   - Add
     `Future<void> rememberSshHostKeyFingerprint({required String configId, required String? fingerprint})`:
     trim the value; return without writing when it is null or empty; take the
     **current** `_activeConfig` (not a captured object) and return when it is
     null or its `id` differs from `configId`; return when the value already
     equals `config.sshHostKeyFingerprint`; otherwise assign the field and
     `await updateDnsttConfig(config)`.
   - KDoc: called only after a successful connection; a null or blank value
     means nothing was observed (desktop, or a native reply without a
     fingerprint); the id check prevents writing config A's accepted key into
     config B after a config switch during the connection, and prevents
     rewriting a config that the editor has since replaced with a stale copy.

8. Tests:
   - Create
     `android/app/src/test/kotlin/xyz/dnstt/app/SshConnectResultTest.kt` with
     three plain JUnit 4 tests: the key set is exactly
     `{"connected", "hostKeyFingerprint", "error"}`; a connected result carries
     the fingerprint and a null error; a failed result carries the error and a
     null fingerprint. No Android runtime, no server.
   - Create `test/ssh_connect_wiring_test.dart`:
     - Call `TestWidgetsFlutterBinding.ensureInitialized()` and install a mock
       handler with
       `TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('xyz.dnstt.app/vpn'), handler)`.
       Do **not** call `VpnService.init()` in this file: on the test VM
       `Platform.isLinux` is true, `init()` would set the singleton to desktop
       and route the calls away from the channel. Never let a call run without
       the mock handler, or `MissingPluginException` flips `_platformSupported`
       to false for the rest of the file.
     - Success: the handler records the method name and arguments and returns
       `{'connected': true, 'hostKeyFingerprint': presented, 'error': null}`.
       Call `connectSshTunnel` with an expected value and assert: the method is
       `connectSshTunnel`, the arguments carry `sshHostKeyFingerprint`, the
       call returns true, `lastSshHostKeyFingerprint` is the presented value and
       `lastError` is null.
     - Changed key: first answer with a success to set the observed value, then
       switch the handler to
       `{'connected': false, 'hostKeyFingerprint': null, 'error': message}` with
       `message` naming the stored and the presented fingerprints. Call again
       and assert it returns false, `lastError` equals the message (the UI
       prints it verbatim), and `lastSshHostKeyFingerprint` is null — the
       stored value never becomes the presented one.
     - VPN method: assert `connectSshTunnelVpn` sends the same argument and
       parses the same map; this is the path that goes through the permission
       round trip on a device.
     - Legacy reply: a bare `true` from the handler yields true, null
       fingerprint and null error, so the Dart side does not cast-crash on a
       boolean.
     - Use documentation values only: the domain `t.example.com` (RFC 2606),
       the made-up public key `List.filled(64, '0').join()` and the
       documentation fingerprint already used in
       `test/config_fingerprint_test.dart`.
   - Extend the same file with an `AppState` group:
     - Seed `SharedPreferences.setMockInitialValues` with `dnstt_configs`
       holding an SSH config, and `active_config` holding its id; build
       `StorageService.init()` and `AppState.init` as in
       `test/config_fingerprint_test.dart`.
     - A null fingerprint (the config has none) is written: `activeConfig`,
       `dnsttConfigs` and the `dnstt_configs` JSON all show the value after
       `rememberSshHostKeyFingerprint`.
     - An equal value and a blank or null value leave the stored value
       unchanged.
     - A `configId` that is not the active config's id writes nothing to
       `dnstt_configs`.
   - Do not attempt a widget test of the home screen connect flow: on the test
     VM `HomeScreen.initState` calls `VpnService.init()`, which marks the
     singleton as desktop and takes the system-`ssh` branch. The persistence
     gate is the one-line `success && sshConfigId != null` call in step 6 and
     is checked by inspection; the snackbar rendering is checked live.

9. Checks:
   - `flutter analyze`, `flutter test`.
   - `(cd android && ./gradlew :app:testDebugUnitTest)`; the prepared
     `android/app/libs/dnstt.aar` and the three `jniLibs` executables must be in
     place, do not rebuild them.
   - `flutter build apk --debug --target-platform android-arm64` for the
     channel compile.
   - `grep -RIn "hostKeyFingerprint\|sshHostKeyFingerprint"` in
     `MainActivity.kt`, `SshConnectResult.kt`, `vpn_service.dart` and
     `home_screen.dart` and confirm: one channel argument name, one map key
     spelling per side, and exactly one caller of
     `rememberSshHostKeyFingerprint`, inside the success gate.
   - `git diff --check`; the diff touches the Kotlin channel and the new result
     object, the Dart service, the state, the home screen and the two test
     files only. No Go, Gradle, workflow or documentation file changes; no
     config format change.

## Done when

- Both channel methods send `sshHostKeyFingerprint` from the request and both
  Kotlin connect paths pass it to `SshTunnelClient.connect` as
  `expectedFingerprint`; the VPN permission round trip keeps it in
  `SshVpnParams`.
- Every result path of `connectSshTunnel` and `connectSshTunnelVpn` — early
  return, success, connection failure, outer catch, VPN permission denied —
  replies with the `{connected, hostKeyFingerprint, error}` map;
  `SshConnectResultTest` pins the keys and the null handling, and the VPN
  permission denial for an SSH pending call replies with the map while the
  other methods keep their boolean.
- On success Dart stores the accepted fingerprint in
  `lastSshHostKeyFingerprint` and clears `lastError`; on failure it sets
  `lastError` to the native text and leaves the observed fingerprint null. The
  mocked-channel tests prove both, including that the expected value is in the
  call arguments and that the previously observed value is cleared by a failed
  attempt.
- `AppState.rememberSshHostKeyFingerprint` writes only a non-null, non-blank,
  changed value into the current active config with the given id, and the value
  reaches `dnstt_configs`; null, blank, equal and wrong-id calls write nothing
  (the `AppState` tests in `test/ssh_connect_wiring_test.dart`).
- The home screen passes `config.sshHostKeyFingerprint` in both SSH calls and
  calls the persistence helper only when `success` is true and the connection
  is SSH; the changed-key text is shown by the existing snackbar through
  `_vpnService.lastError`, with the stored and the presented fingerprints and
  the "forget the host key" hint. Nothing is persisted on failure, so the
  stored value survives a CHANGED reply.
- Desktop SSH accepts the parameter and ignores it; the system `ssh` command
  and its options are unchanged; the fingerprint is never required on desktop.
- `flutter analyze`, `flutter test`, `:app:testDebugUnitTest` and the debug APK
  build pass; no Go file changes, no config format change and no UI for typing
  a fingerprint by hand.
- The real-server behaviour (first key stored, matching key accepted, changed
  key refused in the UI, forgotten key accepted again) is checked in
  [06-live-check](../06-live-check/plan.md); this task is proven without a
  network.

## Risks and what is needed from the user

- The channel result changes from a boolean to a map. Every `result.success`
  path must use the new shape, including the already-running branches, both
  failure paths and the VPN permission-denied branch; a missed path becomes a
  Dart parse fallback, not a crash, but it loses the refusal text. The Dart
  parser tolerates a bare boolean only as a safety net, not as an alternative
  contract.
- The failure branches null `sshTunnelClient` before they call
  `result.success`. Capture `lastError` first, otherwise the refusal message
  with both fingerprints is replaced by a generic error. In the success path
  build the map before `runOnUiThread`, not inside it.
- `SshTunnelClient.disconnect()` resets `acceptedFingerprint`; the success
  reply must be built while the client is still the one that connected. On
  failure the reply carries a null fingerprint by construction, so a refused
  key can never be persisted.
- The map keys are stringly typed across Kotlin and Dart. The Kotlin side has
  constants and a unit test; the Dart side has private constants and the mocked
  channel tests. There is still no cross-language test; the grep in step 9 is
  the check that the spellings match.
- The fingerprint is written to the config object captured at connect time by
  id. If the user edits the config or switches it while the connection is in
  flight, the helper skips the write when the active config's id no longer
  matches; otherwise the last save wins, as before. A skipped write means the
  next connection treats the key as first use again — the accepted TOFU window.
- A crash between a successful connect and the Dart save loses the fingerprint;
  the next connect treats the key as first use again. This is the accepted TOFU
  window and is not retried here.
- The widget-level rendering of the changed-key snackbar cannot be tested on
  the test VM, because the home screen initialises `VpnService` as desktop
  there. The Dart test proves the text reaches `lastError`; the live check
  proves the snackbar.
- No live server, device or network is used in this task. No user action is
  needed for the local checks; the live check needs the user's SSH server in
  [06-live-check](../06-live-check/plan.md).

## Outcome

The fingerprint now travels both ways in one reply. Both `connectSshTunnel` and
`connectSshTunnelVpn` read `sshHostKeyFingerprint` from the call, carry it in
`SshVpnParams` across the VPN permission round trip, and pass it to
`SshTunnelClient.connect(expectedFingerprint = ...)`; the already-running early
return reports the fingerprint the running client accepted. Every result path —
early return, success, connection failure, outer catch and the VPN permission
denial for a pending SSH call — replies with the map built by the new
`SshConnectResult` (`connected`, `hostKeyFingerprint`, `error`); the other
callers of the shared permission-denied branch still receive a boolean. The
success map is built before `runOnUiThread`, and every failure captures
`lastError` before `sshTunnelClient` is cleared, so the changed-key text with
both fingerprints survives. The SSH proxy success log now names
`SshTunnelClient.SOCKS5_PROXY_PORT` like the VPN path.

Dart parses the reply with one private parser that accepts the map, a bare
boolean as a safety net and turns anything else into `Unexpected SSH channel
response`. `lastSshHostKeyFingerprint` is reset at the start of both connect
methods, holds the accepted value only after a success, and is cleared by a
failure, a `PlatformException` and both disconnect paths. `home_screen.dart`
passes `config.sshHostKeyFingerprint` in both SSH calls and calls
`AppState.rememberSshHostKeyFingerprint` only under `success && sshConfigId !=
null`; the helper trims the value, writes nothing for null, blank or unchanged
values, and checks the current active config by id before saving, so a config
switch during the connection cannot receive another config's key. The existing
snackbar shows the refusal text through `lastError`; nothing is persisted on
failure, so a CHANGED reply leaves the stored value in place.

Decisions taken while moving:

- The desktop helper takes the fingerprint parameter and ignores it, and its
  KDoc says so: that path runs the system `ssh` without host key verification.
  The comment was corrected during review from the plan's "its own
  `known_hosts`" wording, which does not match the command line.
- `rememberSshHostKeyFingerprint` takes the current `_activeConfig` rather than
  a captured object and compares its id with the one captured before the
  connect call; the same check covers a config edited or replaced meanwhile.
- The Dart test installs the mock channel handler before any call and never
  calls `VpnService.init()`: the test VM reports Linux and would route the call
  to the desktop branch.

Checks: `flutter analyze` is clean; `flutter test` passes (103 tests, 8 new in
`test/ssh_connect_wiring_test.dart`); `:app:testDebugUnitTest` passes (21
tests, 3 new in `SshConnectResultTest`); the debug APK builds for arm64; the
key spellings and the single `rememberSshHostKeyFingerprint` caller check as
the plan requires; `git diff --check` is clean. Apart from this plan, the diff
touches only `MainActivity.kt`, `SshConnectResult.kt`, `vpn_service.dart`,
`home_screen.dart`, `app_state.dart` and the two new test files: no Go, Gradle,
workflow or other documentation file changed, and the config format is
untouched.

Noticed while working: the desktop SSH path disables host key verification
(`StrictHostKeyChecking=no`, `UserKnownHostsFile=/dev/null`), so desktop is not
protected and the config field has no effect there. This is pre-existing and
outside this task; it belongs to
[05-docs-and-review](../05-docs-and-review/plan.md) — whose current text would
document the desktop path as using OpenSSH's `known_hosts` — and to the
user's decision on whether to close the gap.

Left by design: the real-server behaviour (first key stored, matching key
accepted, changed key refused in the UI, forgotten key accepted again) is
[06-live-check](../06-live-check/plan.md), which also covers the snackbar
rendering, since the test VM cannot run the Android VPN path.
