# Project status and next steps

Resume point for new working sessions. Keep it current: update it at the end of
each stage. Like everything in `docs/`, it follows `AGENTS.md`: no dates,
environment details, servers, credentials or other personal data.

## Fork state

- The fork started identical to upstream `dnstt-xyz/dnstt_xyz_app` at `8155cde`.
- Work branch: `claude/keen-gates-rps2h8`. Commits on top of upstream:
  1. Code review of the fork (`docs/CODE_REVIEW.md`).
  2. Privacy rules for agents (`AGENTS.md`, imported from `CLAUDE.md`;
     `docs/local/` and `docs/runs/` ignored by git).
  3. English-only rule for comments, commits, memory and docs.
  4. Translation of `AGENTS.md` and `docs/CODE_REVIEW.md` into English.
  5. Upstream SOCKS5 username/password auth (see below).
  6. Fixes to the SOCKS5 auth relay after review (see below).
  7. CI builds and release signing (see below).
- No pull requests are open yet. GitHub Actions in the fork have not run yet.

## Done: upstream SOCKS5 auth (upstream issue #15)

Problem: when the SOCKS5 proxy behind the tunnel server requires RFC 1929
username/password auth, the app could not connect at all.

Solution:

- SOCKS-type configs have optional `socksUsername` / `socksPassword` fields
  (`lib/models/dnstt_config.dart`, config dialog, storage, import/export).
  Helpers `upstreamSocksUsername` / `upstreamSocksPassword` return null when no
  auth is configured.
- With credentials, the tunnel client (dnstt or slipstream) listens on a free
  localhost port and a local relay takes the user-facing proxy address. The
  relay accepts local clients without auth, reads the client's request,
  authenticates upstream and passes the stream through. Greeting, credentials
  and request go upstream in one write, so auth adds no round trip through the
  tunnel. Proxies that handle each read as one message (microsocks) drop the
  pipelined bytes; when the proxy accepts username/password auth but the
  pipelined handshake fails or stalls (auth reply not within 3 s or 3x the
  method reply time), the relay retries step by step and keeps that mode for
  the rest of the session.
  - Android: `android/app/src/main/kotlin/xyz/dnstt/app/Socks5AuthRelay.kt`,
    used by `DnsttVpnService`, `DnsttProxyService`, `SlipstreamProxyService` and
    the DNS server tests in `MainActivity`. The prebuilt `dnstt.aar` is unchanged.
  - Desktop: `lib/services/socks5_auth_relay.dart` for connections; Slipstream
    tests pass credentials to `socks5_proxy`; DNSTT tests call the new Go export
    `dnstt_test_dns_server_auth` (`go_src/desktop/desktop.go`). Old desktop
    libraries without that symbol still load; only authenticated DNSTT tests
    fail on them.
- Review fixes (commit 6):
  - fallback to a step-by-step handshake for proxies like microsocks (above);
  - the Kotlin relay starts relaying only after the handshake and after
    clearing read timeouts; before, a client idle for 60 s after CONNECT was
    disconnected;
  - the Kotlin relay catches every exception in its pool threads (an uncaught
    one crashes the app on Android);
  - on upstream failure the client gets a SOCKS5 "general failure" reply
    before the relay closes the connection.
- Tests: `test/socks5_auth_relay_test.dart` (7 tests) and
  `android/app/src/test/kotlin/xyz/dnstt/app/Socks5AuthRelayTest.kt` (6 tests)
  run the relays against a fake SOCKS5 server that requires auth and against a
  fake that handles each read as one message, like microsocks. They include an
  idle-connection test. The new tests fail on the relays from commit 5. All
  pass; the debug APK builds; `flutter analyze` shows only `avoid_print` infos
  in the relay, like the rest of `lib/services/`.
- Not yet verified against a real server and device.

## Done: CI builds and release signing

- `.github/workflows/ci.yml`: on every push and pull request runs the relay
  Dart tests, the Kotlin unit tests and `go test ./...`, then builds release
  APKs (split by ABI) and uploads them as the `android-apks` artifact for 14
  days. The job summary shows the signing certificate.
- `.github/workflows/release.yml` (from upstream, tags `v*`): the Android job
  now runs the same tests, requires the release key (fails without it), and the
  release notes show the SHA-256 of the signing certificate. The release tag
  points at the built commit (`target_commitish`); Go comes from
  `go_src/go.mod`. macOS builds are unchanged; Windows and Linux stay disabled
  as upstream left them.
