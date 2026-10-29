# DoH/DoT transport and tun2socks: design and work plan

Design for two features from `docs/CODE_REVIEW.md` and `docs/STATUS.md`
(next steps 3.5 and 3.6):

- **DoH/DoT**: carry the tunnel's DNS traffic over DNS over HTTPS (RFC 8484)
  and DNS over TLS (RFC 7858) instead of plain UDP/53, for both DNSTT and
  Slipstream, on Android and desktop.
- **tun2socks**: replace the hand-written IPv4/TCP stack of the Android VPN
  mode with a ready-made tun2socks engine, closing the IPv6 leak and the device
  DNS leak (review items 1 and 2) on the way.

The document ends with a step-by-step plan (section 6). Each stage is a
separate commit series that leaves the app working.

## 1. Current state

### Tunnel transport

- `go_src/dnstt-client` (upstream dnstt CLI) already has DoH
  (`http.go`, `HTTPPacketConn`), DoT (`tls.go`, `TLSPacketConn`) and uTLS
  camouflage of the TLS fingerprint (`utls.go`, with HTTP/2 support). It is
  `package main`, so none of it can be imported.
- `go_src/mobile/mobile.go` (used by Android through gomobile and by desktop
  through `go_src/desktop/desktop.go`) carries its own copy of the DNS packet
  encoder (`dnsPacketConn`) and opens a plain `udp4` socket to `<ip>:53`. There
  is no way to choose a transport.
- `slipstream-client` (Rust, `vendor/slipstream-rust`, Apache-2.0) speaks plain
  UDP only. It accepts several `--resolver IP:PORT` values and treats each one
  as a separate path.
- `android/app/libs/dnstt.aar` and `libdnstt.*` are prebuilt from upstream. Any
  Go change requires rebuilding them, and CI does not do that yet.

### Resolver addresses in the app

- `DnsServer.address` (`lib/models/dns_server.dart`) is an IPv4 string. It is
  passed unchanged as `dnsServer` through the platform channel to Kotlin, Go and
  `slipstream-client` (`--resolver $dnsServer:53` in `SlipstreamBridge.kt` and
  `slipstream_service.dart`).
- IPv4-only validation in several places: the add-server dialog
  (`dns_management_screen.dart`, regex), import (`config_import_export_service.dart`,
  `_isValidIp`), system DNS detection (`system_dns_service.dart`), the UDP probe
  in `dnstt_service.dart` (`_testDnsServerViaDnsQuery`, `InternetAddress.tryParse`).

### Android VPN mode (`DnsttVpnService.kt`)

- TUN: `addAddress("10.0.0.2", 32)`, `addRoute("0.0.0.0", 0)`,
  `addDnsServer(dnsServer)`; the app excludes itself
  (`addDisallowedApplication`), so its own sockets bypass the VPN.
- IPv4 only; IPv6 is not routed into the TUN and leaks past the tunnel.
- TCP: hand-written state machine (`TcpConnection.kt`) plus a SOCKS5 client
  (`Socks5Client.kt`) per connection, SYNs handled in a 16-thread pool with at
  most 3 concurrent handshakes. No sequence checks, no receive window, no half
  close (review: "Simplified TCP implementation").
- UDP: everything except port 53 is dropped. Each device DNS query starts a new
  thread and goes as plain UDP to the tunnel resolver, outside the tunnel: the
  censor sees every domain.
- The same service serves DNSTT, Slipstream and SSH-over-DNSTT (`isSshMode`);
  the tunnel client always ends in a local SOCKS5 port (directly, or through
  `Socks5AuthRelay` when upstream auth is configured).

## 2. Order of work: DoH/DoT first, tun2socks second

The question was whether tun2socks should come first. Recommendation: no.
DoH/DoT goes first, with one small interim change in the VPN DNS path, then
tun2socks.

Reasons:

1. **The two features hardly touch each other.** DoH/DoT lives in the Go
   library under the KCP/Noise layers (a different `net.PacketConn`) and in
   `slipstream-client`'s resolver argument. tun2socks lives in the VPN service
   above the local SOCKS5 port. Neither needs the other's code.
2. **DoH/DoT helps every mode**, proxy mode and desktop included. tun2socks
   helps only the Android VPN mode.
3. **DoH/DoT is smaller and lower risk.** Most of the transport code already
   exists in `go_src/dnstt-client` and has run in upstream dnstt for years.
   tun2socks brings a new native library, a JNI bridge and changes how all VPN
   traffic and DNS work.
4. **The one coupling is cheap to bridge.** With a DoH/DoT resolver, the VPN's
   device DNS can no longer go to `<resolver>:53`, and sending it there in plain
   UDP would undo the point of DoH. Stage 3 sends device DNS through a local
   UDP→DoH/DoT bridge (needed for Slipstream anyway, section 3.4). That is about
   twenty lines in `processUdpPacket` and is replaced by the tun2socks DNS
   handling later.

What would argue for tun2socks first: VPN-mode throughput measurements of DoH
would be distorted by the hand-written TCP stack. Proxy mode gives clean
numbers, so this does not change the order.

Both features need the Go library to be built from source in CI. That is
stage 1 and blocks everything else. The first release (STATUS "Next steps",
item 0) does not depend on any of this and can go out before.

## 3. Architecture: DoH/DoT

### 3.1 Resolver spec

One string describes a resolver everywhere (storage, platform channel, FFI, Go):

