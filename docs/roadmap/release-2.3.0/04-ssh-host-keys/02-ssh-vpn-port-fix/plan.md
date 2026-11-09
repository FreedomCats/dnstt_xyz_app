---
kind: task
status: todo
---

# Point the SSH VPN mode at the port `SshTunnelClient` binds

## Task

Fix the pre-existing SSH VPN defect found during the acceptance of stage 03:
`MainActivity.startVpnServiceForSsh` starts `DnsttVpnService` with
`EXTRA_PROXY_PORT = 7000` (`MainActivity.kt:876`), while `SshTunnelClient`
binds its SOCKS5 listener on 1080 (`SshTunnelClient.kt:35`, `:116`). In SSH
mode `DnsttVpnService` starts no tunnel of its own and hands `proxyPort` to
`Tun2Socks.start` (`DnsttVpnService.kt:489-525`, `:555`), so tun2socks is
pointed at a port where nothing listens and SSH VPN mode cannot carry traffic.

Use one public constant as the only source of truth for the port: the class
that binds the listener exposes it, and the activity that starts the VPN
passes the same value. The user placed this fix inside this stage; no separate
stage and no renumbering.

## Steps

1. In `android/app/src/main/kotlin/xyz/dnstt/app/SshTunnelClient.kt`, make the
   companion constant public: `const val SOCKS5_PROXY_PORT = 1080` (currently
   `private` at line 35). Add a KDoc line: this is the local SOCKS5 port the
   class binds, and the SSH VPN intent must pass this value to
   `DnsttVpnService`. Keep the value 1080 and keep `DNSTT_TUNNEL_PORT = 7001`
   unchanged.
2. In `android/app/src/main/kotlin/xyz/dnstt/app/MainActivity.kt`,
   `startVpnServiceForSsh` (lines 872-883): replace the literal 7000 at line 876
   with `SshTunnelClient.SOCKS5_PROXY_PORT`. Leave `EXTRA_PROXY_HOST`,
   `EXTRA_DNS_SERVER`, `EXTRA_TUNNEL_DOMAIN`, `EXTRA_PUBLIC_KEY` and
   `EXTRA_SSH_MODE` as they are.
3. Remove the stale port text on the same path, without changing behavior:
   - `MainActivity.kt:825` says "SOCKS5 on port 7000" and `:835` logs
     "SOCKS5 proxy on port 7000" in `startSshTunnelWithVpn`; both are wrong.
     Put 1080 in the comment; in the log line use
     `SshTunnelClient.SOCKS5_PROXY_PORT` so it cannot drift.
   - The KDoc at the top of `SshTunnelClient.kt` (lines 20-24) and the comment
     before `jsch.getSession` (line 82) say the DNSTT tunnel is on 7000; the
     comment before `startSocksProxy` (line 115) says the SOCKS5 proxy is on
     7000. The code uses 7001 for the DNSTT tunnel (`DNSTT_TUNNEL_PORT`) and
     1080 for the proxy. Correct the comments to 7001 and 1080. If task 01 has
     already shifted the lines, find them by the quoted text.
   - Do not touch the `7000` defaults that belong to other modes:
     `MainActivity.kt:105`, `:133`, `:184`, `:451` and `DnsttVpnService.kt:47`,
     `:111`, nor the DNSTT/proxy services' extras.
4. Create
   `android/app/src/test/kotlin/xyz/dnstt/app/SshTunnelPortTest.kt` with one
   test: `assertEquals(1080, SshTunnelClient.SOCKS5_PROXY_PORT)`. The
   compile-time reference from step 2 is the anti-drift mechanism; this test
   pins the documented value so a future edit of the constant is deliberate.
5. Check the result:
   - `grep -n "SOCKS5_PROXY_PORT" android/app/src/main/kotlin/xyz/dnstt/app/SshTunnelClient.kt android/app/src/main/kotlin/xyz/dnstt/app/MainActivity.kt`
     shows the listener, the log lines and the VPN extra.
   - `grep -n "7000" android/app/src/main/kotlin/xyz/dnstt/app/MainActivity.kt`
     no longer matches the SSH functions at lines 825, 835 and 876; the
     remaining matches are the non-SSH defaults listed in step 3.
   - `(cd android && ./gradlew :app:testDebugUnitTest)` passes with the new
     test; the prepared AAR and jniLibs are in place.

## Done when

- `startVpnServiceForSsh` passes `SshTunnelClient.SOCKS5_PROXY_PORT`, so
  `DnsttVpnService` receives the port its SOCKS5 proxy actually binds (1080).
- The SSH VPN path and the `SshTunnelClient` comments contain no literal 7000;
  the DNSTT tunnel port is documented as 7001 and the SOCKS5 port as 1080.
- The new test passes and `:app:testDebugUnitTest` is green.
- The non-SSH `7000` defaults and every other mode's behavior are unchanged;
  no Dart, Go, Gradle or workflow file changes.
- `SshTunnelClient` still binds `127.0.0.1` only (the stage 03 listener
  invariant).

## Risks and what is needed from the user

- SSH proxy mode and SSH VPN mode share the same `SshTunnelClient`; changing
  the constant affects both, which is intended. The fixed 1080 port is what the
  class binds; this task does not make SSH mode follow the user's configurable
  proxy-port setting.
- `DnsttVpnService` still defaults to 7000 when the extra is absent. Normal VPN
  callers pass the setting and the SSH caller now passes 1080; do not change
  the service default, it belongs to the other modes.
- The unit test proves the constant, not a running service. The observable
  SSH VPN data path is checked in [06-live-check](../06-live-check/plan.md);
  no device is needed here.
