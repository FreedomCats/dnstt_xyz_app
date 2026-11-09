# DoH/DoT transport, tun2socks and the VPN data path: architecture

This is the architecture behind the app's encrypted resolver transports
(DNS over HTTPS, RFC 8484, and DNS over TLS, RFC 7858) and behind the tun2socks
engine of the Android VPN mode. It covers three review items of
`docs/CODE_REVIEW.md` (IPv6 leak, device DNS outside the tunnel, the simplified
TCP stack) and two features:

- **DoH/DoT**: carry the tunnel's DNS traffic over DoH and DoT instead of plain
  UDP/53, for both DNSTT and Slipstream, on Android and desktop.
- **tun2socks**: replace the hand-written IPv4/TCP stack of the Android VPN
  mode with a ready-made tun2socks engine.

The work was done in five stages; the plan and the result of each one are in
`docs/STAGE1_GO_LIBRARY_CI.md` … `docs/STAGE5_TUN2SOCKS.md`. What is left to
do, in which order, is in `docs/roadmap/release-2.3.0/plan.md`.

## 1. Context: how the app was before

### Tunnel transport

- `go_src/dnstt-client` (upstream dnstt CLI) already had DoH
  (`http.go`, `HTTPPacketConn`), DoT (`tls.go`, `TLSPacketConn`) and uTLS
  camouflage of the TLS fingerprint (`utls.go`, with HTTP/2 support). It was
  `package main`, so none of it could be imported.
- `go_src/mobile/mobile.go` (used by Android through gomobile and by desktop
  through `go_src/desktop/desktop.go`) carried its own copy of the DNS packet
  encoder (`dnsPacketConn`) and opened a plain `udp4` socket to `<ip>:53`.
  There was no way to choose a transport.
- `slipstream-client` (Rust, `vendor/slipstream-rust`, Apache-2.0) speaks plain
  UDP only. It accepts several `--resolver IP:PORT` values and treats each one
  as a separate path.
- `android/app/libs/dnstt.aar` and `libdnstt.*` were prebuilt from upstream:
  any Go change required rebuilding them by hand, and CI did not do that.

### Resolver addresses in the app

- `DnsServer.address` (`lib/models/dns_server.dart`) was an IPv4 string, passed
  unchanged as `dnsServer` through the platform channel to Kotlin, Go and
  `slipstream-client` (`--resolver $dnsServer:53`).
- IPv4-only validation in several places: the add-server dialog, import, system
  DNS detection and the UDP probe in `dnstt_service.dart`.

### Android VPN mode (`DnsttVpnService.kt`)

- TUN: `addAddress("10.0.0.2", 32)`, `addRoute("0.0.0.0", 0)`,
  `addDnsServer(dnsServer)`; the app excluded itself, so its own sockets
  bypassed the VPN.
- IPv4 only: IPv6 was not routed into the TUN and leaked past the tunnel.
- TCP: a hand-written state machine (`TcpConnection.kt`) plus a SOCKS5 client
  (`Socks5Client.kt`) per connection, SYNs handled in a 16-thread pool with at
  most 3 concurrent handshakes. No sequence checks, no receive window, no half
  close.
- UDP: everything except port 53 was dropped. Each device DNS query started a
  new thread and went as plain UDP to the tunnel resolver, outside the tunnel.
- The same service serves DNSTT, Slipstream and SSH-over-DNSTT; the tunnel
  client always ends in a local SOCKS5 port (directly, or through
  `Socks5AuthRelay` when upstream auth is configured).

## 2. Decision and order of the work

DoH/DoT came first, with one small interim change in the VPN DNS path, then
tun2socks. Reasons:

1. **The two features hardly touch each other.** DoH/DoT lives in the Go
   library under the KCP/Noise layers (a different `net.PacketConn`) and in
   `slipstream-client`'s resolver argument. tun2socks lives in the VPN service
   above the local SOCKS5 port. Neither needs the other's code.
2. **DoH/DoT helps every mode**, proxy mode and desktop included. tun2socks
   helps only the Android VPN mode.
