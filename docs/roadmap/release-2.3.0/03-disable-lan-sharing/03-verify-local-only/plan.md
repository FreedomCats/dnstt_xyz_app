---
kind: task
status: done
detailed: true
depends: [01-android-share-removal, 02-go-share-api-removal]
---

# Verify that the app has a loopback-only SOCKS5 listener

## Task

Prove the stage's "Done when" on the integrated tree: no share path remains in
`android/`, `go_src/` or `lib/`, every SOCKS5 listener binds `127.0.0.1`, the
Go, Flutter and Kotlin suites pass, and a debug APK builds. This is a
verification task and changes no source. The edits are
[01-android-share-removal](../01-android-share-removal/plan.md) and
[02-go-share-api-removal](../02-go-share-api-removal/plan.md); documentation
and review closure are in [04-docs-and-review](../04-docs-and-review/plan.md).

The source grep over `android/`, `go_src/` and `lib/` must find none of
`shareProxy`, `SHARE_PROXY`, `ShareProxy`, `ProxySharing`,
`connectProxyShared`, `setProxySharing`, `getLocalIpAddresses`,
`GetLocalIPAddresses` or `isPrivateIP`. Every remaining `0.0.0.0` match must be
classified as a non-listener: the expected ones are the VPN route in
`DnsttVpnService.kt` and the outbound UDP source address in
`go_src/client/dialer.go`; `go_src/dnstt-server` and its man page are the
server binary, and `vendor/` is outside the stage's scope.

The listener inventory names every construction and the host its caller passes:
`DnsttProxyService`, `SlipstreamProxyService`, `SshTunnelClient`,
`Socks5AuthRelay`, `DnsttVpnService` (`EXTRA_PROXY_HOST`; all four Dart callers
pass `127.0.0.1`), `SlipstreamBridge.startClient` (`--tcp-listen-host`),
`Mobile.newClient` (`listenAddr`) and desktop `dnstt_create_client` (Dart
default `127.0.0.1:1080`). Any non-loopback caller is a finding, not a pass.

Wildcard binds that are not spelled `0.0.0.0` belong to the same inventory:
`ServerSocket(port)` in the two `isPortInUse` helpers and
`RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)` in the DNS-query test
fallback. Each gets a verdict in the report; none of them is a SOCKS5 listener,
but the classification must be written down rather than inferred from the empty
literal grep.

The APK must be built with the AAR rebuilt from the changed Go sources:
`javap` on `android/app/libs/dnstt.aar` must show neither `setShareProxy` nor
`isShareProxyEnabled`, otherwise run `./scripts/build_aar.sh` first.

## Steps

1. **Freeze the starting state.** From the repository root, run
   `git status --short` and `git rev-parse --short HEAD`; record both in the
   report. The expected tree is 02's commit (`0c91c79`) or a later one that
   still carries the rebuilt AAR and the three `jniLibs` executables. No source,
   test or workflow file may be modified before the first check; if one is,
   report it instead of verifying around it. This task edits no repository file,
   not even this plan.

2. **Share-identifier grep.** From the root:

   ```
   git grep -In -e 'shareProxy' -e 'SHARE_PROXY' -e 'ShareProxy' \
     -e 'ProxySharing' -e 'connectProxyShared' -e 'setProxySharing' \
     -e 'getLocalIpAddresses' -e 'GetLocalIPAddresses' -e 'isPrivateIP' \
     -- android go_src lib
   ```

   Expected: no output and exit status 1. `git grep` is used instead of
   `grep -R` because it sees only tracked source: build directories and the
   ignored AAR cannot produce false positives, and the AAR is covered by step 5.
   Step 1 rules out untracked source, so the tracked set is the whole source.
   Any match is a leftover of 01/02: stop and report it with `file:line`, do not
   edit code in this task.

