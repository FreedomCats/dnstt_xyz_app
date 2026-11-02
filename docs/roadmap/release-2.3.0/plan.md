---
kind: root
status: todo
source: docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md
branch: claude/keen-gates-rps2h8
---

# Release 2.3.0: first release of the fork with DoH/DoT and tun2socks

Ship the fork as a signed release built in CI, with the encrypted resolver
transports (DoH/DoT) and the tun2socks VPN data path checked on a device and on
desktop, then propose the SOCKS5 authentication work upstream. The features
themselves are built and described in `docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md`
and the per-stage reports; this map covers what is left: CI safety nets, two
security items of `docs/CODE_REVIEW.md`, the release, the live checks and the
upstream pull request.

Commits are made without a Jira number, as everywhere in this repository
(`AGENTS.md`, "Commits"). The journal — the resume point, the decisions and
the rejected options — is in `docs/local/roadmap/release-2.3.0/journal.md`,
outside git (see `docs/ROADMAP_WORKFLOW.md`).

## Done before this map

These came before the map; they are listed here so nobody plans them again.
Each has its report with the plan and the result:

1. Go library built from `go_src/` in CI (AAR not in git, reproducible) —
   `docs/STAGE1_GO_LIBRARY_CI.md`.
2. DoH/DoT in the Go library: the `client` package, resolver specs, bootstrap,
   uTLS, DoT redial, the UDP→DoH/DoT bridge, `Probe` —
   `docs/STAGE2_GO_DOH_DOT.md`.
3. DoH/DoT for DNSTT in the app: resolver specs in Dart, bootstrap, TLS
   fingerprint setting, every Android path, desktop FFI —
   `docs/STAGE3_APP_DOH_DOT.md`.
4. DoH/DoT for Slipstream through the bridge, Android and desktop —
   `docs/STAGE4_SLIPSTREAM_DOH_DOT.md`.
5. tun2socks in VPN mode (hev-socks5-tunnel, fake-IP DNS, IPv6), closing
   review items 1, 2 and "Simplified TCP implementation" —
   `docs/STAGE5_TUN2SOCKS.md`.
