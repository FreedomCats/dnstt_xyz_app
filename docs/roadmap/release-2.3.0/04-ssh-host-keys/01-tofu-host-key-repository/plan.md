---
kind: task
status: done
detailed: true
---

# Verify the SSH host key on first use and refuse a changed key

## Task

Stop accepting any SSH host key. `SshTunnelClient.kt:91` sets
`StrictHostKeyChecking=no`, so JSch's default repository accepts a substituted
server key; for DNSTT the Noise layer authenticates the server, but the SSH
layer is not protected against impersonation. Implement the trust-on-first-use
design of `docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md`, section 5.2, on the Android
side: a JSch `HostKeyRepository` that remembers the SHA-256 fingerprint of the
first key, accepts the same key later, and refuses a different one with both
fingerprints in the error text. There is no dialog: the SSH client runs in the
background path of the app and the accepted scheme is refusal plus "forget the
host key" in the config editor.

This task covers the repository, its wiring into `SshTunnelClient` and the
Kotlin unit test. The config field and the import/export half are
[03-config-fingerprint](../03-config-fingerprint/plan.md); the method-channel
flow that passes the stored value in and the accepted value back is
[04-connect-wiring](../04-connect-wiring/plan.md). Until those land the client
is called without an expected fingerprint, which is trust on first use on every
connect and does not weaken this change. The real-server check is
[06-live-check](../06-live-check/plan.md).

## Steps

1. Create
   `android/app/src/main/kotlin/xyz/dnstt/app/SshHostKeyRepository.kt` with
   `class SshHostKeyRepository(expectedFingerprint: String?) : HostKeyRepository`:
   - Normalize the constructor value once:
     `private val storedFingerprint = expectedFingerprint?.trim()?.takeIf { it.isNotEmpty() }`.
     Expose it read-only; the error message needs it.
   - `fingerprintOf(key: ByteArray)`: SHA-256 of the blob through
     `MessageDigest.getInstance("SHA-256")`, standard base64 without padding,
     prefix `SHA256:`. Use
     `kotlin.io.encoding.Base64.Default.withPadding(Base64.PaddingOption.ABSENT)`
     (the Kotlin plugin is 2.2.20 in `android/settings.gradle.kts`). Do not use
     `android.util.Base64`: under the JVM unit tests it is a stub that returns
     null (`testOptions.unitTests.isReturnDefaultValues = true` in
     `android/app/build.gradle.kts`).
   - `check(host, key)`: compute the presented fingerprint and keep it in
     `presentedFingerprint`. With no `storedFingerprint`, set
     `acceptedFingerprint` and return `HostKeyRepository.OK` (TOFU); with an
     equal value, do the same; otherwise set `keyChanged = true` and return
     `HostKeyRepository.CHANGED`. Ignore `host`: JSch sees `127.0.0.1:7001`
     through the tunnel, while the fingerprint belongs to the config and the
     server behind it.
   - Companion `changedMessage(stored: String, presented: String)`:
     `"SSH host key changed: stored $stored, server presented $presented. If the server really changed, forget the host key in the config."`
   - Implement the rest of the interface minimally and document why:
     `add` is a no-op (the key was accepted in `check`), both `remove`
     overloads are no-ops (forgetting is a config action, not a repository
     action), `getKnownHostsRepositoryID()` returns a short label such as
     `"config"`, and both `getHostKey` overloads return `emptyArray()`.
   - KDoc: the repository is per connection and per config; it holds no global
     state, so two configs for different servers cannot see each other's keys.
2. Create
   `android/app/src/test/kotlin/xyz/dnstt/app/SshHostKeyRepositoryTest.kt`:
   - `fingerprintOf(ByteArray(0))` equals
     `SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU`. This pins SHA-256,
     the standard alphabet, the missing padding and the prefix.
   - Use two different non-empty blobs; wrap at least one in
     `HostKey("host", HostKey.ED25519, blob, null)` so the test exercises
     JSch's key type, not only raw bytes.
   - A repository with no expectation accepts the first blob (OK, accepted
     fingerprint set), accepts the same blob again, and returns CHANGED for the
     other blob with `keyChanged == true` and a message containing both
     fingerprints.
   - A repository constructed with `fingerprintOf(blobA)` accepts A and
     returns CHANGED for B.
   - A new repository with no expectation (the config was forgotten) accepts
     B, which is the "forget and accept the new key" path.
   - No server, socket, Android runtime or real key material.