3. **Wildcard grep.** Three commands, each result classified in the report:

   ```
   git grep -In '0\.0\.0\.0' -- android go_src lib
   git grep -In '0\.0\.0\.0' -- go_src/man
   git grep -InE 'ServerSocket\(|\.bind\(|RawDatagramSocket\.bind|InternetAddress\.any|net\.Listen|ListenUDP|ListenTCP|ListenPacket' -- android go_src lib
   ```

   The first is expected to print exactly three lines, all non-listeners:
   - `android/app/src/main/kotlin/xyz/dnstt/app/DnsttVpnService.kt:462` —
     `.addRoute("0.0.0.0", 0)`, the VPN route;
   - `go_src/client/dialer.go:57` — a comment about the IPv4 resolver socket;
   - `go_src/client/dialer.go:64` — `"udp4", "0.0.0.0:0"`, the local address of
     the outbound resolver UDP socket (`ListenPacket` at line 69), not a
     listener.

   The second is expected to print only `go_src/man/dnstt-server.1:169`
   (`0.0.0.0:53` in the server usage example). The third lists every bind site;
   its expected rows are the Kotlin and Dart relay binds, `SshTunnelClient`,
   the two `isPortInUse` `ServerSocket(port)` calls, the `RawDatagramSocket.bind`
   in `lib/`, `mobile.go:167`, `bridge.go:66`, `dialer.go:69`, the
   `dnstt-client` and `dnstt-server` binaries. Test sources appear there too
   (Go and Kotlin tests bind loopback); they are classified as tests. Two
   further matches are text, not bind sites: `go_src/TODO:23` and the
   `mobile.go:43`/`:235` declarations that mention `net.Listener`. Anything
   extra is classified as well.

