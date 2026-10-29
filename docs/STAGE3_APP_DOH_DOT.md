# Stage 3: DoH and DoT for DNSTT in the app

Stage 3 of `docs/DOH_DOT_TUN2SOCKS_PLAN.md` (design: sections 3.1, 3.5–3.7).
The Go library has had UDP, DoH and DoT transports since stage 2; this stage
lets the user add DoH and DoT servers and use them for DNSTT connections and
DNS server tests, on Android (VPN, proxy, shared proxy, SSH) and on desktop.
Slipstream keeps plain UDP until stage 4.

## Starting point

- `DnsServer.address` is an IPv4 string; the add dialog
  (`dns_management_screen.dart`), import (`config_import_export_service.dart`,
  `_isValidIp`) and the bundled lists accept nothing else.
- `home_screen.dart` passes `activeDns.address` as `dnsServer` to the
  `VpnService` connect methods; `app_state.dart` passes `DnsServer` objects to
  `DnsttService.testDnsServer` / `testMultipleDnsServersAll`, which pass
  `server.address` on.
- Android: `MainActivity` reads `dnsServer` from the platform channel and hands
  it to `DnsttVpnService`, `DnsttProxyService`, `SlipstreamProxyService` (intent
  extras) or straight to `Mobile.newClient` (SSH proxy, SSH VPN, DNS server
  test). The services call `Mobile.newClient(dnsServer, …)`.
- `DnsttVpnService` puts the resolver into the TUN's DNS settings
  (`addDnsServer(dnsServer)`, fails for a URL) and forwards device DNS queries
  as plain UDP to `dnsServer:53`, one new thread per query.
- Slipstream appends `:53` to the address (`SlipstreamBridge.kt`, twice in
  `slipstream_service.dart`): an `IP:port` or IPv6 entry would break it.
- Desktop: `dnstt_ffi_service.dart` binds `dnstt_create_client`, `dnstt_start`,
  the tests and (lazily) `dnstt_test_dns_server_auth`.
- Not used anywhere (not imported): `connection_screen.dart`,
  `test_screen.dart`, `lib/data/dns_server_lists.dart`. They are left alone;
  new parameters are optional, so they keep compiling.

## Resolver spec in Dart

New `lib/models/resolver_spec.dart`, a port of `client.ParseResolver`:

- `ResolverSpec.tryParse(String)` returns null for invalid input; fields
  `kind` (`ResolverKind.udp`, `doh`, `dot`), `host`, `port`, `path`.
- Same accepted and rejected inputs as `go_src/client/resolver_test.go`; the
  Dart test uses the same table.
- `toString()` is the short canonical form stored in `DnsServer.address`: the
  default port is left out (`192.0.2.1`, `[2001:db8::1]:5353`,
  `https://dns.example/dns-query`, `tls://dns.example`). Go parses it to the
  same resolver, and an old entry like `8.8.8.8` stays as it is.
- `udpAddress`: `host:port` (IPv6 in brackets) for UDP specs, for
  `slipstream-client --resolver`.
- `ResolverSpec.isValidBootstrap(String)`: an IPv4 or IPv6 address, as
  `client.ParseBootstrap`.

## Data and settings

- `DnsServer.bootstrap` (nullable): IP address dialed instead of resolving the
  DoH/DoT host name. JSON gains `bootstrap`; entries without it load as
  before. `DnsServer.kind` comes from the address (`udp` for anything that does
  not parse, so old entries keep working).
- Import (JSON files, URLs, clipboard, dnstt.xyz) accepts every valid spec plus
  an optional `bootstrap`, stores the normalized spec and skips invalid ones;
  export writes `bootstrap` when set. Deduplication compares normalized specs.
- Global setting "TLS fingerprint" (`tls_fingerprint` in storage, settings
  dialog): Auto (empty: the library default `4*Chrome,1*Firefox,1*Safari`),
  Chrome, Firefox, Safari, iOS, Edge, Off (`none`: Go's own TLS). It applies
  to DoH and DoT only.

## Passing the resolver to the native side

- `VpnService` connect methods and the DNS tests take `dnsBootstrap` and
  `tlsFingerprint` next to `dnsServer` (optional, so other callers compile);
  the platform channel carries them as `dnsBootstrap` and `tlsFingerprint`.
- Kotlin: one small class `ResolverOptions(bootstrap, fingerprint)` reads them
  from a `MethodCall`, writes and reads them as intent extras and applies them
  to a `DnsttClient` (`setBootstrap`, `setTLSFingerprint`). Used by
  `DnsttVpnService`, `DnsttProxyService` (also shared mode), both SSH paths and
  `testDnsServer` in `MainActivity`.
- `DnsttVpnService` also gives the client `setSocketProtector` with
  `VpnService.protect`: the app is excluded from the VPN, so this is a second
  guard for the TLS and UDP sockets, not a fix.
- A spec that `Mobile.newClient` rejects ends the connect with that error,
  as an unreachable server does today.

## VPN: device DNS until tun2socks

- The TUN's DNS server becomes a fixed virtual address, `198.18.0.2` (the
  benchmarking range 198.18.0.0/15, never routed on the Internet), instead of
  the resolver: Android rejects a URL there, and a DoH resolver must not get
  plain queries.
- `processUdpPacket` forwards queries to one target chosen at connect time:
  the resolver's UDP address for UDP specs (port from the spec, not a fixed
  53), or a local bridge (`Mobile.startBridge(spec, bootstrap, fingerprint)`,
  `127.0.0.1:<port>`) for DoH and DoT. The bridge stops on disconnect.
