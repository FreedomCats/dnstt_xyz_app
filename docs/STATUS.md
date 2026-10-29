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
- No pull requests are open yet.

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
  relay accepts local clients without auth, authenticates upstream and passes
  the stream through. Greeting and credentials are pipelined, so auth adds no
  round trip through the tunnel.
  - Android: `android/app/src/main/kotlin/xyz/dnstt/app/Socks5AuthRelay.kt`,
    used by `DnsttVpnService`, `DnsttProxyService`, `SlipstreamProxyService` and
    the DNS server tests in `MainActivity`. The prebuilt `dnstt.aar` is unchanged.
  - Desktop: `lib/services/socks5_auth_relay.dart` for connections; Slipstream
    tests pass credentials to `socks5_proxy`; DNSTT tests call the new Go export
    `dnstt_test_dns_server_auth` (`go_src/desktop/desktop.go`). Old desktop
    libraries without that symbol still load; only authenticated DNSTT tests
    fail on them.
- Tests: `test/socks5_auth_relay_test.dart` (5 tests) and
  `android/app/src/test/kotlin/xyz/dnstt/app/Socks5AuthRelayTest.kt` (4 tests)
  run the relays against a fake SOCKS5 server that requires auth. All pass;
  the debug APK builds; `flutter analyze` shows no new issues; `go vet` passes.
- Not yet verified against a real server and device.

## Next steps

1. **Live check of SOCKS5 auth** on a device with a real server: VPN and proxy
   modes, DNSTT and Slipstream, DNS server tests, wrong password (expect
   `Socks5AuthRelay: Upstream SOCKS5 authentication failed` in logcat).
2. **Upstream pull request for issue #15** (the user wants it visible upstream):
   - branch from current upstream `master`, cherry-pick only the SOCKS5 auth
     commit (its `CLAUDE.md` hunk may conflict: upstream has no `@AGENTS.md`
     line);
   - rerun Dart and Kotlin tests and the APK build;
   - PR body with `Closes #15`. This session has no access to the upstream
     repository: the user opens the PR from the fork, or access is attached.
3. **Fixes from `docs/CODE_REVIEW.md`**, in this order:
   1. IPv6 leak in VPN mode and device DNS queries bypassing the tunnel.
   2. "Share proxy" exposes an open SOCKS5 proxy to the LAN. Now more
      important: with upstream auth, the relay on `0.0.0.0` lends the upstream
      account to anyone on the network. Add local auth for shared mode.
   3. Release signing key and rebuilding `dnstt.aar` / `libslipstream_client.so`
      in CI; Slipstream for all Android ABIs.
   4. Pull request CI: `flutter analyze`, `flutter test`, `go test ./...`,
      Kotlin unit tests; fix or replace the stale `test/widget_test.dart`.
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