4. **Build the listener inventory** in the report: one row per construction with
   `file:line`, the bind expression, who supplies the host, and a verdict
   (SOCKS5 listener on loopback / non-listener wildcard probe / outbound socket /
   CLI or server / out of scope). Check the call sites, not the literals alone:
   a. `Socks5AuthRelay.start()` — `Socks5AuthRelay.kt:106-108` binds
      `bindHost:bindPort`. Constructor callers:
      `git grep -n 'Socks5AuthRelay(' -- android/app/src/main` prints the class
      declaration at `Socks5AuthRelay.kt:33` as well; skip it. The use sites are
      `DnsttProxyService.kt:201`, `SlipstreamProxyService.kt:139`,
      `DnsttVpnService.kt:89`, `MainActivity.kt:977`. Every first argument is
      `127.0.0.1` except `DnsttVpnService`'s `proxyHost`, which is checked in
      (b). `findFreePort()` at `Socks5AuthRelay.kt:65` binds loopback. On
      desktop the production caller `lib/services/vpn_service.dart:66-73`
      passes `bindHost: '127.0.0.1'`; `findFreePort()` is loopback too
      (`socks5_auth_relay.dart:85-86`).
   b. `EXTRA_PROXY_HOST` chain: `git grep -n 'EXTRA_PROXY_HOST' -- android` →
      declaration `DnsttVpnService.kt:28`, read `:110`, producers
      `MainActivity.kt:324`, `:450`, `:875`. Line 324 gets `proxyHost` from the
      `connect` channel (`MainActivity.kt:104`, default `"127.0.0.1"`), and
      every Dart caller passes it explicitly: `git grep -n "proxyHost:" -- lib`
      → `test_screen.dart:340`, `connection_screen.dart:375`,
      `home_screen.dart:953`, `vpn_service.dart:1036`, all `'127.0.0.1'`.
      Lines 450 and 875 are literals. `DnsttVpnService` is
      `android:exported="false"`
      (`android/app/src/main/AndroidManifest.xml:38-49`), so another app cannot
      start it with a different extra. Verdict: loopback.
   c. `Mobile.newClient` / `dnstt_create_client`:
      `git grep -n 'Mobile.newClient(' -- android` → `DnsttProxyService.kt:187`
      (literal `127.0.0.1:$port`), `DnsttVpnService.kt:162` (host from (b)),
      `MainActivity.kt:661`, `:818` (literal `127.0.0.1:7001`), `:1072`
      (literal `127.0.0.1:$port`). The Go side passes the address unchanged to
      `net.Listen("tcp", c.listenAddr)` (`go_src/mobile/mobile.go:167`). The
      desktop C export `dnstt_create_client` takes the caller's `listenAddr`
      (`go_src/desktop/desktop.go:40-56`); Dart `createClient` callers are
      `vpn_service.dart:431-437` (`127.0.0.1:$tunnelPort`) and `:851-857`
      (`127.0.0.1:7001`), with the default `127.0.0.1:1080`
      (`dnstt_ffi_service.dart:216-222`).
   d. `SlipstreamBridge.startClient`: `git grep -n 'startClient(' -- android`
      also prints the declaration at `SlipstreamBridge.kt:66`; the use sites are
      `DnsttVpnService.kt:367` (host from (b)), `SlipstreamProxyService.kt:127`
      (`127.0.0.1`), `MainActivity.kt:569` (`127.0.0.1`), and the
      instrumentation test with `LOOPBACK` (not shipped). The Kotlin argument
      becomes `--tcp-listen-host` (`SlipstreamBridge.kt:99`, signature default
      at :73). Dart launch sites:
      `git grep -n -- '--tcp-listen-host' -- lib` → `slipstream_service.dart:163`
      and `:283`, both `127.0.0.1`. There is no launch site without the flag.
   e. `SshTunnelClient.startSocksProxy()` — `SshTunnelClient.kt:133-139` binds
      `127.0.0.1:1080` with a literal and a constant; the DNSTT endpoint is
      `127.0.0.1:7001` (`:31-35`).
   f. `isPortInUse` — `DnsttProxyService.kt:236-244` and
      `DnsttVpnService.kt:419-427` call `ServerSocket(port)`: a wildcard bind,
      closed at once, no `accept()`. It is a port-availability probe, not a
      SOCKS5 listener; pre-existing and unchanged by 01 (`## Outcome`).
   g. `RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)` —
      `lib/services/dnstt_service.dart:520`, the DNS-query test fallback: an
      ephemeral outbound UDP socket that sends one query to the configured
      resolver and reads one reply. Not TCP, not a SOCKS listener, not on the
      proxy path; still a wildcard bind and must be written down with that
      verdict.
   h. Out of the app: `go_src/dnstt-server` (`main.go:905` and the man-page
      example), `go_src/dnstt-client` (`main.go:121`, `LOCALADDR` positional at
      :227), `vendor/slipstream-rust` (the binary defaults to all interfaces
      only when the flag is omitted; every app launch passes it; `vendor/` is
      outside the stage's scope). `Tun2Socks.kt:42-68` points the engine at
      `127.0.0.1` as a client, not a listener.

   Any shipped SOCKS5 construction whose host is not `127.0.0.1`/loopback is a
   defect of 01/02: stop, report `НЕ УКЛАДЫВАЕТСЯ В ЗАДАЧУ` with the file:line
   and the full call chain; do not widen the scope or patch code here.

5. **AAR guard.** The APK must not pass on the prepared library:

   ```
   tmp=$(mktemp -d)
   unzip -q android/app/libs/dnstt.aar -d "$tmp"
   javap -classpath "$tmp/classes.jar" mobile.DnsttClient mobile.Mobile > "$tmp/javap.txt"
   grep -nE 'setShareProxy|isShareProxyEnabled|getLocalIPAddresses' "$tmp/javap.txt"
   grep -nE 'newClient|startBridge|probeResolver|connectWithTunFd|setBootstrap|setTLSFingerprint|setTunFd|setSocketProtector' "$tmp/javap.txt"
   rm -rf "$tmp"
   ```

   Expected: the first `grep` prints nothing; the second prints the sanity
   methods (`newClient`, `startBridge`, `probeResolver`, `connectWithTunFd`,
   `setBootstrap`, `setTLSFingerprint`, `setTunFd`, `setSocketProtector`). The
   AAR at planning time already satisfies this. If the first grep matches, run
   `./scripts/build_aar.sh` and repeat step 5; if its prerequisites (Go
   toolchain, `javac`, SDK/NDK) are missing, stop and report a blocker — never
   build the APK on the old AAR.

6. **Go checks.** From `go_src`, run the CI commands plus a build:

   ```
   go build ./...
   go test ./...
   noise_package=$(go list ./noise)
   go list ./... | grep -Fvx "$noise_package" | xargs -r go vet
   ```

   Expected: all pass, no vet output; `noise` stays excluded as in `ci.yml`.
   The tests bind loopback only and need no server or network. A failure caused
   by 01/02 is their defect: record it, do not fix code here.

7. **Flutter checks.** From the root:

   ```
   flutter pub get
   flutter analyze
   flutter test
   ```

   Expected: `flutter analyze` prints `No issues found!`; `flutter test` ends
   with all tests passing and 0 failures (the count is observed, not fixed).
   `pub get` may rewrite `linux/flutter/generated_plugins.cmake` and/or
   `windows/flutter/generated_plugins.cmake`; afterwards restore only those
   paths with `git checkout --` and leave every other change alone. Do not
   commit generated files or edit tests.

8. **Kotlin tests.**

   ```
   chmod 0755 android/app/src/main/jniLibs/arm64-v8a/libslipstream_client.so \
     android/app/src/main/jniLibs/armeabi-v7a/libslipstream_client.so \
     android/app/src/main/jniLibs/x86_64/libslipstream_client.so
   (cd android && ./gradlew :app:testDebugUnitTest)
   ```

   Expected: `BUILD SUCCESSFUL`, 11 tests (6 `Socks5AuthRelayTest`, 5
   `Tun2SocksTest`), 0 failures; the count is observed, not fixed. Gradle
   compiles against the AAR checked in step 5.

9. **Debug APK.**

   ```
   flutter build apk --debug --target-platform android-arm64
   ```

   Expected: the build succeeds and prints the path of
   `build/app/outputs/flutter-apk/app-debug.apk`; the file exists. The build
   uses the rebuilt AAR and the prepared `jniLibs` (restore `0755` on the three
   `.so` files if Gradle complains). No release build, no signing, no device.

10. **Final tree check and report.**

    ```
    git status --short
    git diff --stat
    git check-ignore -q android/app/libs/dnstt.aar && echo aar-ignored
    git check-ignore -q build/app/outputs/flutter-apk/app-debug.apk && echo apk-ignored
    ```

    Expected: no tracked source, test, Gradle, CI or release file changed by
    this task; outside the map only this plan file (if the lead has not
    committed it yet); the AAR and the APK are ignored. Restore the incidental
    generated-plugin rewrites from step 7. The report carries: HEAD, each
    command with its exit status, the test counts, the inventory table with
    verdicts, and the classifications of the three wildcard kinds. If a real
    share path was found, the report starts with `НЕ УКЛАДЫВАЕТСЯ В ЗАДАЧУ`,
    names the file:line and the call chain, and says what 01/02 must fix.

## Done when

- Step 2 prints nothing. Step 3's first two greps print exactly the three
  expected source lines and the man-page line, each classified as a
  non-listener, and every bind site from the third grep has a row in the
  inventory.
- The inventory covers every construction of `Socks5AuthRelay`,
  `Mobile.newClient`/`dnstt_create_client`,
  `SlipstreamBridge.startClient`/`--tcp-listen-host`,
  `SshTunnelClient.startSocksProxy` and the auxiliary wildcard binds, with the
  host expression, its supplier and a verdict; every shipped caller supplies
  `127.0.0.1`/loopback. `EXTRA_PROXY_HOST` is recorded as reachable only from
  `MainActivity` (channel default `"127.0.0.1"`, four Dart callers pass
  `'127.0.0.1'`, the other two producers are literals) on a service with
  `android:exported="false"`. `isPortInUse` is recorded as a temporary wildcard
  `ServerSocket` with no `accept()`, `dialer.go:64` as an outbound UDP source
  address, and `dnstt_service.dart:520` as an outbound UDP DNS-test socket —
  none of them a SOCKS5 listener.
- `javap` on the unpacked AAR lists `newClient`, `startBridge`,
  `probeResolver`, `connectWithTunFd`, `setBootstrap`, `setTLSFingerprint`,
  `setTunFd`, `setSocketProtector` and none of `setShareProxy`,
  `isShareProxyEnabled`, `getLocalIPAddresses`; if it failed at first, the AAR
  was rebuilt with `./scripts/build_aar.sh` and the check then passed.
- `(cd go_src && go build ./... && go test ./...)` passes and the `ci.yml`
  filtered `go vet` (every package except `noise`) prints no findings.
- `flutter analyze` prints `No issues found!`; `flutter test` passes with 0
  failures; `(cd android && ./gradlew :app:testDebugUnitTest)` is
  `BUILD SUCCESSFUL` with the observed test count and 0 failures.
- `flutter build apk --debug --target-platform android-arm64` succeeds,
  `build/app/outputs/flutter-apk/app-debug.apk` exists, and the build used the
  AAR checked in the previous point.
- `git status --short` shows no source, test, Gradle, CI or release file changed
  by this task; `android/app/libs/dnstt.aar` and the debug APK are ignored;
  `linux/flutter/generated_plugins.cmake`,
  `windows/flutter/generated_plugins.cmake` and any other generated plugin
  registrant `pub get` rewrote are restored.

## Risks and what is needed from the user

- The literal `0.0.0.0` grep is not the whole story: `isPortInUse`
  (`ServerSocket(port)`), the `anyIPv4` UDP socket and the slipstream binary's
  default bind are wildcard binds spelled differently. Step 3's bind grep and
  the inventory exist so they are classified, not missed.
- `git grep` searches tracked files only; a stale build directory or the
  ignored AAR cannot prove anything. The AAR is covered by `javap`, and the APK
  check runs in a tree that carries the rebuilt one.
- A real non-loopback caller is a defect of 01/02, not a reason to edit code
  here. The task reports it and returns it to the lead.
- Flutter rewrites the two generated plugin files on `pub get`; restore only
  those incidental changes and preserve unrelated work.
- The AAR rebuild needs the prerequisites of 02's plan (Go toolchain, `javac`,
  SDK/NDK). If they are missing, report a blocker instead of a green APK built
  on the old AAR.
