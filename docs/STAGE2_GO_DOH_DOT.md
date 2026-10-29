# Stage 2: DoH and DoT in the Go library

Stage 2 of `docs/DOH_DOT_TUN2SOCKS_PLAN.md` (design: sections 3.1–3.4). The
Go library gets UDP, DoH and DoT transports behind one resolver spec string,
plus a UDP→DoH/DoT bridge and a resolver probe. The app does not use any of it
yet (stage 3); its existing calls keep working unchanged.

## Starting point

- `go_src/dnstt-client` (`package main`) has the DoH (`HTTPPacketConn`), DoT
  (`TLSPacketConn`), uTLS and weighted-list code; nothing can import it.
- `go_src/mobile/mobile.go` has its own copy of the DNS encoder and the
  KCP/Noise/smux setup, and opens only a `udp4` socket.
- Shutdown leaks: the encoder's send loop, the DoH senders and the DoT loops
  never end after `Close` (they range over queues that are never closed). The
  CLI exits with the process; the app creates and stops clients all the time
  (every DNS server test is a client).
- DoT closes the whole conn after one failed redial; a network switch on a
  phone ends the tunnel.
- `refraction-networking/utls` is 1.6.6 (`Chrome_120` is the newest Chrome
  fingerprint). 1.8.2 is current and has `Chrome_133`.

## Package layout

New package `go_src/client` (`www.bamsoftware.com/git/dnstt.git/client`):

| File | Contents |
|------|----------|
| `dnspacketconn.go` | DNSTT encoder from `dnstt-client/dns.go`; stops when closed |
| `http.go` | `HTTPPacketConn` (DoH); senders stop when closed |
| `tls.go` | `TLSPacketConn` (DoT); redial with backoff, liveness check |
| `utls.go`, `weightedlist.go` | uTLS dialer and round tripper with an injectable dialer; fingerprint table for utls 1.8 |
| `resolver.go` | `ParseResolver`, `Resolver`, `Options`, `Open` |
| `dialer.go` | TCP/UDP dialing with the socket protect hook and the bootstrap address |
| `tunnel.go` | `NewTunnel`: KCP, Noise and smux over a transport (shared by the CLI and `mobile`) |
| `probe.go` | `Probe`: one DNSTT-shaped query through the transport |
| `bridge.go` | `Bridge`: local UDP socket forwarding DNS messages to a resolver |

`dnstt-client/main.go` becomes a thin CLI over the package; its flags stay
(`-doh`, `-dot`, `-udp`, `-utls`, `-pubkey`, `-pubkey-file`), plus
`-bootstrap`.

## Resolver spec

| Input | Kind | Address |
|-------|------|---------|
| `192.0.2.1`, `192.0.2.1:5353` | udp | port 53 by default |
| `2001:db8::1`, `[2001:db8::1]:5353` | udp | |
| `dns.example` (host name without scheme) | udp | resolved when opened |
| `udp://host[:port]` | udp | |
| `https://host[:port][/path][?query]` | doh | port 443; empty path becomes `/dns-query` |
| `tls://host[:port]` | dot | port 853 |

Rejected: other schemes, user info, fragments, a path on `udp://` or `tls://`,
ports outside 1–65535, IPv6 zones, malformed host names, empty input. Schemes
are case-insensitive. `Resolver.String()` gives the canonical spec.

`Options`:

- `Bootstrap`: IP address dialed instead of resolving the resolver's host
  name. TLS SNI, certificate check and HTTP `Host` keep the name.
