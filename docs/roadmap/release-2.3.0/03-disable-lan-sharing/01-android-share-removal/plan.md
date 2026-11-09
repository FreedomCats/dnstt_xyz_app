---
kind: task
status: todo
detailed: true
---

# Remove the sharing branches and channel wrappers from the Android app

## Task

Remove every switch that can move the app's SOCKS5 listener off loopback and
delete the platform-channel surface that exists only for the "share proxy" mode.
This is the app half of closing `docs/CODE_REVIEW.md` item 3: the accepted
decision is to remove the mode, not to add a password
(`docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md`, section 5.1).

The surface is provably unreachable from Dart: `lib/` has no `shareProxy`,
`setProxySharing` or `connectProxyShared` reference, and
`VpnService.connectSshTunnel` sends no `shareProxy` key. The Go library method
`DnsttClient.setShareProxy` is removed separately in
[02-go-share-api-removal](../02-go-share-api-removal/plan.md), so this task only
stops calling it; the prepared AAR still contains the unused method, which is
enough for compilation until that task rebuilds it.

## Steps

1. `android/app/src/main/kotlin/xyz/dnstt/app/DnsttProxyService.kt`: delete
   `EXTRA_SHARE_PROXY` (line 35), the `shareProxy` field (48) and the intent
   read (71). In `startDnsttClient` replace every use of `bindHost` with the
   literal `"127.0.0.1"`: the listen address (183, 188), the `Socks5AuthRelay`
   constructor (210) and its error log (214). Delete the
   `dnsttClient?.setShareProxy(true)` block (194-196). Keep the auth-relay port
   selection unchanged.
2. `android/app/src/main/kotlin/xyz/dnstt/app/SlipstreamProxyService.kt`: delete
   `EXTRA_SHARE_PROXY` (36), the field (51) and the intent read (76). Replace
   `bindHost` (125) with `"127.0.0.1"` at `SlipstreamBridge.startClient` (139),
   at the `Socks5AuthRelay` constructor (145) and in its error log (151); the
   `host` selection at 130 then collapses to the same literal.
3. `android/app/src/main/kotlin/xyz/dnstt/app/SshTunnelClient.kt`: delete
   `shareProxyEnabled` (43), the `shareProxy` parameter and its KDoc (54, 61,
   63), and bind the SOCKS5 server always to
   `InetSocketAddress(InetAddress.getByName("127.0.0.1"), port)` (138-147).
   Drop the sharing flag from the bind log (150).
4. `android/app/src/main/kotlin/xyz/dnstt/app/MainActivity.kt`: delete the
   `isProxySharingEnabled` field (84-85); the `"setProxySharing"` (180-187),
   `"isProxySharingEnabled"` (188-190) and `"connectProxyShared"` (191-197)
   channel cases; the `connectProxyShared` function (458-496);
   `getLocalIpAddresses` (429-456) with its channel case (177-179) — it has no
   caller and exists only to display an address for the removed mode; and the
   then-unused `java.net.NetworkInterface` import (26). Remove the `shareProxy`
   argument from the `"connectSshTunnel"` case (153, 156) and from the
   `connectSshTunnel` signature and body (746, 774, 779). Delete the two
   `putExtra(..., EXTRA_SHARE_PROXY, false)` calls (410, 605) and
   `isProxySharingEnabled.set(false)` (425).
5. Check for leftovers before building:
   `grep -RIn "shareProxy\|SHARE_PROXY\|ShareProxy\|ProxySharing\|getLocalIpAddresses" android/app/src/main/kotlin`
   prints nothing; `grep -RIn '0\.0\.0\.0' android/app/src/main/kotlin` prints
   only the VPN route `addRoute("0.0.0.0", 0)` in `DnsttVpnService.kt` (462).
6. Compile and test with the prepared local inputs:
   `(cd android && ./gradlew :app:testDebugUnitTest)`. The AAR at
   `android/app/libs/dnstt.aar` and the three `jniLibs` executables are in
   place; restore `0755` on them if Gradle reports a missing or
   non-executable Slipstream file. This compiles every changed file; the debug
   APK build and the full suites belong to
   [03-verify-local-only](../03-verify-local-only/plan.md).

## Done when

- The two greps in step 5 show no share identifier and no listener bind outside
  loopback; the only remaining `0.0.0.0` under `android/app/src/main/kotlin` is
  the VPN route.
- The channel no longer handles `setProxySharing`, `isProxySharingEnabled`,
  `connectProxyShared` or `getLocalIpAddresses`; `connectSshTunnel` accepts no
  sharing flag and `SshTunnelClient.connect` has no sharing parameter.
- `:app:testDebugUnitTest` passes (11 Kotlin tests today; the count is
  observed, not fixed). No Dart or Go file changes in this task.

## Risks and what is needed from the user

- `EXTRA_SHARE_PROXY` is a public companion constant; removing it without
  removing the two `putExtra(..., false)` calls in `MainActivity.kt` breaks
  compilation.
- `DnsttVpnService.kt` keeps `EXTRA_PROXY_HOST`, which the channel can set.
  Every Dart caller passes `127.0.0.1` (four call sites), and this task does not
  widen scope to that parameter; [03-verify-local-only](../03-verify-local-only/plan.md)
  records it in the listener inventory so the stage criterion is not silently
  weakened.
- No user action is needed: no network, new SDK package or device is used.