- If `flutter` is not on `PATH`, use the SDK recorded in
  `android/local.properties`; do not copy that path into a tracked file.
- The stage asks for a debug APK; release APKs stay in CI, as `AGENTS.md`
  requires. No device, server or network is needed.

## Outcome

- The integrated tree at `0c91c79` passes every point of `## Done when`. No
  source, test, Gradle, CI or release file was changed by this task, and no
  shipped SOCKS5 caller takes a non-loopback host.
- The share-identifier grep (step 2, nine patterns, `android go_src lib`) exits
  1 and prints nothing.
- The `0.0.0.0` grep prints four lines, not the three step 3 predicts: the
  `go_src` pathspec includes `go_src/man`, so the man-page line appears in both
  greps. The three source lines are `DnsttVpnService.kt:462`
  (`.addRoute("0.0.0.0", 0)`, the VPN route), `go_src/client/dialer.go:57`
  (a comment) and `go_src/client/dialer.go:64` (`"udp4", "0.0.0.0:0"`, the local
  address of the outbound resolver socket opened by `ListenPacket` at `:69`).
  The man-page line is `go_src/man/dnstt-server.1:169` (`0.0.0.0:53` in the
  server usage example). None of the four is a listener; the union of the two
  greps is exactly the three expected source lines and the man-page line.