- `android/app/build.gradle.kts`: release signing from `android/key.properties`
  or the `ANDROID_KEYSTORE_FILE` / `ANDROID_KEYSTORE_PASSWORD` /
  `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD` environment variables, debug key
  otherwise; VCS metadata is no longer included in the APK. Key creation and
  the secrets are described in `CLAUDE.md` ("Signing Release Builds").
- Checked locally: a release build signed with a test key from the environment
  variables, and the debug-key fallback. The workflows have not run on GitHub
  yet.
- Only `arm64-v8a` has the Slipstream binary; the `armeabi-v7a` and `x86_64`
  APKs work with DNSTT only. `dnstt.aar` and `libslipstream_client.so` are
  still prebuilt from upstream.

## Next steps

0. **First CI build** (needs the user):
   - enable GitHub Actions in the fork (Actions tab);
   - create the release key and add the four secrets (`CLAUDE.md`, "Signing
     Release Builds"); keep a backup of the key;
   - push to the work branch, download `android-apks` from the CI run and
     install the `arm64-v8a` APK on the phone;
   - for a release: lightweight tag `v*` on the work branch (`AGENTS.md`). The
     `workflow_dispatch` button uses the workflow from the default branch
     `main`, which is still upstream's.
1. **Live check of SOCKS5 auth** on a device with a real server: VPN and proxy
   modes, DNSTT and Slipstream, DNS server tests, wrong password (expect
   `Socks5AuthRelay: Upstream SOCKS5 authentication failed` in logcat).
   Check both a proxy that accepts pipelining (Dante, 3proxy or a Go server)
   and microsocks with `-u`/`-P` (expect `pipelining disabled` once in logcat).
2. **Upstream pull request for issue #15** (the user wants it visible upstream):
   - branch from current upstream `master`, cherry-pick the SOCKS5 auth commit
     and the review fixes (the `CLAUDE.md` hunks may conflict: upstream has no
     `@AGENTS.md` line);
   - rerun Dart and Kotlin tests and the APK build;
   - PR body with `Closes #15`. This session has no access to the upstream
     repository: the user opens the PR from the fork, or access is attached.
3. **Fixes from `docs/CODE_REVIEW.md`**, in this order:
   1. IPv6 leak in VPN mode and device DNS queries bypassing the tunnel.
   2. "Share proxy" exposes an open SOCKS5 proxy to the LAN. Now more
      important: with upstream auth, the relay on `0.0.0.0` lends the upstream
      account to anyone on the network. Add local auth for shared mode.
   3. Rebuild `dnstt.aar` / `libslipstream_client.so` in CI (signing is done);
      Slipstream for all Android ABIs.
   4. CI: add `flutter analyze` and the full `flutter test` after fixing or
      replacing the stale `test/widget_test.dart`; `go vet ./...` fails on
      upstream tests in `go_src/noise`.
   5. Replace the hand-written TCP stack with a tun2socks implementation.
   6. DoH/DoT transport in the DNSTT mobile library.

## Working notes

- Commit rules are in `AGENTS.md`: author `FreedomCats
  <noreply@freedomcats.invalid>`, date at midnight UTC, no session links, check
  `git diff --cached` before every commit.
- Toolchain that builds the project: Flutter 3.38.7, Android SDK platform 36,
  build-tools 35, NDK 28.2.13676358, JDK 17, Go 1.24.
- In cloud containers Maven Central may answer 429 to parallel Gradle
  downloads. Set `org.gradle.workers.max=1` and `org.gradle.parallel=false` in
  the user Gradle properties and retry; Gradle keeps what it already fetched.
  Install the NDK with `sdkmanager` up front: an interrupted Gradle download
  leaves an NDK directory without `source.properties`.
- `flutter pub get` rewrites `linux/flutter/generated_plugins.cmake` and
  `windows/flutter/generated_plugins.cmake`; revert them before committing.
  Gradle unit tests leave `android/build/`; delete it.
- Run tests:
  - `flutter test test/socks5_auth_relay_test.dart`
  - `cd android && ./gradlew :app:testDebugUnitTest --tests 'xyz.dnstt.app.Socks5AuthRelayTest'`
  - `flutter build apk --debug --target-platform android-arm64`
  - `cd go_src && go vet ./desktop`
