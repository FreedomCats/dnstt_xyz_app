# Stage 5: tun2socks in VPN mode

Stage 5 of `docs/DOH_DOT_TUN2SOCKS_PLAN.md` (design: section 4). The Android VPN
mode replaces its hand-written IPv4/TCP stack with hev-socks5-tunnel, a small C
tun2socks engine with a fake-IP DNS. This closes review items 1 (IPv6 leak,
device DNS outside the tunnel) and "Simplified TCP implementation" of
`docs/CODE_REVIEW.md`.

```
Apps ──► TUN 198.18.0.1/32 + fc00::1/128, routes 0.0.0.0/0 and ::/0, MTU 8500
            │
            ▼
   hev-socks5-tunnel (native thread in the app process, reads the TUN fd)
     • UDP to 198.18.0.2:53 → mapdns: A → fake IPv4 from 198.18.128.0/17,
       every other type → empty answer
     • TCP → SOCKS5 CONNECT; fake IP → domain name, real IP → IP (v4 or v6)
     • other UDP → SOCKS5 UDP ASSOCIATE (fails on servers without it)
            │
            ▼
   127.0.0.1:<proxy port>: tunnel client (DNSTT, Slipstream, SSH), or
                           Socks5AuthRelay in front of it with upstream auth
```

## Starting point

- `DnsttVpnService` (1328 lines) builds a TUN with `10.0.0.2/32`, an IPv4
  default route only, MTU 1500, blocking fd. Its packet loop parses IPv4,
  hands TCP to `TcpConnection` (state machine) and `Socks5Client`
  (SOCKS5 CONNECT by IP), at most three handshakes at a time; UDP port 53 goes
  to the resolver (`startDnsForwarding`: plain UDP, or the DoH/DoT bridge);
  everything else is dropped. IPv6 is not routed into the TUN, so IPv6 traffic
  bypasses the VPN, and device DNS goes to the resolver outside the tunnel.
- In VPN mode Slipstream shares the device-DNS bridge for a DoH/DoT resolver.
- `TcpConnection.kt` and `Socks5Client.kt` are used only by the VPN service.

## Engine: hev-socks5-tunnel

- Submodule `vendor/hev-socks5-tunnel`, tag `2.19.3` (the first release line
  with `mapdns`; 2.9.x has none). Its own submodules (`src/core`,
  `third-part/hev-task-system`, `lwip`, `yaml`) are needed:
  `git submodule update --init --recursive vendor/hev-socks5-tunnel`.
- Licenses: hev-socks5-tunnel, hev-socks5-core, hev-task-system and yaml are
  MIT, lwIP is BSD-3-Clause: distribution with the app is allowed (AGENTS.md).
  `third-part/wintun` (Windows driver DLLs under the WireGuard prebuilt binary
  license) is part of the upstream tree but is neither built nor shipped for
  Android.
- JNI (`src/hev-jni.c`): `JNI_OnLoad` registers `TProxyStartService(String
  configPath, int fd)`, `TProxyStopService()` and `TProxyGetStats()` (tx
  packets, tx bytes, rx packets, rx bytes) on the class `PKGNAME/CLSNAME`.
  Start runs the engine in a new thread and returns at once; a second start
  without a stop is ignored, even after the engine thread ended on a bad
  config. Stop asks the engine to quit and joins the thread. One instance per
  process.
- mapdns (`src/hev-mapped-dns.c`): only queries to the configured address and
  port (IPv4), `A`/`IN` questions get a fake address (TTL 1 s) from the
  configured network, LRU of `cache-size` names; other questions get a
  NOERROR answer without records. A TCP connection to a fake address becomes
  a SOCKS5 CONNECT by name.

## Build

- `android/app/build.gradle.kts`: `externalNativeBuild { ndkBuild { path =
  vendor/hev-socks5-tunnel/Android.mk } }`, only the `hev-socks5-tunnel`
  target (the module also defines an executable), `cFlags` with
  `-DPKGNAME=xyz/dnstt/app -DCLSNAME=TProxyService -O3` and
  `-ffile-prefix-map=<repo>=.` so that no checkout path ends up in the `.so`.
  The library is linked with 16 KB pages (upstream `LDFLAGS`). ABIs come from
  Flutter (`--split-per-abi`, `--target-platform`).
- The Flutter Gradle plugin sets `externalNativeBuild.cmake` to an empty
  project so that AGP installs the NDK ("forceNdkDownload"); AGP refuses two
  native builds ("More than one externalNativeBuild path specified"), so the
  app clears the cmake path. The ndkBuild needs the NDK anyway.
- `preBuild` stops with "run git submodule update --init --recursive
  vendor/hev-socks5-tunnel" if the submodule is missing, like the AAR check.
- `android/app/proguard-rules.pro` keeps `xyz.dnstt.app.TProxyService` (the
  Flutter Gradle plugin adds this file to R8 for release builds):
  `JNI_OnLoad` looks the class up by name, so R8 must not rename it.
