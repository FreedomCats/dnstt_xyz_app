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
  7. CI builds and release signing (see below), then two CI fixes: generate
     the Gradle wrapper before the Kotlin tests; actions moved to their
     Node.js 24 versions.
  8. Design and work plan for DoH/DoT and tun2socks
     (`docs/DOH_DOT_TUN2SOCKS_PLAN.md`).
  9. Stage 1 of that plan: `dnstt.aar` built from `go_src` in CI
     (`docs/STAGE1_GO_LIBRARY_CI.md`, see below).
- No pull requests are open yet. GitHub Actions are enabled in the fork, and
  the four signing secrets are set. No release has been made yet; the user
  does not want one for now.

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
- `ci.yml` runs green on GitHub: tests pass, the APKs are signed with the
  project key. Signing certificate: `CN=FreedomCats`, SHA-256
  `a0463ae9637d96ee9ad8b8ce305aa62b0c78868fa565d19111f26eca74e0500c` (public,
  it is in every APK). No Node.js 20 warnings are left.
- Actions in use: `checkout@v7`, `setup-java@v6`, `setup-go@v7`,
  `upload-artifact@v7`, `download-artifact@v7`, `action-gh-release@v3`,
  `subosito/flutter-action@v2` and `dtolnay/rust-toolchain` (composite, no
  Node). `release.yml` has not run yet: its macOS jobs, `download-artifact`
  and `action-gh-release` are untested on GitHub. The release is created only
  if all three build jobs (Android, macOS arm64, macOS Intel) succeed.
- The secret `ANDROID_KEY_ALIAS` is `dnstt`, so GitHub masks every `dnstt` in
  the logs (`***_xyz_app`). Cosmetic; the alias could move out of the secrets.
- Artifacts are only on the run's Summary page (not in the job pages, not in
  the GitHub mobile app) and need a GitHub login; releases are easier to
  install from a phone.
- Only `arm64-v8a` has the Slipstream binary; the `armeabi-v7a` and `x86_64`
  APKs work with DNSTT only. `libslipstream_client.so` is still prebuilt from
  upstream.

## Done: Go library built in CI (stage 1 of the DoH/DoT plan)

- `scripts/build_aar.sh` builds `android/app/libs/dnstt.aar` from `go_src`:
  copy in the fixed directory `/tmp/dnstt_build` (gomobile records it in the
  build info), gomobile/gobind at the version pinned in `go.mod`, Go toolchain
  from `go.mod`, `-trimpath -ldflags="-s -w -buildid="`, ABIs arm, arm64,
  amd64 (the old AAR also had x86, which Flutter never packs). Java API is the
  same as the old upstream AAR.
- Reproducible: the `.so` files are byte-identical across builds and machines.
  Two causes of differences were found and fixed: the Go and GNU build IDs
  hash the NDK compiler's path (`-buildid=` removes both), and GitHub runners
  set a global `ANDROID_NDK_HOME` to their default NDK (r27), which the script
  first preferred over the pinned r28. Now the script takes
  `$ANDROID_HOME/ndk/$NDK_VERSION` and accepts another `ANDROID_NDK_HOME` only
  with exactly that version.
- `go_src/go.mod` pins `toolchain go1.26.10`; CI used Go 1.24.0 before (no
  longer supported). Go tests pass with it.
- `scripts/check_binary_paths.sh` checks binaries and archives for machine
  paths; `--allow REGEX` for known neutral paths.
- Finding: `libapp.so` (Dart AOT) in every release APK contains the absolute
  project path (`file://<project>/.dart_tool/flutter_build/dart_plugin_registrant.dart`),
  `--obfuscate` does not remove it. In CI it is the runner checkout, which
  the check allows explicitly; a locally built release APK would carry the
  user's path. Recorded in `AGENTS.md`: release APKs only from CI.
- CI: reusable `.github/workflows/build-aar.yml` (JDK 17, Go from `go.mod`,
  NDK 28.2.13676358 via `sdkmanager`, artifact `dnstt-aar`, checksums in the
  job summary). `ci.yml` and `release.yml` build the AAR first and download
  it before the Kotlin tests and the APK build; APKs are checked for paths;
  `release.yml` also checks `libdnstt.dylib` and `slipstream-client` (untested
  until the first release run).
- `dnstt.aar` and `dnstt-sources.jar` are removed from git and ignored.
  Gradle `preBuild` stops with "run scripts/build_aar.sh" if the AAR is
  missing.
- Locally: Kotlin unit tests pass and release APKs build with the new AAR.
- `ci.yml` is green with the CI-built AAR (tests, signed APKs, path checks).
  The `.so` checksums in the job summary equal those of a local build of the
  same commit; the `.aar` file itself differs only through `classes.jar`
  (compiled by the local JDK).
- Not yet checked on a device: the Go code is unchanged, but the toolchain and
  the build are new. The user should install a CI APK and connect with DNSTT.

## Next steps

