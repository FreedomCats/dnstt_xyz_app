---
kind: task
status: done
detailed: true
---

# Point the SSH VPN mode at the port `SshTunnelClient` binds

## Task

Fix the pre-existing SSH VPN defect found during the acceptance of stage 03:
`MainActivity.startVpnServiceForSsh` starts `DnsttVpnService` with
`EXTRA_PROXY_PORT = 7000` (`MainActivity.kt:876`), while `SshTunnelClient`
binds its SOCKS5 listener on 1080 (`SshTunnelClient.kt:35`, `:128`). In SSH
mode `DnsttVpnService` starts no tunnel of its own and hands `proxyPort` to
`Tun2Socks.start` (`DnsttVpnService.kt:489-525`, `:555`), so tun2socks is
pointed at a port where nothing listens and SSH VPN mode cannot carry traffic.

Use one public constant as the only source of truth for the port: the class
that binds the listener exposes it, and the activity that starts the VPN
passes the same value. The user placed this fix inside this stage; no separate
stage and no renumbering.

## Steps

1. Expose the port from the class that binds it, `SshTunnelClient.kt`:
   - Replace the comment at line 34 and the private constant at line 35
     (`SOCKS5_PROXY_PORT = 1080`) with a public constant and a KDoc. Kotlin's
     default visibility is public, and the project already declares companion
     constants that way (`DnsttVpnService.EXTRA_PROXY_PORT`,
     `DnsttVpnService.kt:29`): write `const val SOCKS5_PROXY_PORT = 1080` with
     no modifier, do not use `internal` or `@JvmField`.
   - KDoc: this is the local loopback SOCKS5 port the client binds;
     `MainActivity.startVpnServiceForSsh` passes the same value to
     `DnsttVpnService.EXTRA_PROXY_PORT`, so it is the one value for both sides.
     Drop the misleading "same as other modes": the 7000 in the other modes is
     a tunnel port, not this proxy port.
   - Keep the value 1080 and keep `DNSTT_TUNNEL_PORT = 7001` (line 32)
     unchanged. Touch nothing else in the file: the host-key repository,
     `acceptedFingerprint` and the error path added in
     [01-tofu-host-key-repository](../01-tofu-host-key-repository/plan.md)
     stay as they are.

2. Point the SSH VPN intent at that constant, `MainActivity.kt:876`
   (`startVpnServiceForSsh`): `putExtra(DnsttVpnService.EXTRA_PROXY_PORT,
   SshTunnelClient.SOCKS5_PROXY_PORT)`. Leave `EXTRA_PROXY_HOST` (127.0.0.1),
   `EXTRA_DNS_SERVER`, `EXTRA_TUNNEL_DOMAIN`, `EXTRA_PUBLIC_KEY` and
   `EXTRA_SSH_MODE` as they are. Do not touch the non-SSH defaults:
   `MainActivity.kt:105`, `:133`, `:184`, `:451`; `DnsttVpnService.kt:47`,
   `:111`; `DnsttProxyService.kt:46`, `:68`; `SlipstreamProxyService.kt:46`,
   `:70`; `SlipstreamBridge.kt:72`. They belong to the proxy, Slipstream and
   service-default paths.

3. Correct the stale port text on this path (comments and one log line, no
   behavior change). The line numbers are from the tree at planning time; the
   KDoc added in step 1 may shift the later `SshTunnelClient.kt` lines, so
   locate each item by its quoted text:
   - `MainActivity.kt:825`: replace "SOCKS5 on port 7000" with "SOCKS5 on
     `SshTunnelClient.SOCKS5_PROXY_PORT`" (or 1080) — no literal that can go
     stale.
   - `MainActivity.kt:835`: put `${SshTunnelClient.SOCKS5_PROXY_PORT}` into the
     "SSH tunnel connected, SOCKS5 proxy on port ..." message.
   - `SshTunnelClient.kt:20-21` (class KDoc) and `:92-93` (comment before
     `jsch.getSession`): the DNSTT tunnel is 7001, not 7000.
   - `SshTunnelClient.kt:127` (comment before
     `startSocksProxy(SOCKS5_PROXY_PORT)` at `:128`): the SOCKS5 proxy is on
     `SOCKS5_PROXY_PORT`, not 7000.
   - `MainActivity.kt:816-817` already says 7001; leave it.
   - Do not edit `docs/`: `docs/SSH_TUNNEL_ARCHITECTURE.md` and the remaining
     port documentation belong to
     [05-docs-and-review](../05-docs-and-review/plan.md).

4. Add the pin that makes a value change deliberate:
   - Create `android/app/src/test/kotlin/xyz/dnstt/app/SshTunnelPortTest.kt`
     with one JUnit 4 test:
     `assertEquals(1080, SshTunnelClient.SOCKS5_PROXY_PORT)`.
   - Comment there: the constant is the single source of truth for the SSH
     listener and the VPN intent, and 1080 is also the app's default proxy port
     (`lib/services/vpn_service.dart:50`), so changing it is a deliberate act
     that must update this pin.
   - Do not add a test that reads Kotlin source files to look for a literal
     `7000` in `MainActivity`: a source scan is brittle, and the compile-time
     reference from step 2 already keeps the two uses identical.

