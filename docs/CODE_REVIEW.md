# Code review: dnstt_xyz_app (FreedomCats fork)

Revision: `8155cde` (same as upstream `dnstt-xyz/dnstt_xyz_app` HEAD)

The review is based on reading the source. The code, build and tests were not
run.

## Project overview

The fork is identical to upstream and has no commits of its own. All findings
below apply to the original project as well.

It is a Flutter client for two DNS tunneling protocols:

- **DNSTT** (KCP + Noise over DNS TXT). A Go library: on Android it is used via
  gomobile (`go_src/mobile/mobile.go`), on desktop via FFI
  (`go_src/desktop/desktop.go`).
- **Slipstream** (QUIC over DNS). The Rust `slipstream-client` binary runs as a
  subprocess; its source is in the `vendor/slipstream-rust` submodule.

Modes:

- **Android:** device-wide VPN (TUN traffic is parsed into TCP by hand and sent
  to SOCKS5) or a plain local SOCKS5 proxy.
- **Desktop:** SOCKS5 on `127.0.0.1:7000` only.
- **SSH over DNSTT** (`SshTunnelClient.kt`, JSch library).

About 20k lines. Largest files: `lib/screens/dns_management_screen.dart`
(1539), `lib/services/vpn_service.dart` (1429), `MainActivity.kt` (1230),
`DnsttVpnService.kt` (1190).

## Serious issues (privacy and security)

### 1. IPv6 leak in VPN mode

`DnsttVpnService.kt` (around lines 418–423) sets only
`addAddress("10.0.0.2", 32)` and `addRoute("0.0.0.0", 0)`. There is no IPv6
route, so on networks with IPv6 that traffic goes directly, bypassing the
tunnel.

**Fix:** add an IPv6 address and a `::/0` route, and drop or handle those
packets instead of letting them bypass the VPN.

### 2. Device DNS queries bypass the tunnel

`processUdpPacket` (`DnsttVpnService.kt:679`) sends every DNS query as plain UDP
through a protected socket (`protect(dnsSocket)`) directly to the selected
resolver. The ISP or censor sees every domain the user visits.

In addition, a new `Thread {}` is created for every query with no limit on the
number of threads.

**Fix:** route DNS through the tunnel, for example over TCP via SOCKS5 or via
DoH inside the tunnel, and handle queries in a bounded thread pool.

### 3. "Share proxy" exposes SOCKS5 to the whole network without a password

With the option enabled, the proxy listens on `0.0.0.0`:

- `DnsttProxyService.kt:174`
- `SlipstreamProxyService.kt:116`
- `SshTunnelClient.kt:140`

There is no authentication, so anyone on the same network (for example, shared
Wi-Fi) can use the tunnel.

**Fix:** require a SOCKS5 username and password when sharing is enabled and
warn about it in the UI.

**Resolved.** The share mode was unreachable from the UI, so it was removed
instead of given a password: the `0.0.0.0` branches and `EXTRA_SHARE_PROXY`
handling in `DnsttProxyService.kt`, `SlipstreamProxyService.kt` and
`SshTunnelClient.kt`, the channel methods `setProxySharing`,
`isProxySharingEnabled`, `connectProxyShared` and `getLocalIpAddresses`, and
the Go API `setShareProxy` / `IsShareProxyEnabled` are gone; every proxy
listener binds `127.0.0.1`. A password-protected version can return as its own
stage. Evidence: the listener inventory and full checks in
[03-disable-lan-sharing](roadmap/release-2.3.0/03-disable-lan-sharing/plan.md).

### 4. SSH without server key verification

`SshTunnelClient.kt:95` sets `StrictHostKeyChecking=no`. For DNSTT this is
partly mitigated by Noise authenticating the server, but the SSH layer is still
not protected against impersonation.

**Fix:** at least remember the key fingerprint on first connection and verify
it afterwards (TOFU).

**Resolved.** The Android app now installs a trust-on-first-use
`HostKeyRepository` (`SshHostKeyRepository.kt`): the first connection stores
the `SHA256:` fingerprint in the config field `sshHostKeyFingerprint`, the same
key is accepted later, and a changed key refuses the connection with both
fingerprints and the "forget the host key in the config" hint. The config
editor has "Forget host key". Evidence: the unit test in
[01-tofu-host-key-repository](roadmap/release-2.3.0/04-ssh-host-keys/01-tofu-host-key-repository/plan.md)
and the channel/config tasks around it. The real-server check is the
[06-live-check](roadmap/release-2.3.0/04-ssh-host-keys/06-live-check/plan.md)
node or moves to the live-checks stage; this paragraph does not claim a
real-server run. The desktop SSH path is not covered in this release: it runs
the system `ssh` with host key verification disabled, documented in
`docs/SSH_TUNNEL_ARCHITECTURE.md`; desktop TOFU is a separate later change.

### 5. Release builds are signed with the debug key