3. Wire the repository into `SshTunnelClient.kt`:
   - Add `var acceptedFingerprint: String? = null` with a private setter next
     to `lastError` (line 44); reset it at the start of `connect` and in
     `disconnect`.
   - Add `expectedFingerprint: String? = null` to `connect` (lines 55-59) and
     document that null or empty means trust on first use.
   - Before the `try`, create
     `val hostKeyRepository = SshHostKeyRepository(expectedFingerprint)`; after
     `val jsch = JSch()` (line 69) set `jsch.hostKeyRepository =
     hostKeyRepository`.
   - Replace `put("StrictHostKeyChecking", "no")` (line 91) with `"yes"`. Do not
     use `"ask"`: there is no `UserInfo`, so it only changes the wording of the
     rejection.
   - After the session is confirmed connected (lines 107-113), set
     `acceptedFingerprint = hostKeyRepository.acceptedFingerprint`.
   - In the catch (lines 122-127) prefer the repository's message:
     `lastError = if (hostKeyRepository.keyChanged) SshHostKeyRepository.changedMessage(hostKeyRepository.storedFingerprint!!, hostKeyRepository.presentedFingerprint!!) else e.message ?: "Unknown SSH error"`.
     Keep the `disconnect()` call. JSch's own text for this path is only
     `HostKey has been changed: <host>` and names no fingerprints, so it must
     not reach the UI. Do not put key bytes into log lines; fingerprints are
     public and may be logged.
4. Run
   `(cd android && ./gradlew :app:testDebugUnitTest --tests 'xyz.dnstt.app.SshHostKeyRepositoryTest')`,
   then the full `(cd android && ./gradlew :app:testDebugUnitTest)`. The
   prepared `android/app/libs/dnstt.aar` and the three `jniLibs` executables
   must be in place; do not rebuild them.
5. Inspect the diff: only the new repository, the new test and
   `SshTunnelClient.kt` change. `grep -RIn "StrictHostKeyChecking"
   android/app/src/main/kotlin` shows only `yes`; `git diff --check` passes.

## Done when

- The fingerprint is exactly `SHA256:` plus unpadded standard base64 of the
  SHA-256 of the key blob, and the unit test pins a known digest.
- The repository accepts a first key and records its fingerprint, accepts the
  same key, refuses a different key with both fingerprints and the hint, and
  accepts a new key after the expectation is cleared.
- `SshTunnelClient` installs the repository, uses
  `StrictHostKeyChecking=yes`, exposes `acceptedFingerprint`, and sets
  `lastError` to the message naming both fingerprints instead of JSch's
  host-only message.
- `:app:testDebugUnitTest` passes with the new test class; no Dart, Go, Gradle,
  workflow or documentation file changes in this task.
- No live server, device or network access is used.

## Risks and what is needed from the user

- JSch 0.2.18 rejects a non-OK result only under `StrictHostKeyChecking=ask`
  or `yes`; with `yes` and no `UserInfo` it throws before authentication. The
  unit test proves the repository, not the full SSH handshake;
  [06-live-check](../06-live-check/plan.md) proves the handshake.
- JSch may call `add` after `check` returns OK and may read `getHostKey`; the
  no-op and empty implementations are intentional for a config-backed store.
  If a future JSch version depends on them, the live check catches it.
- Do not use JSch's `HostKey.getFingerPrint`: its hash and format are not what
  `ssh-keygen -lf` prints and users compare. The explicit SHA-256 encoder in
  this task is the format.
- Do not persist the accepted fingerprint in this task: the config field is
  [03-config-fingerprint](../03-config-fingerprint/plan.md) and the flow is
  [04-connect-wiring](../04-connect-wiring/plan.md). A second store would
  become a second source of truth.
- `kotlin.io.encoding.Base64` is stable in Kotlin 2.2.20; if the toolchain
  reports the API as experimental, add the opt-in annotation rather than
  switching to the Android stub.
- `SshTunnelClient.kt` is also touched by
  [02-ssh-vpn-port-fix](../02-ssh-vpn-port-fix/plan.md); leave the port
  constant change to that task and keep this diff to host-key verification.
- No user action is needed for the unit test; no SSH server is contacted here.

## Outcome

The Android side verifies the SSH host key on first use.
`SshHostKeyRepository` computes `SHA256:` plus unpadded standard base64 of
the SHA-256 of the public key blob, accepts the first key when the config
carries no fingerprint, accepts the same key later, and refuses a different
one with both fingerprints and the hint to forget the key in the config.
`SshTunnelClient` installs the repository per connection, uses
`StrictHostKeyChecking=yes` and no `UserInfo`, exposes `acceptedFingerprint`,
and replaces JSch's host-only change text with the repository's message. The
unit test pins the digest of the empty blob and covers first use, the same
key, a changed key, a stored fingerprint and the forgotten-key path. The full
Android unit suite passes (17 tests).

Decisions taken while moving:

- Inside one connection the first accepted key is the reference when the
  config has no fingerprint, so a second different key is still refused; the
  stored fingerprint stays the config value.
- The error path falls back from `storedFingerprint` to `acceptedFingerprint`
  for the message, so a change detected against the first key of the
  connection cannot raise a `NullPointerException` while building the text.
- `acceptedFingerprint` is reset when a new connection actually starts, not on
  a call that returns because the tunnel is already running.
- `add`, both `remove` methods and both `getHostKey` methods are no-ops: the key
  lives in the config, and forgetting it is a config action.

Left to the next nodes by design: persisting the accepted fingerprint
([03-config-fingerprint](../03-config-fingerprint/plan.md),
[04-connect-wiring](../04-connect-wiring/plan.md)) and the live handshake
check ([06-live-check](../06-live-check/plan.md)). JSch 0.2.18 calls the
repository once per `connect` and does not recheck the key on rekey, so the
protection added here is the check at connection setup.