6. SOCKS5 username/password auth for the upstream proxy (upstream issue #15),
   with the relay on Android and desktop, and the review fixes.

`ci.yml` is green on every stage; none of stages 1–5 has been checked against a
real server and device yet — that is node 6 of this map.

## Done when

- `ci.yml` runs `flutter analyze` and the full `flutter test`, and both are
  green; `go vet` passes on every package that passed before.
- `libslipstream_client.so` is built in CI for `arm64-v8a`, `armeabi-v7a` and
  `x86_64`, and Slipstream connects from an APK of each ABI.
- No code path in the app binds a SOCKS5 listener to anything but `127.0.0.1`.
- An SSH connection refuses a changed host key and names both fingerprints.
- A signed release `v2.3.0-beta` is published from CI, installs on the device,
  and its version code is higher than the installed one.
- The live checks of DoH/DoT, VPN mode with tun2socks, upstream auth and SSH
  pass on the device and on desktop; the results are recorded in the journal
  and, where generally useful, in the stage reports under `docs/`.
- A pull request for issue #15 is open upstream with a green build.

## Stages

### 1. CI gate: analyzer and the full test suite

- Goal: CI catches what the developer would catch by hand, before the release
  depends on it.
- What to do, what is touched: replace `test/widget_test.dart` with a smoke
  test; run `flutter test` and `flutter analyze` on the whole tree; decide the
  analyzer baseline; `go vet` on the packages that pass today.
- Done when: `ci.yml` runs both commands and is green; a deliberately
  broken analyzer rule fails the build.
- Depends on: nothing.
- Risks and what is needed from the user: the analyzer baseline (~110 infos in
  `lib/services/`) can hide new issues; the user decides the threshold.

### 2. Slipstream binary for every Android ABI

- Goal: Slipstream works on 32-bit ARM and x86_64 devices and emulators, and
  the binary no longer comes prebuilt from upstream.
- What to do, what is touched: `scripts/build_slipstream_android.sh` in CI with
  the pinned NDK, three ABIs, artifact upload, `check_binary_paths.sh`;
  `CODE_REVIEW.md` item 3.3 closed.
- Done when: the APKs contain `libslipstream_client.so` for all three
  ABIs and the path check passes.
- Depends on: nothing.
- Risks and what is needed from the user: cross-compiling OpenSSL and picoquic for
  three ABIs takes time in CI (build cache needed); APK size grows.

### 3. Disable shared LAN access to the proxy

- Goal: close review item 3 without shipping a half-built feature.
- What to do, what is touched: remove the `0.0.0.0` branches in
  `DnsttProxyService.kt`, `SlipstreamProxyService.kt`, `SshTunnelClient.kt`;
  remove `setProxySharing` and `connectProxyShared` from `MainActivity.kt` and
  `setShareProxy` / `IsShareProxyEnabled` from `mobile.go`; update
  `CODE_REVIEW.md` and `CLAUDE.md`.
- Done when: no listener binds anything but `127.0.0.1`; tests and the APK
  build; review item 3 is marked closed with the reason.
- Depends on: nothing.
- Risks and what is needed from the user: the feature disappears; if it is wanted
  later it returns as its own stage with a password (architecture 5.1).

### 4. SSH host key verification

- Goal: an SSH connection through the tunnel no longer accepts a substituted
  server key.
- What to do, what is touched: a JSch `HostKeyRepository` with trust on first
  use, the fingerprint stored in the config
  (`sshHostKeyFingerprint`), refusal with both fingerprints on change,
  "forget host key" in the config editor, a Kotlin unit test.
- Done when: on a real server the first connection stores the key, a
  changed key refuses with both fingerprints, forgetting the key lets the new
  one in; unit test green.
- Depends on: nothing.
- Risks and what is needed from the user: a changed key blocks the user until they
  forget it (accepted); import/export must carry the field.

### 5. First release

- Goal: a signed release built in CI that the user can install and test with.
- What to do, what is touched: `version: 2.3.0+6` in `pubspec.yaml`; a
  lightweight tag `v2.3.0-beta` on the work branch; run and follow
  `release.yml` (Android, macOS arm64, macOS Intel), fix what fails; check the
  certificate SHA-256 in the release notes.
- Done when: the release is published, the APKs are signed with the
  project key, the install replaces nothing and the app starts.
- Depends on: 1, 2, 3, 4 (the release should carry all of them).
- Risks and what is needed from the user: `release.yml` has never run; macOS jobs
  are the slow and fragile part. Release APKs only from CI (`AGENTS.md`); do
  not use the "Run workflow" button, it runs `main`. The phone may hold the
  upstream app: export configs and uninstall first (same application ID,
  different signature).

### 6. Live checks

- Goal: prove on a real server and device that stages 1–5 work.
- What to do, what is touched: the check list of architecture section 6 — DoH
  and DoT for DNSTT and Slipstream, proxy and VPN modes, desktop, throughput,
  network switch, leak tests, upstream auth with and without pipelining, SSH
  mode; record what fails as new map nodes.
- Done when: every item passed or is written down as a defect with its own
  node; the results are in the journal.
- Depends on: 5.
- Risks and what is needed from the user: needs the user's tunnel server, a phone
  and a desktop; the live checks cannot be delegated to an agent.

### 7. Upstream pull request for issue #15

- Goal: the SOCKS5 authentication work goes upstream.
- What to do, what is touched: a branch from current upstream `master`,
  cherry-pick the auth commit and the review fixes, resolve `CLAUDE.md`
  conflicts, rerun the tests and the APK build, open the PR with `Closes #15`.
- Done when: the PR is open and its CI is green.
- Depends on: 3 (no relay that lends the upstream account to the LAN), 6
  (the auth path checked live).
- Risks and what is needed from the user: the session has no write access to the
  upstream repository — the user opens the PR or attaches access; the PR raises
  the shared proxy question upstream, where it may be discussed.

## Possible follow-up, not in the map

- **Tunnel DNS mode** (optional stage of the architecture, section 4.3): real
  answers for every record type through the tunnel, as a setting. Becomes a
  stage if the live checks show applications broken by fake-IP answers.
- **Shared LAN access to the proxy** with a generated password (architecture
  5.1), if the user wants the feature back.