`android/app/build.gradle.kts` sets
`signingConfig = signingConfigs.getByName("debug")` for release. Updates cannot
be told apart from fakes: anyone can publish an APK with the same signature.

**Fix:** create a dedicated signing key, keep it in CI secrets and sign releases
with it.

### 6. Prebuilt binaries are committed to the repository

- `android/app/libs/dnstt.aar` (about 7 MB)
- `android/app/src/main/jniLibs/arm64-v8a/libslipstream_client.so`

The Android CI does not rebuild them, so there is no way to verify they were
built from the sources in the repository.

**Fix:** build the AAR (gomobile) and the `.so` (cargo-ndk) in CI.

**Resolved.** `build-aar.yml` builds `dnstt.aar` from `go_src/`, and
`build-slipstream-android.yml` builds the three Slipstream executables from the
pinned vendored source. Both are uploaded as artifacts and downloaded by the
Android jobs; neither is committed.

### 7. Config import over plain HTTP

The manifest sets `usesCleartextTraffic="true"`, and
`config_import_export_service.dart:22` also accepts `http://` URLs. A config
(domain and public key) can be swapped in transit.

**Fix:** allow HTTPS only and disable cleartext traffic in the manifest.

## Functional bugs

### Simplified TCP implementation (`TcpConnection.kt`)

- Incoming sequence numbers are not checked. Retransmitted and out-of-order
  segments are forwarded to SOCKS5 as is, causing duplicated and reordered
  data.
- The client's receive window is ignored: `windowSize = 65535` is always sent
  and nothing waits for acknowledgements from the client.
- RST is not handled.
- On FIN the connection is closed entirely; half-closed connections are not
  supported.

On a weak link this can produce broken connections.

**Fix:** replace the hand-written TCP with a ready-made tun2socks, for example
`hev-socks5-tunnel` or a Go tun2socks implementation built into the AAR.

### All UDP except port 53 is dropped

QUIC, WebRTC, games and calls do not work in VPN mode: browsers fall back to
TCP, everything else just breaks. ICMP is dropped too.

### Slipstream on Android exists only for arm64

CI builds APKs for armeabi-v7a and x86_64, but `jniLibs` contains only
`arm64-v8a`. Slipstream will not start on those builds.

**Resolved.** No generated Slipstream binary is committed.
`scripts/build_slipstream_android.sh` builds it from the pinned
`vendor/slipstream-rust` source for all three ABIs in CI
(`build-slipstream-android.yml`); the Kotlin-test, APK and release jobs consume
the same-run `slipstream-android-jni` artifact, and
`scripts/check_slipstream_apks.sh` checks that each split APK contains exactly
its matching `lib/<abi>/libslipstream_client.so`. A runtime smoke test starts
the packaged executable and accepts a local TCP connection on x86_64 and on
`armeabi-v7a` (on an x86_64 runtime with ARM translation, the accepted
ARMv7-capable environment). Evidence:
[03-apk-packaging](roadmap/release-2.3.0/02-slipstream-abi/03-apk-packaging/plan.md)
and
[04-android-subprocess-smoke](roadmap/release-2.3.0/02-slipstream-abi/04-android-subprocess-smoke/plan.md).

### The DNSTT mobile library supports only plain UDP/53

The original `dnstt-client` (`go_src/dnstt-client`) has DoH and DoT with uTLS,
but the mobile wrapper (`go_src/mobile/mobile.go`) works over plain UDP only.
That traffic is easy to detect and block.

### Go version mismatch

`go.mod` specifies `go 1.24.0`, while CI (`.github/workflows/release.yml`)
installs Go 1.21. The build currently works only thanks to automatic toolchain
download (`GOTOOLCHAIN=auto`).

## Code quality and infrastructure

- **There are effectively no tests.** `test/widget_test.dart` is the untouched
  counter template and will fail.
- **CI runs only on tags.** There are no pull request checks: no
  `flutter analyze`, no `go test ./...`, even though `go_src/dns` and
  `go_src/noise` have tests.
- **Duplication:** the `"8.8.8.8"` default is repeated more than 15 times in
  `MainActivity.kt` and the services.
- **Verbose logging:** the destination of every connection and every DNS query
  is logged. For a censorship circumvention tool this is better disabled in
  release builds.
- **Documentation:** CLAUDE.md and README point to upstream rather than the
  fork.

## Suggested order of work

1. Block IPv6 leaks and route DNS through the tunnel (items 1–2).
2. Remove the unauthenticated "share proxy" mode (item 3); a password-protected
   version can return as a separate stage.
3. Create a dedicated signing key and rebuild the AAR and `.so` in CI
   (items 5–6); add Slipstream builds for all ABIs.
4. Add pull request CI: `flutter analyze`, `go test ./...`, a fixed widget
   test.
5. Replace the hand-written TCP with a ready-made tun2socks.
6. Add a DoH/DoT transport to the DNSTT mobile library.