| Spec | Transport | Default port |
|------|-----------|--------------|
| `8.8.8.8`, `8.8.8.8:5353`, `[2001:db8::1]:53` | UDP (today's format, stored values stay valid) | 53 |
| `udp://host[:port]` | UDP, explicit | 53 |
| `https://host[:port]/path` | DoH, POST `application/dns-message` | 443 |
| `tls://host[:port]` | DoT, two-byte length prefix | 853 |

Separate optional fields, not part of the spec:

- **bootstrap address** (`DnsServer.bootstrap`, e.g. `8.8.8.8` for
  `https://dns.google/dns-query`): dial this IP and keep the URL host as TLS SNI
  and HTTP `Host`. Avoids a plain DNS lookup of the resolver host (which a
  censor can see or poison) and works where system DNS is broken.
- **TLS fingerprint** (global setting, not per server): uTLS distribution as in
  dnstt (`Chrome`, `Firefox`, `iOS`, `random`, `none`, or a weighted list).
  Default: dnstt's weighted distribution.

There is one parser in Go (`client.ParseResolver`), exported to Kotlin and
desktop, so the native layers never parse specs themselves. Dart has its own
parser for validation and display only, tested against the same table of cases.

### 3.2 Go: a `client` package

New importable package `go_src/client/` (module
`www.bamsoftware.com/git/dnstt.git/client`), built from the code in
`go_src/dnstt-client`:

| File | Contents |
|------|----------|
| `dnspacketconn.go` | DNSTT encoder over any `net.PacketConn` (from `dnstt-client/dns.go`; merge the mobile copy's behaviour: ignore transient write errors) |
| `http.go` | `HTTPPacketConn` (DoH), unchanged logic: N senders, `Retry-After` on 429 |
| `tls.go` | `TLSPacketConn` (DoT). Change: on mobile the connection drops on every network switch, so redial with backoff while the client runs instead of closing the whole conn after one failed redial |
| `utls.go`, `weightedlist.go` | uTLS dialer and HTTP/1.1+HTTP/2 round tripper; the dialer becomes a parameter instead of `&net.Dialer{}` |
| `resolver.go` | `ParseResolver(spec)`, `Options{Bootstrap, UTLS, Protect}` and `Open(spec, opts) (net.PacketConn, net.Addr, error)` that returns the UDP, DoH or DoT conn |
| `dialer.go` | `net.Dialer` with `Control` calling the Android `protect(fd)` callback, and bootstrap IP substitution |
| `bridge.go` | UDP→resolver bridge (section 3.4) |

`dnstt-client/main.go` becomes a thin CLI over the package (tests move with the
code), so upstream behaviour stays testable. `mobile.go` drops its encoder copy
and calls `client.Open`.

Turbotunnel keeps the KCP session alive across transport reconnects (the
session is keyed by client ID, not by socket), so a DoT/DoH reconnect after a
Wi-Fi↔mobile switch does not drop open streams.

Update `refraction-networking/utls` from 1.6.6 to a current release first: the
fingerprints in 1.6.6 (`Chrome_120`, `Firefox_120`) are dated, and an outdated
fingerprint is itself a signal.

### 3.3 gomobile and FFI API

gomobile can only pass strings, numbers, bools, `[]byte` and errors, so the
API stays flat and backward compatible:

```go
// mobile package (Android AAR, also used by go_src/desktop)
func NewClient(resolver, tunnelDomain, pubKeyHex, listenAddr string) (*DnsttClient, error) // resolver = spec
func (c *DnsttClient) SetBootstrap(addr string)
func (c *DnsttClient) SetTLSFingerprint(spec string)

func ResolverKind(spec string) string             // "udp" | "doh" | "dot" | "" (invalid)
func UdpResolverAddr(spec string) string           // "ip:port" for UDP specs
func StartBridge(spec, bootstrap, fingerprint string) (*Bridge, error)
func (b *Bridge) Port() int
func (b *Bridge) Stop()
func ProbeResolver(spec, bootstrap, fingerprint, tunnelDomain string, timeoutMs int) (int, error) // latency ms
```

Desktop C exports mirror them: `dnstt_create_client` takes the spec, plus
`dnstt_set_bootstrap`, `dnstt_set_tls_fingerprint`, `dnstt_bridge_start`
(returns a port), `dnstt_bridge_stop`, `dnstt_probe_resolver`. As with
`dnstt_test_dns_server_auth`, Dart looks the new symbols up lazily, so an old
library still loads and only DoH/DoT is unavailable.

`ProbeResolver` sends one DNSTT-shaped query through the real transport (same
TLS fingerprint as the tunnel). It replaces the Dart UDP probe for DoH/DoT
servers; a Dart `HttpClient` probe would show a different TLS fingerprint than
the tunnel and could pass where the tunnel is blocked.

### 3.4 UDP→DoH/DoT bridge (Slipstream and device DNS)

`slipstream-client` only sends UDP. Rather than patching the Rust client, the
app runs a local bridge:

```
slipstream-client --resolver 127.0.0.1:<port>
        │ UDP DNS queries
        ▼
Bridge (Go, in the app process)  ──DoH/DoT──►  public resolver ──►  tunnel server
```

- Listens on `127.0.0.1:0` (UDP), reads one DNS message per datagram, sends it
  through `client.Open(spec)` and writes the answer back to the sender.
- Answers are matched to senders by DNS ID plus question name, with an expiry
  (the transports return answers in any order). The ID is forwarded unchanged:
  Slipstream matches polls by ID. If a resolver rewrites IDs (to check: RFC 8484
  only recommends ID 0 for caching), fall back to question-name matching;
  Slipstream query names are unique.
- On Android it runs inside the app process, which is excluded from the VPN;
  the Slipstream subprocess has the same UID and is excluded as well.
- Slipstream's resolver-path model is kept: one bridge per configured resolver,
  each on its own port, if multi-resolver support is added later.
- Do not combine the bridge with `--authoritative`: its high QPS would hit the
  public resolver's rate limits. The app does not use that flag today.

The same bridge serves device DNS in VPN mode until tun2socks lands (stage 3).

Patching `slipstream-rust` for native DoH remains an option if the bridge turns
out too slow (one extra local hop; HTTP/2 multiplexing should hide most of it).

### 3.5 Android (Kotlin)

- `MainActivity` and the services pass `dnsServer` as a spec, plus
  `dnsBootstrap` and `tlsFingerprint` extras.
- DNSTT (`DnsttVpnService`, `DnsttProxyService`, SSH mode, DNS tests): give the
  spec, bootstrap and fingerprint to `Mobile.newClient` and the setters.
- Slipstream (`SlipstreamBridge`, `SlipstreamProxyService`, VPN, tests): if
  `Mobile.resolverKind(spec) == "udp"`, pass `Mobile.udpResolverAddr(spec)` to
  `--resolver` (fixes today's hard-coded `:53`); otherwise start
  `Mobile.startBridge` and pass `127.0.0.1:<port>`; stop it with the
  subprocess.
- VPN interim DNS (removed again in stage 5): `addDnsServer` gets a fixed
  virtual address (`198.18.0.2`, from the benchmarking range 198.18.0.0/15, not
  routed on the Internet) instead of the resolver. `processUdpPacket` sends UDP
  resolvers' queries as today, but for DoH/DoT sends them to the bridge on
  loopback. Replace thread-per-query with a bounded executor.

### 3.6 Desktop

- `dnstt_ffi_service.dart`: pass the spec, bootstrap and fingerprint.
- `slipstream_service.dart`: same UDP/bridge choice as on Android, the bridge
  coming from `libdnstt` through FFI. Without a new enough `libdnstt`,
  Slipstream over DoH/DoT reports a clear error.
- Build scripts (`build_macos.sh`, `build_linux.sh`, `build_windows.sh`) build
  `libdnstt` with `-trimpath` from a temp directory, as for the AAR.

### 3.7 Flutter

- `DnsServer`: add `bootstrap` (nullable) and a `kind` getter derived from the
  address (`udp`/`doh`/`dot`). JSON stays backward compatible (missing field →
  null).
- New `lib/models/resolver_spec.dart`: parse, validate and normalize specs;
  shared by the add-server dialog, import and display.
- DNS management screen: the add dialog accepts IP, `IP:port`, `https://…` and
  `tls://…`, with an optional bootstrap IP field for DoH/DoT; each row shows a
  `UDP`/`DoH`/`DoT` badge.
- Bundled list: a new "Encrypted (DoH/DoT)" group in `assets/dns` with
  well-known public resolvers (Google, Cloudflare, Quad9, AdGuard, Mullvad)
  and their bootstrap IPs.
- Settings: "TLS fingerprint" selector (Auto, Chrome, Firefox, iOS, Off).
- Testing: `testDnsServer` routes DoH/DoT servers to `ProbeResolver` and the
  tunnel test; the UDP probe stays for UDP servers. Auto-DNS selection works
  unchanged on the test results.
- Config import/export: DNS server lists may contain specs; import accepts
  them.

## 4. Architecture: tun2socks

### 4.1 Engine choice

| | hev-socks5-tunnel | xjasonlyu/tun2socks | Own engine on gVisor netstack |
|---|---|---|---|
| License | MIT | MIT | Apache-2.0 (gVisor) + our code |
| Language / build | C, `ndk-build`, JNI | Go, into the AAR | Go, into the AAR |
| Size per ABI | ~0.5 MB | several MB (gVisor) | several MB (gVisor) |
| Memory / CPU on phone | low, no GC | higher (Go GC, gVisor) | higher |
| IPv4/IPv6 | yes | yes | to be written |
| UDP | SOCKS5 UDP ASSOCIATE, UDP-in-TCP | UDP ASSOCIATE | to be written |
| Fake-IP DNS | built in (`mapdns`) | no | to be written |
| SOCKS5 auth, pipelined handshake | yes | auth yes | to be written |
| Android use | widely used, documented JNI API | used, less on Android | — |

All three licenses allow distribution with the project (AGENTS.md, third-party
code). **Choice: hev-socks5-tunnel.** It is small, fast, has an Android JNI API
and a fake-IP DNS that suits slow DNS tunnels (below). It is added as a git
submodule `vendor/hev-socks5-tunnel` (recursive: it pulls lwIP, hev-task-system
and yaml) and built by Gradle through `externalNativeBuild { ndkBuild }` with
`-DPKGNAME=xyz/dnstt/app -DCLSNAME=TProxyService` and `-ffile-prefix-map` so
no build paths end up in the `.so`.

### 4.2 Data path

```
Apps ──► TUN (198.18.0.1/32, fc00::1/128, routes 0.0.0.0/0 and ::/0, MTU 8500)
            │
            ▼
   hev-socks5-tunnel (native thread, reads the TUN fd)
     • DNS to 198.18.0.2:53 → mapdns: A → fake IPv4 from 198.18.128.0/17
     • TCP → SOCKS5 CONNECT; fake IP → domain name (ATYP 3), real IP → IP
     • UDP → SOCKS5 UDP ASSOCIATE (fails cleanly on servers without it)
            │
            ▼
   127.0.0.1:<port>   tunnel client (DNSTT / Slipstream / SSH),
                      or Socks5AuthRelay in front of it when upstream auth is set
            │
            ▼
   DNS tunnel (UDP, DoH or DoT) ──► tunnel server ──► upstream SOCKS5 ──► Internet
```

The engine sits above the SOCKS5 port, so DNSTT, Slipstream and SSH-over-DNSTT
all use it unchanged (the SSH client's SOCKS server already accepts domain
names).

### 4.3 DNS in VPN mode

- **Fake-IP (default).** hev's `mapdns` answers `A` queries with a fake address
  and remembers the name; a TCP connection to that address becomes a SOCKS5
  CONNECT by name, so the server side resolves it. No device DNS leaves the
  phone, and no DNS round trip goes through the slow tunnel before each
  connection. Every other query type (`AAAA`, `HTTPS`, `MX`, `SRV`, `TXT`) gets
  an empty answer. Empty `AAAA` keeps apps on IPv4, which the tunnel always
  carries.
  Limits: apps that need SRV/TXT/MX records or real IPs break (some
  messengers, mail clients); fake addresses are valid only while the VPN runs
  (cache `cache-size`, LRU).
- **Tunnel DNS (stage 6, optional mode).** Real answers for all types: hev
  sends UDP/53 through SOCKS5 UDP ASSOCIATE to a local gateway (the
  `Socks5AuthRelay` grown into a gateway), which resolves the queries as DNS
  over TCP through the tunnel (CONNECT to a configurable resolver, `1.1.1.1:53`
  by default) with a small cache. Other UDP stays dropped unless the server
  side supports UDP-in-TCP (hev-socks5-server), which could be enabled later.

Android "Private DNS" (DoT from the system) is TCP/853 and goes through the
tunnel like any TCP; in automatic mode it fails against `198.18.0.2` and the
system falls back to plain DNS, which mapdns answers.

### 4.4 What changes in the service

- `DnsttVpnService`: new `Builder` setup (IPv4 + IPv6 addresses and routes,
  `addDnsServer("198.18.0.2")`, MTU 8500, non-blocking fd), YAML config written
  to `cacheDir`, `TProxyService.TProxyStartService(path, fd)` after the tunnel
  verification passes, `TProxyStopService()` on disconnect and revoke.
- Removed: `TcpConnection.kt`, `Socks5Client.kt`, the IPv4/TCP/UDP header
  classes and the packet loop in `DnsttVpnService.kt` (roughly 900 lines).
- The 3-handshake limit of the old stack protected the tunnel from SYN storms.
  hev has `connect-timeout` and `max-session-count`; if a storm stalls the
  tunnel in live tests, add a concurrency limit for CONNECTs in the relay.
- SOCKS5 handshake pipelining stays off in hev (`pipeline: false`): microsocks
  drops pipelined bytes (see the relay's fallback). With upstream auth, hev talks
  to the relay, which already pipelines adaptively.
- Traffic counters in the notification can come from `TProxyGetStats()`
  (optional).

## 5. Testing

- **Go unit tests** (`go test ./...` in CI already):
  - `ParseResolver` table (IPv4, IPv6, ports, URLs, invalid input), the same
    table as the Dart tests;
  - DoH/DoT conns against `httptest` TLS servers; TLS redial after the server
    drops the connection;
  - bridge: ID/name matching, concurrent queries, answers out of order;
  - end to end: `dnstt-server` on loopback UDP behind a test DoH and DoT
    front, `mobile.NewClient` over each transport, a stream echoed through the
    tunnel. The test trusts the test certificate through an unexported hook.
- **Dart:** resolver spec parsing, `DnsServer` JSON compatibility (old entries
  without `bootstrap`), import of mixed lists.
- **Kotlin:** hev YAML generation, resolver-kind decisions for Slipstream.
- **Build checks:** `strings` on the new `.so` files and the AAR shows no
  machine paths (AGENTS.md).
- **Live checks** (by the user, on a device and desktop): DNSTT and Slipstream
  over DoH and DoT with two public resolvers, proxy and VPN modes, throughput
  compared to UDP; network switch Wi-Fi↔mobile with an open download; a packet
  capture on the network side shows only TLS to the resolver, no UDP/53; in VPN
  mode after stage 5: no IPv6 or DNS leaks (ipleak-style test pages), browsing,
  a messenger, a long download.

## 6. Step-by-step plan

### Stage 1. Build the Go library in CI (prerequisite)

Detailed plan and result: `docs/STAGE1_GO_LIBRARY_CI.md`.

1. `scripts/build_aar.sh`: copy `go_src` to a temp dir, `gomobile bind
   -trimpath -ldflags="-s -w" -androidapi 21 -target=android`, copy the AAR to
   `android/app/libs/`.
2. CI (`ci.yml`, `release.yml`): install gomobile, run the script before the
   APK build, run the `strings` path check on the `.so` files in the AAR.
3. Remove the prebuilt `dnstt.aar` and `dnstt-sources.jar` from git; document
   the local build in `CLAUDE.md`.
4. Desktop `libdnstt`: the macOS release jobs already build it from source with
   `-trimpath`; add the same `strings` check there.

Done when: CI APKs work with the AAR built from `go_src` at that commit.

### Stage 2. DoH/DoT in the Go library

Detailed plan and result: `docs/STAGE2_GO_DOH_DOT.md`.

1. Create `go_src/client` from `dnstt-client` (encoder, DoH, DoT, uTLS,
   weighted list); `dnstt-client` uses it; move the tests. No behaviour change.
2. `resolver.go` and `dialer.go`: spec parser, bootstrap, protect hook, uTLS
   option.
3. DoT redial with backoff instead of closing.
4. `mobile.go`: use `client.Open`; add `SetBootstrap`, `SetTLSFingerprint`,
   `ResolverKind`, `UdpResolverAddr`, `ProbeResolver`.
5. `bridge.go` and `StartBridge`.
6. `desktop.go`: matching C exports.
7. Update utls; check that gomobile builds all four Android ABIs.
8. Go tests from section 5, including the end-to-end test.

Done when: `go test ./...` passes with the e2e test over UDP, DoH and DoT; the
AAR builds in CI.

### Stage 3. DoH/DoT for DNSTT in the app

1. Dart `ResolverSpec`, `DnsServer.bootstrap`, validation in the add dialog,
   import, display badges; tests.
2. TLS fingerprint setting in storage and settings screen.
3. Platform channel and Kotlin: pass spec, bootstrap and fingerprint to every
   DNSTT path (VPN, proxy, shared proxy, SSH, DNS tests).
4. VPN interim DNS through the bridge; virtual DNS address; bounded executor.
5. Desktop FFI for DNSTT.
6. DNS tests: `ProbeResolver` for DoH/DoT, tunnel test unchanged.
7. Bundled "Encrypted (DoH/DoT)" group.

Done when: a DNSTT config connects over a DoH and a DoT server in proxy and VPN
modes on Android and in proxy mode on desktop; the user checks it live.

### Stage 4. DoH/DoT for Slipstream

1. Android: UDP resolvers as `Mobile.udpResolverAddr` (fix the fixed `:53`);
   bridge for DoH/DoT in `SlipstreamBridge`, `SlipstreamProxyService`, VPN mode
   and `testSlipstreamDnsServer`.
2. Desktop: the same in `slipstream_service.dart` with the FFI bridge.
3. Live measurement: Slipstream over DoH vs UDP; check resolver rate limiting.
   If the bridge is the bottleneck, record it and consider native DoH in
   slipstream-rust as a separate task.

Done when: a Slipstream config connects over DoH and DoT on Android and
desktop.

### Stage 5. tun2socks in VPN mode

1. Submodule `vendor/hev-socks5-tunnel` (pinned release tag), Gradle
   `ndkBuild` for all ABIs, JNI class `xyz.dnstt.app.TProxyService`; CI path
   check on the `.so`.
2. `Tun2Socks.kt`: config generation (unit-tested), start, stop, stats.
3. `DnsttVpnService`: new `Builder` setup with IPv6, start hev after the tunnel
   verification, stop on disconnect/revoke; remove the interim DNS bridge use.
4. Remove `TcpConnection.kt`, `Socks5Client.kt` and the packet code.
5. Live checks: browsing, downloads, a messenger, IPv6 and DNS leak tests,
   SSH mode, Slipstream and DNSTT, with and without upstream auth.

Done when: review items 1 and 2 and "Simplified TCP implementation" are closed
and live checks pass.

### Stage 6. Tunnel DNS mode (optional)

1. Grow `Socks5AuthRelay` into a local gateway: always on in VPN mode, CONNECT
   as today, UDP ASSOCIATE answering UDP/53 by DNS over TCP through the tunnel,
   with a cache; tests against the fake SOCKS5 servers.
2. hev config without `mapdns` in this mode; setting "VPN DNS: Fake-IP / Through
   tunnel".

Done when: SRV/TXT lookups work in VPN mode with the setting on.

### Stage 7. Documentation

At the end of each stage: `CLAUDE.md` (architecture, build of AAR and hev,
config format with resolver specs), `docs/STATUS.md`, `README.md` (DoH/DoT
usage).

## 7. Risks and open questions

- **Rate limits of public DoH resolvers.** DNSTT through Google/Cloudflare DoH
  is the setup dnstt was designed for. Slipstream sends far more queries and may
  get HTTP 429; `HTTPPacketConn` then pauses for `Retry-After`. To measure in
  stage 4.
- **Blocked DoH endpoints.** Well-known resolvers are blocked in some
  countries. Mitigations in this plan: user-defined endpoints and bootstrap IPs.
  Later options: SNI override / domain fronting, ECH.
- **DNS ID rewriting by DoH resolvers** affects only the bridge; handled by the
  name-matching fallback (section 3.4).
- **Network switches** on mobile: DoT redial and HTTP/2 reconnect are covered by
  stage 2; KCP sessions survive. Live check required.
- **AAR size** grows with uTLS and HTTP/2 (about 1–2 MB per ABI); hev adds about
  0.5 MB per ABI.
- **Fake-IP limits** (section 4.3): the reason for stage 6.
- **hev is a single global instance** per process; start/stop must be strictly
  sequential across reconnects.
- **SYN storms** through a slow tunnel without the old 3-handshake limit (section
  4.4); watch in live tests.

## 8. Out of scope

- Per-app VPN (allow/deny lists); the new `Builder` setup makes it easy later.
- UDP for apps (QUIC, calls, games) beyond DNS; needs server-side UDP-in-TCP.
- DoQ / DoH3.
- Several resolvers at once for one tunnel (load balancing, failover).