5. Check the result:
   - `grep -n "7000" android/app/src/main/kotlin/xyz/dnstt/app/MainActivity.kt`
     matches only the four non-SSH defaults (currently lines 105, 133, 184,
     451); the same grep on `SshTunnelClient.kt` returns nothing.
   - `grep -n "SOCKS5_PROXY_PORT"
     android/app/src/main/kotlin/xyz/dnstt/app/SshTunnelClient.kt
     android/app/src/main/kotlin/xyz/dnstt/app/MainActivity.kt` shows the
     declaration, the `startSocksProxy` argument, the log line and the VPN
     extra.
   - `(cd android && ./gradlew :app:testDebugUnitTest)` passes with the new
     test. The prepared `android/app/libs/dnstt.aar` and the `jniLibs`
     executables must be in place; do not rebuild them.
   - `git diff --check` passes; the diff contains only `SshTunnelClient.kt`,
     `MainActivity.kt` and the new test file, and the host-key code from
     [01-tofu-host-key-repository](../01-tofu-host-key-repository/plan.md) is
     untouched.

## Done when

- `SshTunnelClient.SOCKS5_PROXY_PORT` is public and equals 1080; the listener
  binds it and `startVpnServiceForSsh` passes exactly it to
  `DnsttVpnService.EXTRA_PROXY_PORT`, so there is one value for both sides.
- No literal 7000 remains on the SSH VPN path: `SshTunnelClient.kt` has none,
  and `MainActivity.kt` keeps it only in the four non-SSH defaults listed in
  step 2.
- The comments and the connected log line on this path name the DNSTT tunnel
  port as 7001 and the SOCKS5 port as 1080 or as the constant.
- `SshTunnelPortTest` and the full `:app:testDebugUnitTest` task pass,
  including `SshHostKeyRepositoryTest`, `Socks5AuthRelayTest` and
  `Tun2SocksTest`.
- Non-SSH modes and the `DnsttVpnService` default keep 7000 and behave
  unchanged; no Dart, Go, Gradle, workflow or documentation file changes.
- `SshTunnelClient` still binds `127.0.0.1` only (the stage 03 listener
  invariant).

## Risks and what is needed from the user

- SSH proxy mode and SSH VPN mode share the same `SshTunnelClient`; exposing
  the constant and binding one value affects both, which is intended. It does
  not make SSH mode follow the configurable `state.proxyPort`; that
  pre-existing divergence between the Android SSH listener and the proxy-port
  setting stays out of this task.
- `DnsttVpnService` still defaults to 7000 when the extra is absent. Normal VPN
  callers pass the setting and the SSH caller now passes 1080; do not change
  the service default, it belongs to the other modes.
- The DNSTT tunnel port 7001 is also written as a literal in
  `MainActivity.kt:817` next to `SshTunnelClient.DNSTT_TUNNEL_PORT`; unifying
  it is a separate change, left out so the diff stays on the SOCKS5 port.
- The unit test pins the constant; the compile-time reference is what prevents
  the intent and the listener from diverging. No service is started here; the
  SSH VPN data path is checked in
  [06-live-check](../06-live-check/plan.md).
- No user action is needed: no device, network or server is used.

## Outcome

`SshTunnelClient.SOCKS5_PROXY_PORT` is a public `const val` of 1080 with a KDoc
naming both consumers, and `MainActivity.startVpnServiceForSsh` passes it to
`DnsttVpnService.EXTRA_PROXY_PORT`, so the listener and the tun2socks endpoint
cannot diverge through a literal any more. The SSH path's stale text now names
the DNSTT tunnel as 7001 and the SOCKS5 listener by the constant, and the
misleading "same as other modes" comment is gone. `SshTunnelPortTest` pins 1080
and records that the value is also the app's default proxy port. The non-SSH
7000 defaults (`MainActivity` four places, `DnsttVpnService`,
`DnsttProxyService`, `SlipstreamProxyService`, `SlipstreamBridge`) and the
host-key code of [01-tofu-host-key-repository](../01-tofu-host-key-repository/plan.md)
are untouched.

Decisions taken while moving:

- The Step 2 comment and the connected log line in `MainActivity` name the
  constant instead of 1080, so neither can go stale again.
- The KDoc refers to `MainActivity.startVpnServiceForSsh` and
  `DnsttVpnService.EXTRA_PROXY_PORT` as code spans, not KDoc links, to avoid
  depending on symbol resolution for a companion constant.
- No test scans the Kotlin sources for a literal, as the plan requires: the
  compile-time reference is what keeps the two uses identical.

Checks: the focused test and `:app:testDebugUnitTest` pass with 18 tests
(`Socks5AuthRelayTest` 6, `SshHostKeyRepositoryTest` 6, `SshTunnelPortTest` 1,
`Tun2SocksTest` 5); `grep -n "7000"` leaves only the four non-SSH defaults in
`MainActivity.kt` and matches nothing in `SshTunnelClient.kt`; the full Flutter
test suite and `go test ./...` stay green; `git diff --check` is clean.

Noticed while working: the SSH proxy-mode path (not the VPN one) still writes
1080 in its comments and log (`MainActivity.kt:639`, `:669`, `:679`). The
value is right, and switching it to the constant stays out so the diff covers
only the VPN path.

Left by design: the remaining port text in
`docs/SSH_TUNNEL_ARCHITECTURE.md` belongs to
[05-docs-and-review](../05-docs-and-review/plan.md), and the SSH VPN data path
is checked on a real server in [06-live-check](../06-live-check/plan.md). The
SSH listener still does not follow the configurable `state.proxyPort`; that
pre-existing divergence stays out of this task, as the risks above record.