- The bind-site grep (third command of step 3) prints 32 lines and every one is
  classified. Fourteen are test binds on loopback (`Socks5AuthRelayTest.kt:22`,
  `:90`; `bridge_test.go:48`, `:180`; `slipstream_test.go:124`, `:150`, `:157`;
  `transport_test.go:25`; `dnstt-server/e2e_test.go:32`, `:64`, `:227`, `:243`;
  `SlipstreamBridgeInstrumentationTest.kt:123`;
  `SlipstreamExecutableInstrumentationTest.kt:106`). Four are declarations or
  text, not binds (`go_src/TODO:23`, `dialer.go:68` `ListenConfig`,
  `mobile.go:43` and `:235` `net.Listener`). The other fourteen map to the rows
  below.
- Listener inventory:

| Construction | Bind expression | Host source | Verdict |
| --- | --- | --- | --- |
| `Socks5AuthRelay.kt:106-108` | `server.bind(InetSocketAddress(bindHost, bindPort))` | `DnsttProxyService.kt:201-204`, `SlipstreamProxyService.kt:139-142`, `MainActivity.kt:977-980` pass the literal `"127.0.0.1"`; `DnsttVpnService.kt:89-92` passes `proxyHost` (chain below); `Socks5AuthRelayTest.kt:170-173` passes `"127.0.0.1"` | SOCKS5 listener on loopback |
| `Socks5AuthRelay.kt:64-65` | `ServerSocket(0, 0, 127.0.0.1)` | literal `127.0.0.1`; called from `DnsttProxyService.kt:183`, `DnsttVpnService.kt:84`, `MainActivity.kt:976`, `SlipstreamProxyService.kt:125` | loopback free-port probe |
| `DnsttVpnService.kt:28`, `:110` (`EXTRA_PROXY_HOST`) | `proxyHost` into the relay and the tunnel client | producer `MainActivity.kt:324` takes the `connect` channel argument `proxyHost`, default `"127.0.0.1"` (`MainActivity.kt:104`); producers `MainActivity.kt:450` and `:875` are literals; the four Dart callers pass `'127.0.0.1'` (`connection_screen.dart:375`, `home_screen.dart:953`, `test_screen.dart:340`, `vpn_service.dart:1036`); the service is `android:exported="false"` (`AndroidManifest.xml:40`) | loopback; no other app can start the service with a different extra |
| `go_src/mobile/mobile.go:167` | `net.Listen("tcp", c.listenAddr)` | `DnsttProxyService.kt:184` builds `127.0.0.1:$proxyPort` or `127.0.0.1:$tunnelPort`; `DnsttVpnService.kt:161-162` builds `$host:$port` from the chain above; `MainActivity.kt:660-661` and `:817-818` pass `127.0.0.1:7001`; `MainActivity.kt:1061,1072` pass `127.0.0.1:$port` | SOCKS5 listener on loopback |
| `go_src/desktop/desktop.go:39-56` (`dnstt_create_client`) | `listenAddr` passed to `mobile.NewClient` unchanged | Dart `createClient` callers pass `127.0.0.1:$tunnelPort` (`vpn_service.dart:431-437`) and `127.0.0.1:7001` (`:851-857`); the default is `127.0.0.1:1080` (`dnstt_ffi_service.dart:222`) | desktop SOCKS5 listener on loopback |
| `socks5_auth_relay.dart:85-86` | `ServerSocket.bind(InternetAddress.loopbackIPv4, 0)` | literal loopback; called from `vpn_service.dart:59` | loopback free-port probe |
| `socks5_auth_relay.dart:97` | `ServerSocket.bind(bindHost, bindPort, shared: false)` | `vpn_service.dart:66-73` passes `bindHost: '127.0.0.1'` and `bindPort: proxyPort` | desktop SOCKS5 listener on loopback |
| `SlipstreamBridge.kt:66-75`, `:96-99` | `--tcp-listen-host <host>` | default `"127.0.0.1"` (`:73`); `DnsttVpnService.kt:367-375` passes the `host` from the chain above; `SlipstreamProxyService.kt:127-134` and `MainActivity.kt:569-576` pass `"127.0.0.1"`; the instrumentation test passes `LOOPBACK` and is not shipped | loopback |
| `slipstream_service.dart:163`, `:283` | `'--tcp-listen-host', '127.0.0.1'` | literal; no launch site omits the flag | loopback |
| `SshTunnelClient.kt:133-139` | `InetSocketAddress(InetAddress.getByName("127.0.0.1"), port)`, bound at `:138` | literal `127.0.0.1`; the port is the `SOCKS5_PROXY_PORT = 1080` constant (`:35`); the instances are created at `MainActivity.kt:670` and `:826` | SOCKS5 listener on loopback |
| `vpn_service.dart:880`, `:887`, `:896`, `:908`, `:936` (desktop SSH) | `ssh -D <proxyPort>` with no bind address | the port comes from the profile; OpenSSH listens on loopback when the address is omitted | desktop SOCKS5 listener on loopback, outside the Android stage |
| `DnsttProxyService.kt:236-244` | `java.net.ServerSocket(port)`, closed at once, no `accept()` | `proxyPort` from the intent | wildcard bind, port-availability probe, not a listener |
| `DnsttVpnService.kt:419-427` | `java.net.ServerSocket(port)`, closed at once, no `accept()` | `proxyPort` | wildcard bind, port-availability probe, not a listener |
| `dnstt_service.dart:520` | `RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)` | ephemeral; one query `send` to the configured resolver (`:541`) and one reply | outbound UDP DNS-test socket, not TCP, not a SOCKS5 listener |
| `go_src/client/bridge.go:66` | `net.ListenUDP("udp", 127.0.0.1:0)` | literal loopback | loopback resolver bridge, not SOCKS |
| `go_src/client/dialer.go:64`, `:68-69` | `ListenPacket("udp4", "0.0.0.0:0")`, `"udp6", "[::]:0"` | literal source address | outbound resolver socket, not a listener |
| `dnstt-server/main.go:905`, `man/dnstt-server.1:169` | `net.ListenPacket("udp", -udp address)` | CLI flag; the man page shows `0.0.0.0:53` | server binary, outside the app |
| `dnstt-client/main.go:121` | `net.ListenTCP("tcp", localAddr)` | `LOCALADDR` positional argument (`:227`) | CLI binary, outside the app |
| `vendor/slipstream-rust` | binds `::`, falling back to `0.0.0.0`, only when `--tcp-listen-host` is omitted | every app launch passes the flag (rows above) | out of the stage's scope; shipped launches are loopback |
| `Tun2Socks.kt:42-68` | points the engine at `127.0.0.1` | literal | client of the SOCKS listener, not a listener |