- A bounded executor (4 threads, queue of 64, drop when full: DNS clients
  retry) replaces the thread per query.
- SSH VPN mode keeps `8.8.8.8` over UDP, as now.
- Stage 5 (tun2socks) replaces all of this.

## Slipstream until stage 4

- Slipstream gets `udpAddress` instead of `address:53`: Android through
  `Mobile.udpResolverAddr(spec)` in `SlipstreamBridge`, desktop through the
  Dart parser in `slipstream_service.dart`. This fixes ports and IPv6 entries.
- DoH and DoT servers are refused for Slipstream with a clear message
  ("Slipstream supports only plain UDP DNS servers for now"): at connect
  (`home_screen.dart`), in the DNS tests, and as a guard in `SlipstreamBridge`
  and `slipstream_service.dart`.

## Desktop

- `dnstt_ffi_service.dart` binds lazily, like `dnstt_test_dns_server_auth`:
  `dnstt_set_bootstrap`, `dnstt_set_tls_fingerprint` and
  `dnstt_test_dns_server_ex`. `createClient` and `testDnsServer` take bootstrap
  and fingerprint; with an old library they fail with "library too old for
  DoH/DoT" when a DoH/DoT spec or a bootstrap is given, and work as before for
  plain UDP.
- The desktop library itself needs no change: the release workflow builds it
  from `go_src`.

## DNS server tests

- With a DNSTT config, the tunnel test (client, then an HTTP request through
  it) runs over the server's transport: spec, bootstrap and fingerprint are
  passed through as for a connection.
- Without a config the app sends one plain DNS query over UDP. For DoH/DoT
  servers that probe does not apply; they report "Select a config to test
  DoH/DoT servers". (`Mobile.probeResolver` needs the tunnel domain, which only
  a config has, and the full tunnel test is the better check then.)
- Slipstream configs: DoH/DoT servers fail with the Slipstream message above.

## UI

- Add dialog: "Address" accepts IP, `IP:port`, `[IPv6]:port`, host names,
  `udp://`, `https://` and `tls://`; an optional "Bootstrap IP" field, checked
  when given. The error names the accepted forms.
- Server rows: a `DoH`/`DoT` badge, long addresses end with an ellipsis.
- Settings dialog: the TLS fingerprint selector.
- Bundled list: new group "Encrypted (DoH/DoT)" (`assets/dns/encrypted.json`)
  with Google, Cloudflare, Quad9, AdGuard (unfiltered) and Mullvad, DoH and DoT
  each, with their well-known bootstrap IPs.

## Steps

1. `resolver_spec.dart` and its test (the Go table).
2. `DnsServer.bootstrap`, `kind`; storage of the TLS fingerprint; `AppState`.
3. Import/export and bundled list loading; `encrypted.json`; tests for JSON
   compatibility and mixed imports.
4. UI: add dialog, badges, settings selector.
5. `VpnService` and `DnsttService` parameters; `home_screen.dart` and
   `app_state.dart` pass the server's bootstrap and the fingerprint; Slipstream
   refusal.
6. Kotlin: `ResolverOptions`, the DNSTT call sites, `SlipstreamBridge`
   address, VPN DNS target, bridge and executor.
7. Desktop FFI and `slipstream_service.dart`.
8. Checks: `flutter analyze` (no new issues), `flutter test` for the new and
   relay tests, Kotlin unit tests, debug APK build, `go test ./...` (Go is
   unchanged).
9. Docs: `CLAUDE.md` (config format, DNS servers), `docs/STATUS.md`; commit,
   push, CI green.

## Done when

- A DoH and a DoT server can be added, imported, selected and tested; DNSTT
  connects over them in VPN and proxy mode on Android and in proxy mode on
  desktop (live check by the user: this stage cannot be checked against a
  real tunnel server from the session).
- Plain UDP servers behave as before; stored lists load unchanged.
- Slipstream refuses DoH/DoT servers with a clear message and accepts
  `IP:port` and IPv6 UDP servers.

## Not in this stage

- Slipstream over DoH/DoT through the bridge (stage 4).
- tun2socks, IPv6 in the TUN, DNS through the tunnel (stages 5 and 6).
- Auto DNS (system resolver detection) stays IPv4 and UDP.

## Result

- Done as planned. The only Go change is a fix for a flaky probe timeout
  found in CI (`client/probe.go`). `ResolverSpec` accepts a subset of
  what the Go parser accepts (it rejects a few exotic forms Go takes, such as
  `[192.0.2.1]` or a DoH path with spaces); every short form it stores was
  checked against `client.ParseResolver`.
- Android: the `ResolverOptions` class carries bootstrap and fingerprint from
  the platform channel to the services and clients. In VPN mode the TUN
  announces `198.18.0.2`; device DNS goes through a bounded executor to the
  resolver's UDP address or, for DoH/DoT, to a bridge started with the VPN.
- Desktop: `createClient` and `testDnsServer` use the new exports when the
  library has them; an old library still works for UDP servers and reports
  "library too old" for DoH/DoT.
- Tests: `test/resolver_spec_test.dart` (the Go table plus a few cases),
  `test/dns_server_import_test.dart` (JSON compatibility, mixed imports,
  export round trip); the relay tests and Kotlin unit tests pass; the debug
  APK builds; `flutter analyze` shows no new issues besides `avoid_print`
  infos like the rest of `lib/services/`.
- Not checked live: DNSTT over DoH/DoT on a device and on desktop, VPN-mode
  DNS through the bridge, Slipstream with `IP:port` servers.