- CI (`ci.yml`, `release.yml`): the Android jobs fetch the submodule
  recursively; the Kotlin test job too (Gradle configuration needs the
  `Android.mk`). The NDK is installed with `sdkmanager` before the APK build.
  The existing path check on the APKs covers `libhev-socks5-tunnel.so`.
- About 0.3 MB per ABI.

## Android

- `TProxyService.kt`: `object` with the three `external` functions
  (`@JvmStatic`), loads `libhev-socks5-tunnel.so`.
- `Tun2Socks.kt`:
  - `config(socksPort, …)`: the YAML text (pure function, unit-tested):
    `tunnel` (MTU 8500, `198.18.0.1`, `fc00::1`), `socks5` (`127.0.0.1`,
    port, `udp: 'udp'`, no pipelining: microsocks drops pipelined bytes),
    `mapdns` (`198.18.0.2:53`, network `198.18.128.0/17`, cache 10000),
    `misc` (connect timeout 30 s: a CONNECT crosses the DNS tunnel; log level
    `warn` to a file in `cacheDir`). Offloads off: TSO/USO need a vnet header
    the VPN fd does not have, and "jumbo" (on by default: TCP segments larger
    than the MTU into the TUN) gains nothing at DNS tunnel speeds.
  - `start(context, fd, socksPort)`: writes the config to `cacheDir`, stops
    a previous engine, starts it; `stop()` stops it and copies the last log
    lines and the traffic counters to logcat. Both synchronized.
- `DnsttVpnService`:
  - `Builder`: `198.18.0.1/32`, `fc00::1/128`, routes `0.0.0.0/0` and
    `::/0`, DNS `198.18.0.2`, MTU 8500, non-blocking fd (the default). The
    app itself stays excluded (`addDisallowedApplication`).
  - Order on connect stays: establish the TUN, start the tunnel client, verify
    the tunnel, then start the engine on the fd (instead of the packet loop).
  - Disconnect and revoke: stop the engine before closing the fd, then the
    tunnel client.
  - Slipstream gets the DNS server spec and `ResolverOptions`, so
    `SlipstreamBridge` starts its own bridge for DoH/DoT again (device DNS no
    longer needs one).
  - The engine always connects to `127.0.0.1:<proxy port>`.
- Removed: the packet loop, `processTcpPacket`/`processUdpPacket`, DNS
  forwarding and its bridge, the SYN pool and handshake semaphore,
  `IPv4Header`/`TCPHeader`/`UDPHeader`/`calculateChecksum`,
  `TcpConnection.kt`, `Socks5Client.kt`.
- Unchanged: tunnel clients, `Socks5AuthRelay` (the engine talks to it without
  auth), SSH mode, proxy services, DNS tests.

## Behaviour changes in VPN mode

- IPv6: routed into the TUN; IPv6 literal connections go through the tunnel
  as CONNECT to the IPv6 address. Empty `AAAA` answers keep named connections
  on IPv4 (fake IP).
- DNS: no device DNS query leaves the phone; names are resolved by the
  server side of the tunnel. Apps that need real addresses or `SRV`, `TXT`,
  `MX` records break (stage 6). Queries sent to other DNS servers than
  `198.18.0.2` (apps with a hard-coded resolver) become UDP flows like any
  other.
- UDP besides DNS: each flow tries SOCKS5 UDP ASSOCIATE through the tunnel;
  most upstream proxies (microsocks, for example) refuse it, and the app
  falls back (QUIC → TCP). Each try costs a stream through the tunnel; if live
  tests show load from it, a local front answering UDP ASSOCIATE at once comes
  with stage 6.
- No limit of three concurrent handshakes; the engine has
  `max-session-count` (unlimited by default). Watch for SYN storms in live
  tests.
- Android Private DNS in automatic mode fails against `198.18.0.2` and falls
  back to plain DNS; strict mode with a host name sends DoT over TCP through
  the tunnel.

## Tests

- Kotlin unit test of the config text (`Tun2SocksTest`).
- In the session (not CI): hev built for Linux from the submodule, run on a
  TUN in a network namespace with the text of `Tun2Socks.config` (plus the
  interface name Linux needs) against a local SOCKS5 server: name resolution
  through mapdns (fake A, empty AAAA), HTTP by name and by IPv4/IPv6 literal,
  CONNECT arrives with the domain name.
- hev opens its sockets to the SOCKS5 server as `AF_INET6` with IPv4-mapped
  addresses. Phones have IPv6 sockets; a container without IPv6 needs a test
  shim (`LD_PRELOAD`) that turns them into `AF_INET`. The IPv6 literal case
  cannot run there.
- Debug APK builds; release APK in CI with the path check.
- Live (needs the user's server): browsing, downloads, a messenger, IPv6 and
  DNS leak tests, SSH mode, Slipstream and DNSTT, with and without upstream
  auth, DoH/DoT resolvers.

## Documentation

`CLAUDE.md` (structure, key components, build of the engine) and
`docs/STATUS.md` (closed review items are recorded there, as in earlier stages).