- `accept()` in shipped code appears only in `Socks5AuthRelay.kt:139` and
  `SshTunnelClient.kt:148`; the two `isPortInUse` sockets close immediately and
  never accept traffic. No construction takes its host from a config file, a
  profile or the environment: every supplier is a literal, the channel default
  or the `EXTRA_PROXY_HOST` chain above.
- AAR guard: `javap` on the unpacked `android/app/libs/dnstt.aar` lists
  `newClient`, `startBridge`, `probeResolver`, `connectWithTunFd`,
  `setBootstrap`, `setTLSFingerprint`, `setTunFd` and `setSocketProtector`, and
  the forbidden grep (`setShareProxy`, `isShareProxyEnabled`,
  `getLocalIPAddresses`) exits 1. No share symbol is present in the AAR's native
  libraries or in any `classes*.dex` of the APK either.
  `android/app/build.gradle.kts:137,163` depends on `files("libs/dnstt.aar")`,
  so the APK carries the checked AAR; the AAR rebuilt by
  [02-go-share-api-removal](../02-go-share-api-removal/plan.md) needed no
  second rebuild.
- Go: `go build ./...` exits 0; `go test -count=1 ./...` exits 0 (`ok` for
  `client`, `dns`, `dnstt-server` and `noise`, `no test files` for the rest);
  the `ci.yml` filtered vet (every package except `go list ./noise`) exits 0
  with no output.