0. **First release, for installing on the phone** (the user's top priority:
   a working app on the phone comes first). Proposed to the user, waiting for
   a yes and the version:
   - bump `version:` in `pubspec.yaml` from `2.2.0+5` (same as upstream) to
     `2.3.0+6`; the APK version comes from there, not from the tag, and
     Android refuses a lower build number than the installed one;
   - lightweight tag on the work branch, proposed `v2.3.0-beta` (prerelease,
     because the name contains `beta`), pushed with `git push origin <tag>`;
   - follow the "Build and Release" run (about 20–30 min, macOS is the slow
     part) and fix what fails; check that the release notes show the
     certificate SHA-256 above;
   - the phone may have the upstream app installed: same application ID,
     different signature, so the user exports configs and uninstalls it first.
   Do not use the "Run workflow" button of "Build and Release": it runs the
   workflow from `main`, which is still upstream's code without signing.
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
   Suggested to the user, not decided: do fix 3.2 (shared proxy) before this
   PR, so upstream does not get a relay that lends the upstream account to the
   LAN.
3. **Fixes from `docs/CODE_REVIEW.md`**, in this order:
   1. IPv6 leak in VPN mode and device DNS queries bypassing the tunnel.
   2. "Share proxy" exposes an open SOCKS5 proxy to the LAN. Now more
      important: with upstream auth, the relay on `0.0.0.0` lends the upstream
      account to anyone on the network. Add local auth for shared mode.
   3. Rebuild `libslipstream_client.so` in CI (`dnstt.aar` is done);
      Slipstream for all Android ABIs.
   4. CI: add `flutter analyze` and the full `flutter test` after fixing or
      replacing the stale `test/widget_test.dart`; `go vet ./...` fails on
      upstream tests in `go_src/noise`.
   5. Replace the hand-written TCP stack with a tun2socks implementation.
   6. DoH/DoT transport in the DNSTT mobile library.
4. **DoH/DoT and tun2socks**: designed in `docs/DOH_DOT_TUN2SOCKS_PLAN.md`
   (covers 3.1, 3.3, 3.5 and 3.6). Order: build the Go library in CI, DoH/DoT in
   Go, then in the app for DNSTT, then Slipstream through a local UDP→DoH/DoT
   bridge, then tun2socks (hev-socks5-tunnel, fake-IP DNS, IPv6), then an
   optional tunnel-DNS mode. Stage 1 (Go library in CI) is done; next is
   stage 2, DoH/DoT in the Go library.

## Working notes

- Commit rules are in `AGENTS.md`: author `FreedomCats
  <noreply@freedomcats.invalid>`, date at midnight UTC, no session links, check
  `git diff --cached` before every commit.
- Toolchain that builds the project: Flutter 3.38.7, Android SDK platform 36,
  build-tools 35, NDK 28.2.13676358, JDK 17 (JDK 21 works too), Go toolchain
  pinned in `go_src/go.mod` (1.26.10; an older local Go downloads it).
- A local Android build needs `./scripts/build_aar.sh` first (about 3 minutes);
  it reads `sdk.dir` from `android/local.properties`.
- In cloud containers Maven Central may answer 429 to parallel Gradle
  downloads. Set `org.gradle.workers.max=1` and `org.gradle.parallel=false` in
  the user Gradle properties and retry; Gradle keeps what it already fetched.
  Install the NDK with `sdkmanager` up front: an interrupted Gradle download
  leaves an NDK directory without `source.properties`.
- `flutter pub get` rewrites `linux/flutter/generated_plugins.cmake` and
  `windows/flutter/generated_plugins.cmake`; revert them before committing.
  Gradle unit tests leave `android/build/`; delete it.
- `android/gradlew` and the wrapper jar are not in git (`android/.gitignore`);
  `flutter build apk --config-only` generates them in a few seconds.
- A fresh cloud container has no Flutter or Android SDK. Download the Flutter
  3.38.7 tarball from `storage.googleapis.com/flutter_infra_release` and the
  Android command-line tools from `dl.google.com`, then `sdkmanager` for
  `platforms;android-36`, `build-tools;35.0.0`, `platform-tools` and the NDK;
  write `sdk.dir` and `flutter.sdk` into `android/local.properties` (ignored).
- Following CI from a session: the fork is public, so the unauthenticated
  GitHub API works for runs and jobs
  (`api.github.com/repos/FreedomCats/dnstt_xyz_app/actions/runs`); job logs
  via the GitHub MCP tools (`get_job_logs`). The GitHub API for other
  repositories is blocked in sessions, raw files on
  `raw.githubusercontent.com` are readable.
- `workflow_dispatch` buttons only exist for workflows on the default branch
  `main`; `ci.yml` runs on every push to any branch.
- Run tests (after `./scripts/build_aar.sh`):
  - `flutter test test/socks5_auth_relay_test.dart`
  - `cd android && ./gradlew :app:testDebugUnitTest --tests 'xyz.dnstt.app.Socks5AuthRelayTest'`
  - `flutter build apk --debug --target-platform android-arm64`
  - `cd go_src && go vet ./desktop`
