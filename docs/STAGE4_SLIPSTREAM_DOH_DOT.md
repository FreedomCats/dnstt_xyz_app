# Stage 4: DoH and DoT for Slipstream

Stage 4 of `docs/DOH_DOT_TUN2SOCKS_PLAN.md` (design: section 3.4). Since
stage 3, DNSTT works over DoH and DoT servers; Slipstream refuses them because
`slipstream-client` sends only plain UDP. This stage puts the local
UDP→DoH/DoT bridge from stage 2 (`client.Bridge`, `Mobile.startBridge`,
`dnstt_bridge_start`) between `slipstream-client` and an encrypted resolver,
on Android (VPN, proxy, DNS tests) and on desktop.

```
slipstream-client --resolver 127.0.0.1:<port>
        │ UDP DNS queries
        ▼
Bridge (Go, in the app process)  ──DoH/DoT──►  resolver ──►  tunnel server
```

## Starting point

- Android: `SlipstreamBridge.startClient` takes `Mobile.udpResolverAddr(spec)`
  and fails with "Slipstream supports only plain UDP DNS servers for now"
  when it is empty. Callers: `DnsttVpnService.startSlipstreamClient`,
  `SlipstreamProxyService`, `MainActivity.testSlipstreamDnsServer`. The
  Slipstream platform channel calls (`connectSlipstream`,
  `connectSlipstreamProxy`, `testSlipstreamDnsServer`) and intents carry no
  `ResolverOptions`; `DnsttVpnService` already reads them from every intent.
- In VPN mode `DnsttVpnService.startDnsForwarding` already starts a bridge for
  device DNS when the resolver is DoH/DoT, before the tunnel client starts.
- Desktop: `SlipstreamService.resolverArg` returns null for DoH/DoT;
  `startClient` and `testServer` refuse them. `dnstt_ffi_service.dart` does
  not bind `dnstt_bridge_start` / `dnstt_bridge_stop` yet.
- Dart refusals: `VpnService.connectSlipstream` and `connectSlipstreamProxy`,
  `DnsttService.testDnsServer` (Slipstream branch); the message is
  `SlipstreamService.udpOnlyMessage`.

## How slipstream-client uses its resolver

Read in `vendor/slipstream-rust` (`crates/slipstream-client/src/dns/`):

- `--resolver host:port` is resolved once; each resolver is a QUIC path.
- Answers are assigned to a resolver by their source address, so the bridge
  must answer from the address the client sends to. It does: one socket on
  `127.0.0.1:<port>` receives queries and sends answers.
- In recursive mode (the one the app uses; `--authoritative` is not used) the
  client ignores the DNS ID of answers. IDs are a counter starting at 1. Query
  names carry a QUIC packet each and do not repeat.

So the bridge needs no change for Slipstream. One gap from the design
(section 3.4) is closed anyway: when a resolver answers with a different DNS
ID, the bridge drops the answer today (its key is ID + question). It now falls
back to matching by question alone and restores the original ID. This matters
for device DNS in VPN mode, where clients do check the ID.

## Android

- `SlipstreamBridge.startClient` takes `ResolverOptions` (default empty).
  UDP specs: `Mobile.udpResolverAddr` as now. DoH/DoT specs: start
  `Mobile.startBridge(spec, bootstrap, fingerprint)` and pass
  `127.0.0.1:<port>`; `stopClient` stops the bridge after the subprocess, and
  a failed start stops it too. An invalid spec fails with "Invalid DNS server".
- VPN mode shares one bridge: when `DnsttVpnService` already runs a bridge for
  device DNS, it passes that bridge's address (`127.0.0.1:<port>`, a plain UDP
  spec) to `SlipstreamBridge` instead of starting a second one. One TLS
  connection to the resolver instead of two.
- `MainActivity`: `connectSlipstream`, `connectSlipstreamProxy` and
  `testSlipstreamDnsServer` read `ResolverOptions.from(call)`; the VPN intent
  (also after the permission prompt) and the `SlipstreamProxyService` intent
  carry it; the test passes it to `startClient`.