- Flutter: `flutter pub get` exits 0, `flutter analyze` prints
  `No issues found!`, `flutter test` ends at `+75: All tests passed!`. Both
  `pub get` and `analyze` rewrite `linux/flutter/generated_plugins.cmake` and
  `windows/flutter/generated_plugins.cmake` (one `jni` entry in
  `FLUTTER_FFI_PLUGIN_LIST` each); both paths were restored and nothing else
  was touched.
- Kotlin: `(cd android && ./gradlew :app:testDebugUnitTest)` reports
  `BUILD SUCCESSFUL`; the first run was `UP-TO-DATE`, so it was repeated with
  `--rerun-tasks` for a fresh one. The results give `Socks5AuthRelayTest` 6 and
  `Tun2SocksTest` 5 — 11 tests, 0 failures, 0 errors. They land in
  `build/app/test-results/testDebugUnitTest/`, not in the
  `android/app/build/test-results/` path the plan names: Flutter redirects the
  module build directory to the root `build/`.
- Debug APK: `flutter build apk --debug --target-platform android-arm64`
  exits 0, prints `✓ Built build/app/outputs/flutter-apk/app-debug.apk` and the
  file exists (72 141 870 bytes). It was built in this tree against the checked
  AAR; the packaged `lib/arm64-v8a/libgojni.so` matches the AAR's copy apart
  from the ELF section table (the Gradle strip), `libslipstream_client.so` is
  packaged, and no share identifier appears in the dex. `android/build/` was
  not created (the build directory is redirected to the root `build/`), so
  there was nothing to delete.
- Exit statuses not named above: the two `0.0.0.0` greps and the bind-site grep
  exit 0 (they print matches), as do `unzip`, `javap`, `flutter analyze`,
  `flutter test`, `./gradlew :app:testDebugUnitTest` and the APK build; the
  share-identifier grep and the forbidden-symbol grep exit 1.
- Final tree: `git status --short` and `git diff --stat` name only this plan
  file; `git check-ignore` confirms `android/app/libs/dnstt.aar` and the debug
  APK are ignored; HEAD is still `0c91c79`; no untracked artifact was left.
- Limit of the proof: `javap` and the string scans establish that the AAR and
  the APK contain no share API; that the APK carries this AAR rests on the
  Gradle file dependency and on the build having run in this tree, not on a
  cryptographic provenance check.
- Review found no code defect and no regression; its findings were about the
  accuracy of the report, and they are folded into this Outcome: the desktop
  `ssh -D` listener is now a row (it was missing from the draft inventory), the
  `Socks5AuthRelay` and `SshTunnelClient` line references were corrected, "only"
  about `accept()` was qualified to shipped code, and the four-line first grep
  is recorded above. No source changed in the review round.
- What remains belongs to [04-docs-and-review](../04-docs-and-review/plan.md):
  closing `docs/CODE_REVIEW.md` item 3 with the reason and updating
  `CLAUDE.md` and architecture section 5.1.