- `TLSFingerprint`: weighted list as in dnstt (`3*Chrome,1*Firefox`), a single
  label, or `none` (Go's own TLS). Empty means `DefaultTLSFingerprint`,
  sampled once per `Open`.
- `Protect func(fd int) bool`: called on every socket before connect (Android
  `VpnService.protect`).
- `RootCAs`: trusted roots, nil for the system roots (tests set it).

`DefaultTLSFingerprint` moves to current browsers: common fingerprints only,
no randomized ones (a unique ClientHello is itself a signal). The CLI default
stays dnstt's distribution where its labels still exist.

## Transport behaviour

- **Shutdown.** `turbotunnel.QueuePacketConn` gets `Closed() <-chan struct{}`;
  every loop selects on it. Closing a tunnel closes smux, KCP, the encoder and
  the transport, and all goroutines end (checked by a test).
- **DoT.** The first dial stays synchronous (errors reach the caller). Later
  the conn redials with backoff (0.5 s doubling to 15 s, reset after a
  successful dial) until closed. A connection counts as dead and is redialed
  when a message was sent and nothing has been received for 20 s (a network
  switch leaves a TCP connection that accepts writes and never answers;
  DNSTT polls at least every 10 s, and the server answers within about 1 s).
- **DoH.** HTTP/2 health checks (ping after 10 s without frames, 5 s timeout)
  for the same reason; request timeout 20 s instead of 1 min.
- **UDP.** IPv4 resolvers keep today's `udp4` socket on `0.0.0.0`; IPv6
  resolvers get a `udp6` socket.

## gomobile and desktop API

`mobile` (Android AAR; `desktop` wraps it):

```go
func NewClient(resolver, tunnelDomain, pubKeyHex, listenAddr string) (*DnsttClient, error) // resolver = spec, checked here
func (c *DnsttClient) SetBootstrap(addr string)
func (c *DnsttClient) SetTLSFingerprint(spec string)
func (c *DnsttClient) SetSocketProtector(p SocketProtector) // interface { Protect(fd int) bool }
func ResolverKind(spec string) string   // "udp", "doh", "dot", "" if invalid
func UdpResolverAddr(spec string) string // "host:port" for UDP specs, "" otherwise
func StartBridge(spec, bootstrap, fingerprint string) (*Bridge, error) // Bridge.Port(), Bridge.Stop()
func ProbeResolver(spec, bootstrap, fingerprint, tunnelDomain string, timeoutMs int) (int, error)
```

The old `SetProtectSocket(func)` is replaced: gomobile skipped it, so Java
never had it. The existing Java API stays as it is.

`desktop` C exports: `dnstt_set_bootstrap`, `dnstt_set_tls_fingerprint` (on
the created client, before `dnstt_start`), `dnstt_resolver_kind` (string to
free with `dnstt_free_string`), `dnstt_bridge_start` (returns the port or -1),
`dnstt_bridge_stop(port)`, `dnstt_probe_resolver` (latency or -1, message in
`dnstt_get_last_error`), and `dnstt_test_dns_server_ex` (the tunnel test with
bootstrap, fingerprint and optional SOCKS5 credentials).

`ProbeResolver` sends a poll with a random client ID under the tunnel domain
and returns the time to the answer. NOERROR is success (as in the app's UDP
probe); other RCODEs are errors naming the RCODE. The DNSTT server holds a lone
poll for up to 1 s, so the latency includes that wait, as in the UDP probe the
app has now.

## Bridge

- Listens on `127.0.0.1:0` (UDP); each datagram is one DNS message, sent
  through `Open(spec)` without DNSTT encoding.
- Answers are matched by DNS ID and question (name lowercased, type, class);
  entries expire after 15 s. The ID is forwarded unchanged.
- Malformed datagrams are dropped. A full queue drops messages (DNS clients
  retry).

## Steps

1. `turbotunnel`: `Closed()`.
2. Create `go_src/client` from `dnstt-client` (encoder, DoH, DoT, uTLS,
   weighted list) and move its tests; add `tunnel.go`; `dnstt-client` uses the
   package.
3. `resolver.go`, `dialer.go`: spec parser, `Options`, `Open`, bootstrap,
   protect hook.
4. Clean shutdown of all loops; DoT redial and liveness; DoH timeouts and
   HTTP/2 pings.
5. Update utls to 1.8.2 (`golang.org/x/net` 0.49 already has what is
   needed); fingerprint table and default.
6. `probe.go`, `bridge.go`.
7. `mobile.go` on `client.Open` / `client.NewTunnel`, new functions;
   `desktop.go` exports.
8. Tests:
   - `ParseResolver` table;
   - DoH and DoT against local TLS servers (Go TLS and uTLS fingerprints,
     HTTP/2), DoT redial after the server drops the connection, shutdown
     without leaked goroutines;
   - bridge: two senders, answers out of order, expiry;
   - end to end in `dnstt-server` (it is `package main`, so the test lives
     there and calls its `run`): server on loopback UDP, DoH and DoT fronts
     with a test certificate, a tunnel over UDP, DoH, DoT and DoH with
     bootstrap, data echoed through a stream; `mobile.NewClient` over UDP;
     `Probe` success and NXDOMAIN.
9. `go vet` on the changed packages, `go test ./...`, `scripts/build_aar.sh`
   (gomobile with the new dependencies), the AAR's Java API compared with the
   stage 1 AAR (only additions), Kotlin unit tests and the debug APK.
10. Docs: `CLAUDE.md` (Go library section), `docs/STATUS.md`; commit, push,
    CI green.

## Done when

- `go test ./...` passes, including the end-to-end test over UDP, DoH and DoT.
- The AAR builds in CI; its Java API has only additions.
- The app behaves as before (it still passes plain IPv4 addresses).

## Not in this stage

- Anything in Dart, Kotlin or the desktop Dart code (stage 3).
- Live tests with public resolvers: they come with the app support in stage 3.

## Result

- Done as planned. `go_src/client` holds the transports and the tunnel;
  `mobile`, `desktop` and the CLI are thin layers on it. `dnstt-client` keeps
  its flags and upstream default fingerprint distribution; `-bootstrap` is new.
- Tests (`go test ./...`, also with `-race`): the spec table, every transport
  with Go TLS and several uTLS fingerprints (HTTP/2 included) and with a
  bootstrap address, the protect hook, DoT redial and liveness, no goroutines
  left after `Close`, the bridge with reordered answers and two clients, and
  end to end against `dnstt-server`: tunnels over UDP, DoH and DoT with data
  echoed through two streams, a wrong server key, `Probe` (NOERROR,
  NXDOMAIN, timeout), `mobile.NewClient` start/stop/restart, the bridge.
- The AAR's Java API: the stage 1 API plus `probeResolver`, `resolverKind`,
  `startBridge`, `udpResolverAddr`, `setBootstrap`, `setTLSFingerprint`,
  `setSocketProtector`, and the classes `Bridge` and `SocketProtector`.
  Kotlin unit tests pass and the debug APK builds with it.
- Size: `libgojni.so` grows by about 3.5 MB per ABI (to about 8.8 MB on
  arm64), the AAR from 5.5 to 11 MB. The old library had no HTTP or TLS
  client; `net/http`, HTTP/2 and uTLS (with its certificate compression
  libraries) are the cost of DoH/DoT with fingerprint camouflage.
- Not checked live: the app does not use the new transports until stage 3.