- `SlipstreamProxyService` reads `ResolverOptions.from(intent)`.

## Desktop

- `dnstt_ffi_service.dart` binds `dnstt_bridge_start` and `dnstt_bridge_stop`
  lazily (old libraries still load); `startBridge(spec, bootstrap,
  fingerprint)` returns the port or null (error in `getLastError`),
  `stopBridge(port)`.
- `SlipstreamService.startClient` and `testServer` take `dnsBootstrap` and
  `tlsFingerprint`. For DoH/DoT they load the library, start a bridge and pass
  `127.0.0.1:<port>`; the bridge stops with the subprocess (`stopClient`, the
  exit handler, the end of `testServer`). Without a library that has the
  bridge, the error is "dnstt library too old for DoH/DoT servers".
- `VpnService` passes `dnsBootstrap` and `tlsFingerprint` to the Slipstream
  connect methods; `home_screen.dart` and the DNS tests pass the server's
  bootstrap and the global fingerprint.

## Removed

- The DoH/DoT refusals in `VpnService`, `DnsttService`, `SlipstreamService`
  and `SlipstreamBridge`, and `SlipstreamService.udpOnlyMessage`.

## Checks

- Go: a bridge test with a resolver that rewrites DNS IDs (answers reach the
  client with the original ID); `go test ./...`.
- Local end-to-end run in the session, without a real server: build
  `slipstream-client` and `slipstream-server` from `vendor/slipstream-rust`,
  run the server on loopback, put the test DoH and DoT servers
  (`internal/testresolver`) in front of it, and fetch data through
  `slipstream-client` → bridge → DoH/DoT → server. Compare with plain UDP. This
  checks the bridge with the real client, not rate limits or real resolvers.
- Dart: tests for the resolver choice of `SlipstreamService`; the existing
  tests; `flutter analyze` without new issues; Kotlin unit tests; debug APK.

## Steps

1. Go: ID fallback in `client.Bridge`, test; rebuild the AAR.
2. Local end-to-end run (script kept in `docs/runs/`, not in git).
3. Kotlin: `SlipstreamBridge`, `DnsttVpnService`, `SlipstreamProxyService`,
   `MainActivity`.
4. Dart: FFI bridge, `SlipstreamService`, `VpnService`, `DnsttService`,
   `home_screen.dart`; remove the refusals.
5. Checks above; docs (`CLAUDE.md`, `docs/STATUS.md`); commit, push, CI green.

## Done when

- A Slipstream config connects over a DoH and a DoT server in VPN and proxy
  mode on Android and on desktop, and DNS server tests work for them (live
  check by the user).
- UDP servers behave as before.

## Not in this stage

- Live measurement against real public resolvers (throughput, HTTP 429 rate
  limits): needs the user's tunnel server; the user checks it later. If the
  bridge turns out to be the bottleneck, native DoH in `slipstream-rust` is a
  separate task.
- Several resolvers per Slipstream connection.

## Result

- Done as planned. The Go bridge restores DNS IDs a resolver changed; the
  Slipstream paths on Android and desktop use it for DoH/DoT, and the
  refusals are gone.
- Found on the way: desktop `slipstream-client` was started without
  `--tcp-listen-host` and listened on all interfaces (an open proxy for the
  local network). It now listens on `127.0.0.1`, like DNSTT on desktop.
- `TestSlipstreamOverBridge` (opt-in) passes: 4 MB download over UDP, DoH and
  DoT through the real client and server. On loopback the bridge is no
  bottleneck (DoH and DoT were not slower than direct UDP). The desktop Dart
  path was checked the same way with a temporary test against a Linux
  `libdnstt.so`, including the errors for an invalid and an unreachable
  server.
- `slipstream-client` always binds its UDP socket to `[::]` and fails on a
  host without IPv6 sockets; the local runs used a patched copy. Not a concern
  for phones and desktops.
- Not checked live: real resolvers, rate limits, Android devices.