3. **DoH/DoT is smaller and lower risk.** Most of the transport code already
   existed in `go_src/dnstt-client` and had run in upstream dnstt for years.
   tun2socks brought a new native library, a JNI bridge and changes to how all
   VPN traffic and DNS work.
4. **The one coupling is cheap to bridge.** With a DoH/DoT resolver, the VPN's
   device DNS can no longer go to `<resolver>:53`, and sending it there in
   plain UDP would undo the point of DoH. Stage 3 sent device DNS through a
   local UDP→DoH/DoT bridge, which stage 5 replaced with the tun2socks DNS
   handling.

What would have argued for tun2socks first: VPN-mode throughput measurements of
DoH distorted by the hand-written TCP stack. Proxy mode gives clean numbers, so
it did not change the order.

Both features needed the Go library built from source in CI, which came first
and blocked everything else.

## 3. Architecture: DoH/DoT

### 3.1 Resolver spec

One string describes a resolver everywhere (storage, platform channel, FFI,
Go):

| Spec | Transport | Default port |
|------|-----------|--------------|
| `8.8.8.8`, `8.8.8.8:5353`, `[2001:db8::1]:53` | UDP (the old format, stored values stay valid) | 53 |
| `udp://host[:port]` | UDP, explicit | 53 |
| `https://host[:port]/path` | DoH, POST `application/dns-message` | 443 |
| `tls://host[:port]` | DoT, two-byte length prefix | 853 |

Separate optional fields, not part of the spec:

- **bootstrap address** (`DnsServer.bootstrap`, e.g. `8.8.8.8` for
  `https://dns.google/dns-query`): dial this IP and keep the URL host as TLS
  SNI and HTTP `Host`. Avoids a plain DNS lookup of the resolver host (which a
  censor can see or poison) and works where system DNS is broken.
- **TLS fingerprint** (global setting, not per server): a uTLS distribution as
  in dnstt (`Chrome`, `Firefox`, `iOS`, `random`, `none`, or a weighted list).
  The default distribution is `4*Chrome, 1*Firefox, 1*Safari`.

There is one parser in Go (`client.ParseResolver`, `go_src/client/resolver.go`),
exported to Kotlin and desktop, so the native layers never parse specs
themselves. Dart has its own parser (`lib/models/resolver_spec.dart`) for
validation and display only, tested against the same table of cases.

### 3.2 Go: the `client` package

The package `go_src/client/` sits between the upstream CLI and the mobile
bindings:

| File | Contents |
|------|----------|
| `dnspacketconn.go` | DNSTT encoder over any `net.PacketConn` (from `dnstt-client/dns.go`; merges the mobile copy's behaviour: ignore transient write errors) |
| `http.go` | `HTTPPacketConn` (DoH): N senders, `Retry-After` on 429 |
| `tls.go` | `TLSPacketConn` (DoT). Change from upstream: on mobile the connection drops on every network switch, so it redials with backoff while the client runs instead of closing the whole conn after one failed redial |
| `utls.go`, `weightedlist.go` | uTLS dialer and HTTP/1.1+HTTP/2 round tripper; the dialer is a parameter, not `&net.Dialer{}` |
| `resolver.go` | `ParseResolver(spec)`, `Options{Bootstrap, UTLS, Protect}` and `Open(spec, opts) (net.PacketConn, net.Addr, error)` returning the UDP, DoH or DoT conn |
| `dialer.go` | `net.Dialer` with `Control` calling the Android `protect(fd)` callback, and bootstrap IP substitution |
| `bridge.go` | UDP→resolver bridge (section 3.4) |
| `probe.go` | `Probe`: one DNSTT-shaped query through the real transport |
| `tunnel.go` | The KCP/Noise/smux tunnel over a packet conn |

`dnstt-client/main.go` is a thin CLI over the package (the tests moved with the
code), so upstream behaviour stays testable. `mobile.go` no longer has its own
encoder copy and calls `client.Open`. `refraction-networking/utls` was updated
from 1.6.6 to 1.8.2: the fingerprints in 1.6.6 (`Chrome_120`, `Firefox_120`)
are dated, and an outdated fingerprint is itself a signal.

Turbotunnel keeps the KCP session alive across transport reconnects (the
session is keyed by client ID, not by socket), so a DoT/DoH reconnect after a
Wi-Fi↔mobile switch does not drop open streams.

### 3.3 gomobile and FFI API

gomobile can only pass strings, numbers, bools, `[]byte` and errors, so the API
stays flat and backward compatible:

```go
// mobile package (Android AAR, also used by go_src/desktop)
func NewClient(resolver, tunnelDomain, pubKeyHex, listenAddr string) (*DnsttClient, error) // resolver = spec
func (c *DnsttClient) SetBootstrap(addr string)
func (c *DnsttClient) SetTLSFingerprint(spec string)

func ResolverKind(spec string) string             // "udp" | "doh" | "dot" | "" (invalid)
func UdpResolverAddr(spec string) string          // "ip:port" for UDP specs
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

`ProbeResolver` sends one DNSTT-shaped query through the real transport (the
same TLS fingerprint as the tunnel). It replaces the Dart UDP probe for DoH/DoT
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
  (the transports return answers in any order). The ID is forwarded unchanged;
  when a resolver answers with another ID, the bridge restores the original by
  matching the question. Slipstream in recursive mode ignores DNS IDs, so it
  needed no change.
- On Android it runs inside the app process, which is excluded from the VPN;
  the Slipstream subprocess has the same UID and is excluded as well.
- Slipstream's resolver-path model is kept: one bridge per configured resolver,
  each on its own port, if multi-resolver support is added later.
- The bridge is not combined with `--authoritative`: its high QPS would hit the
  public resolver's rate limits. The app does not use that flag.

Patching `slipstream-rust` for native DoH remains an option if the bridge turns
out too slow. A loopback measurement (`TestSlipstreamOverBridge`) found DoH and
DoT no slower than direct UDP; a real resolver has to confirm it.

### 3.5 Android (Kotlin)

- `MainActivity` and the services pass `dnsServer` as a spec, plus
  `dnsBootstrap` and `tlsFingerprint` extras (`ResolverOptions.kt`).
- DNSTT (`DnsttVpnService`, `DnsttProxyService`, SSH mode, DNS tests): the
  spec, bootstrap and fingerprint go to `Mobile.newClient` and the setters.
- Slipstream (`SlipstreamBridge`, `SlipstreamProxyService`, VPN, tests): if
  `Mobile.resolverKind(spec) == "udp"`, `Mobile.udpResolverAddr(spec)` is
  passed to `--resolver` (this also fixed the hard-coded `:53`); otherwise
  `Mobile.startBridge` starts a bridge and `127.0.0.1:<port>` is passed; the
  bridge is stopped with the subprocess.
- DNSTT and the tunnel client's sockets are protected so their traffic does not
  re-enter the VPN.

### 3.6 Desktop

- `dnstt_ffi_service.dart`: passes the spec, bootstrap and fingerprint.
- `slipstream_service.dart`: the same UDP/bridge choice as on Android, the
  bridge coming from `libdnstt` through FFI, run in another isolate. Without a
  new enough `libdnstt`, Slipstream over DoH/DoT reports a clear error.
- Build scripts (`build_macos.sh`, `build_linux.sh`, `build_windows.sh`) build
  `libdnstt` with `-trimpath` from a temp directory, as for the AAR.
- Found on the way: desktop `slipstream-client` was started without
  `--tcp-listen-host` and listened on all interfaces (an open proxy for the
  local network). It now listens on `127.0.0.1`, like DNSTT on desktop.

### 3.7 Flutter

- `DnsServer`: `bootstrap` (nullable) and a `kind` getter derived from the
  address (`udp`/`doh`/`dot`). JSON stays backward compatible (missing field →
  null).
- `lib/models/resolver_spec.dart`: parse, validate and normalize specs; shared
  by the add-server dialog, import and display.
- DNS management screen: the add dialog accepts IP, `IP:port`, `https://…` and
  `tls://…`, with an optional bootstrap IP field for DoH/DoT; each row shows a
  `UDP`/`DoH`/`DoT` badge.
- Bundled list: a group "Encrypted (DoH/DoT)" with well-known public resolvers
  (Google, Cloudflare, Quad9, AdGuard, Mullvad) and their bootstrap IPs.
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

All three licenses allow distribution with the project (AGENTS.md,
third-party code). **Choice: hev-socks5-tunnel**, tag `2.19.3` (the first
release line with `mapdns`; 2.9.x has none). It is small, fast, has an Android
JNI API and a fake-IP DNS that suits slow DNS tunnels. It is a git submodule
`vendor/hev-socks5-tunnel` (recursive: it pulls lwIP, hev-task-system and yaml)
built by Gradle through `externalNativeBuild { ndkBuild }` with
`-DPKGNAME=xyz/dnstt/app -DCLSNAME=TProxyService` and `-ffile-prefix-map` so no
build paths end up in the `.so`.

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
- **Tunnel DNS (optional mode, not built).** Real answers for all types: hev
  sends UDP/53 through SOCKS5 UDP ASSOCIATE to a local gateway (the
  `Socks5AuthRelay` grown into a gateway), which resolves the queries as DNS
  over TCP through the tunnel (CONNECT to a configurable resolver, `1.1.1.1:53`
  by default) with a small cache. Other UDP stays dropped unless the server
  side supports UDP-in-TCP (hev-socks5-server), which could be enabled later.

Android "Private DNS" (DoT from the system) is TCP/853 and goes through the
tunnel like any TCP; in automatic mode it fails against `198.18.0.2` and the
system falls back to plain DNS, which mapdns answers.

### 4.4 What changed in the service

- `DnsttVpnService`: the TUN is built with IPv4 and IPv6 addresses and routes,
  `addDnsServer("198.18.0.2")`, MTU 8500, a non-blocking fd; the YAML config is
  written to `cacheDir`; `TProxyService.TProxyStartService(path, fd)` runs after
  the tunnel verification passes, `TProxyStopService()` on disconnect and
  revoke.
- Removed: `TcpConnection.kt`, `Socks5Client.kt`, the IPv4/TCP/UDP header
  classes and the packet loop in `DnsttVpnService.kt` (roughly 900 lines).
- The 3-handshake limit of the old stack protected the tunnel from SYN storms.
  hev has `connect-timeout` and `max-session-count`; if a storm stalls the
  tunnel in live tests, a concurrency limit for CONNECTs in the relay is the
  next step.
- SOCKS5 handshake pipelining stays off in hev (`pipeline: false`): microsocks
  drops pipelined bytes (see the relay's fallback). With upstream auth, hev
  talks to the relay, which pipelines adaptively.
- Traffic counters in the notification can come from `TProxyGetStats()`
  (optional).

## 5. Architecture: the remaining work

The release roadmap tracks these parts in
`docs/roadmap/release-2.3.0/plan.md`. The CI gate in section 5.3 is implemented
and verified; the other sections describe work still to be built.

### 5.1 Shared LAN access to the proxy: disable it

Review item 3 of `docs/CODE_REVIEW.md`: with sharing enabled the SOCKS5 proxy
listens on `0.0.0.0` without a password. With upstream auth the relay would
lend the upstream account to the whole network.

Three places bind to `0.0.0.0` when `shareProxy` is set:

- `android/app/src/main/kotlin/xyz/dnstt/app/DnsttProxyService.kt:183`
- `android/app/src/main/kotlin/xyz/dnstt/app/SlipstreamProxyService.kt:125`
- `android/app/src/main/kotlin/xyz/dnstt/app/SshTunnelClient.kt:139`

No Dart code calls `connectProxyShared` or `setProxySharing` (the platform
channel methods of `MainActivity.kt:180` and `:191`), so the mode is
unreachable from the UI today: the only way in is a direct channel call. The
decision is to remove the paths rather than to add a password: a shared mode
needs UI, storage and tests to be useful, and until then the exposed code is
only a risk.

- Remove the `EXTRA_SHARE_PROXY` handling and the `0.0.0.0` branch in all three
  services; they always bind `127.0.0.1`.
- Remove the channel methods `setProxySharing` and `connectProxyShared`, and
  `DnsttClient.setShareProxy` / `IsShareProxyEnabled` from `mobile.go` with
  their `ShareProxy` field.
- Record in `CODE_REVIEW.md` that item 3 is closed by removing the feature, and
  in `CLAUDE.md` that proxy mode is local-only.
- If the feature is wanted later, it comes back as a stage of its own: a
  generated password shown on connect, a warning, and `Socks5AuthRelay` in
  front of the tunnel client in every mode. The relay already accepts local
  clients with any credentials and authenticates upstream, so it needs a
  local-credentials mode rather than a new component.

### 5.2 SSH host key verification: trust on first use

Review item 4: `SshTunnelClient.kt:95` sets `StrictHostKeyChecking=no`. For
DNSTT the Noise layer authenticates the server, but the SSH layer is not
protected against impersonation.

JSch supports this without new cryptography: `hostKeyRepository` receives the
key and a `HostKeyRepository` implementation decides. Design:

- On connect, the SSH client asks for the key of `<tunnelDomain>:<port>` and
  compares it with the stored fingerprint — SHA-256 of the public key blob,
  base64, the format of `ssh-keygen -lf` (it is what users can compare).
- Nothing stored: the key is remembered and the connection continues (TOFU).
- Stored and different: the connection fails with a message naming both
  fingerprints and the hint "forget the key in the config if the server
  really changed". No dialog: the SSH session lives in a Kotlin service that
  cannot show UI.
- Storage: a field of the SSH config (`lib/models/dnstt_config.dart`,
  `sshHostKeyFingerprint`) next to `sshUsername`, so it travels with the
  config and import/export carries it. A config without the field accepts the
  first key it sees.
- "Forget host key" in the config editor clears the field.
- Tests: a Kotlin unit test of the repository (accept first, refuse a changed
  key, accept after forgetting) against JSch's key types, not a live server.

### 5.3 CI: analyzer and the full test suite

Review item 3.4 is addressed by the implemented gate. The counter-template test
was replaced by `test/app_smoke_test.dart`, which pumps `DnsttClientApp` and
checks the empty start screen. Both `.github/workflows/ci.yml` and
`release.yml` run plain `flutter test`, discovering the full suite rather than
listing files. The verified suite has 75 tests in four files; discovery also
covers tests added later.

`ci.yml` runs plain `flutter analyze` before Dart tests and requires no findings
under `analysis_options.yaml`. The accepted rule set disables `avoid_print` to
keep intentional service diagnostics and centrally ignores
`deprecated_member_use` to defer API migrations. Other measured findings were
fixed, including all seven `use_build_context_synchronously` sites. Flutter
3.38.7 makes infos and warnings fatal by default; there is no saved count,
finding allowance or weaker fatality flag.

After full `go test ./...`, `ci.yml` discovers packages with `go list ./...`,
removes only the exact import path returned by `go list ./noise` using
`grep -Fvx`, and vets the rest with `xargs -r go vet` under `set -euo pipefail`.
The explicit vet step excludes `go_src/noise` because its upstream tests contain
two `t.Fatal` calls from goroutines, which vet rejects. Full Go tests still
include that package; dynamic vet covers eight of the current nine packages and
future packages automatically. Failed checks prevent the dependent Android APK
job. `release.yml` runs the full Dart suite and Kotlin tests, but has no analyzer
or explicit Go vet step.

The [CI gate verification](roadmap/release-2.3.0/01-ci-gate/06-prove-the-gate/plan.md)
records three isolated expected CI failures and a successful run after the
probes were removed. Probe commits were kept outside `develop`; the final
tested tree equals the reviewed baseline.

### 5.4 Slipstream binary for all ABIs

Review item 3.3 is closed: generated `libslipstream_client.so` files are no
longer committed. `scripts/build_slipstream_android.sh` cross-compiles the
pinned `vendor/slipstream-rust` checkout with cargo-ndk 4.1.2 and NDK
28.2.13676358 for `arm64-v8a`, `armeabi-v7a` and `x86_64`; it remaps checkout
and home paths out of the binaries, verifies their ELF machines and runs
`scripts/check_binary_paths.sh`. Per-target picoquic/OpenSSL caches are reused
only with a matching source, toolchain and native-settings stamp; anything else
fails closed.

`build-slipstream-android.yml` runs that script in CI with an exact cache key
and uploads the `slipstream-android-jni` artifact in the
`<abi>/libslipstream_client.so` layout. The Kotlin-test, APK and release jobs
download the same-run artifact into `android/app/src/main/jniLibs/`, restore
`0755` and check `test -x` before Gradle because ZIP transport drops the mode.
`android/app/build.gradle.kts` requires all three files for a local APK build,
so the script must run first; there is no download fallback.
`scripts/check_slipstream_apks.sh` verifies that each split APK contains exactly
its matching entry. `SlipstreamBridge.kt` resolves the executable under
`applicationInfo.nativeLibraryDir`; an instrumentation smoke test starts it on
x86_64 through the bridge and on the accepted ARMv7-capable runtime (an x86_64
image with ARM translation) directly. The measured APK growth is about 2-3 MB
per ABI, the compressed size of the packaged executable entry in the split
APKs.

## 6. Testing

- **Go unit tests** (`go test ./...` in CI):
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
- **Kotlin:** hev YAML generation, resolver-kind decisions for Slipstream, the
  SSH host key repository.
- **Build checks:** `strings` on the new `.so` files and the AAR shows no
  machine paths (AGENTS.md).
- **Live checks** (by the user, on a device and desktop): DNSTT and Slipstream
  over DoH and DoT with two public resolvers, proxy and VPN modes, throughput
  compared to UDP; network switch Wi-Fi↔mobile with an open download; a packet
  capture on the network side shows only TLS to the resolver, no UDP/53; in VPN
  mode: no IPv6 or DNS leaks (ipleak-style test pages), browsing, a messenger,
  a long download; SSH mode with a changed host key; upstream auth with and
  without pipelining.

## 7. Risks and open questions

- **Rate limits of public DoH resolvers.** DNSTT through Google/Cloudflare DoH
  is the setup dnstt was designed for. Slipstream sends far more queries and may
  get HTTP 429; `HTTPPacketConn` then pauses for `Retry-After`. To measure in
  the live checks.
- **Blocked DoH endpoints.** Well-known resolvers are blocked in some
  countries. Mitigations built in: user-defined endpoints and bootstrap IPs.
  Later options: SNI override / domain fronting, ECH.
- **DNS ID rewriting by DoH resolvers** affects only the bridge; handled by the
  name-matching fallback (section 3.4).
- **Network switches** on mobile: DoT redial and HTTP/2 reconnect are covered
  by the client package; KCP sessions survive. Live check required.
- **AAR size** grows with uTLS and HTTP/2 (about 1.5 MB per ABI, the AAR went
  from 5.5 to 11 MB); hev adds about 0.3 MB per ABI.
- **Fake-IP limits** (section 4.3): the reason for the optional tunnel DNS
  mode.
- **hev is a single global instance** per process; start/stop must be strictly
  sequential across reconnects.
- **SYN storms** through a slow tunnel without the old 3-handshake limit
  (section 4.4); watch in live tests.

## 8. Out of scope

- Per-app VPN (allow/deny lists); the new `Builder` setup makes it easy later.
- UDP for apps (QUIC, calls, games) beyond DNS; needs server-side UDP-in-TCP.
- DoQ / DoH3.
- Several resolvers at once for one tunnel (load balancing, failover).
- Shared LAN access to the proxy (section 5.1).
