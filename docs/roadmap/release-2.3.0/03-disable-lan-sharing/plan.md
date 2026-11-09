---
kind: stage
status: done
base: 5bc8530392acc7841b80c82b1f20c1559ac3354e
---

# Disable shared LAN access to the proxy

## Goal

Close `docs/CODE_REVIEW.md` item 3 without shipping a half-built feature. The
"share proxy" mode binds the SOCKS5 listener to `0.0.0.0` with no
authentication, and nothing in the Dart code reaches it: no UI calls
`connectProxyShared` or `setProxySharing`. The exposed paths are removed; a
password-protected version can come back later as its own stage
(`docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md`, section 5.1).

## What to do, what is touched

- `DnsttProxyService.kt`, `SlipstreamProxyService.kt`, `SshTunnelClient.kt`:
  remove the `0.0.0.0` branches, keep `127.0.0.1`.
- `MainActivity.kt`: remove `setProxySharing` and `connectProxyShared`.
- `go_src/mobile/mobile.go`: remove `setShareProxy` / `IsShareProxyEnabled` and
  the `0.0.0.0` listener they enable; the desktop C exports in
  `go_src/desktop/desktop.go` and the Dart bindings follow if they mirror it.
- `docs/CODE_REVIEW.md` (item 3 closed with the reason), `CLAUDE.md`.

Children, in order:

1. [01-android-share-removal](01-android-share-removal/plan.md) (task): remove
   the sharing branches and platform-channel wrappers from the Kotlin services
   and `MainActivity.kt`; every app listener binds `127.0.0.1`.
2. [02-go-share-api-removal](02-go-share-api-removal/plan.md) (task): remove
   `SetShareProxy`, `IsShareProxyEnabled` and the `0.0.0.0` rewrite from
   `go_src/mobile/mobile.go`, remove the unused local-address helper, and
   rebuild the AAR.
3. [03-verify-local-only](03-verify-local-only/plan.md) (task): prove with
   greps, the Go/Flutter/Kotlin suites and a debug APK build that no SOCKS5
   listener binds outside loopback.
4. [04-docs-and-review](04-docs-and-review/plan.md) (task): close
   `docs/CODE_REVIEW.md` item 3 with the reason and update `CLAUDE.md` and
   architecture section 5.1.

The desktop C exports and the Dart bindings do not mirror the sharing API
(`go_src/desktop/desktop.go` takes `listenAddr` and the Dart FFI defaults to
`127.0.0.1:1080`), so no desktop or Dart source changes; node 03 checks that in
the listener inventory.

## Done when

- No code path in the app binds a SOCKS5 listener to anything but `127.0.0.1`
  (checked by grep over `android/`, `go_src/`, `lib/`).
- The Go tests, the Flutter tests and a debug APK build pass.
- Review item 3 is marked closed with the reason.

## Depends on

Nothing.

## Risks and what is needed from the user

The feature disappears; a user who shares the proxy with another device loses
it. If it is wanted, it returns as its own stage with a generated password.

## Outcome

- The stage is complete at `94a6d22` (children: `32331ff`, `0c91c79`,
  `06b7618`, `94a6d22`). The share-proxy mode was removed rather than
  password-protected, as the stage decided: `DnsttProxyService.kt`,
  `SlipstreamProxyService.kt` and `SshTunnelClient.kt` always bind
  `127.0.0.1`; `MainActivity.kt` no longer exposes `setProxySharing`,
  `isProxySharingEnabled`, `connectProxyShared` or `getLocalIpAddresses` and
  takes no `shareProxy` argument; `go_src/mobile/mobile.go` no longer exports
  `SetShareProxy`, `IsShareProxyEnabled`, `GetLocalIPAddresses` or
  `isPrivateIP` and passes `listenAddr` unchanged to `net.Listen`. The AAR was
  rebuilt from that source (ignored by git) and no longer exports the removed
  API. `docs/CODE_REVIEW.md` item 3 is closed with the reason, the suggested
  order no longer asks for a password, and `CLAUDE.md` and architecture
  section 5.1 describe loopback-only proxy modes.
- Acceptance over `5bc8530..94a6d22` found no defect or regression. The
  share-identifier grep over `android/`, `go_src/` and `lib/` is empty; the
  only `0.0.0.0` matches are the VPN route, the outbound resolver socket and
  the server man page. The listener inventory of
  [03-verify-local-only](03-verify-local-only/plan.md) covers every shipped
  construction: all SOCKS5 listeners bind loopback; `isPortInUse`
  (`ServerSocket(port)`, no `accept()`), `dialer.go` and the Dart DNS-test
  socket are wildcard probe or outbound sockets, not SOCKS5 listeners;
  `EXTRA_PROXY_HOST` is reachable only through the channel default and
  literals, and the service is `android:exported="false"`; the desktop
  `ssh -D <port>` omits the address, so OpenSSH listens on loopback.
- Checks run at `94a6d22` on a clean tree: `flutter pub get`, `flutter analyze`
  (`No issues found!`), `flutter test` (75 tests, all passed); `go build ./...`,
  `go test ./...` and the `ci.yml` filtered `go vet`; `./gradlew
  :app:testDebugUnitTest --rerun-tasks` (11 tests, 0 failures); `flutter build
  apk --debug --target-platform android-arm64`. The debug APK was rebuilt after
  deleting the previous one; its `libgojni.so` is byte-identical to the AAR's
  copy after `llvm-strip --strip-unneeded`, and neither the dex nor the native
  libraries contain a share identifier. `android/build/` was not created; the
  AAR and the APK are ignored by git; the two generated-plugin files rewritten
  by Flutter were restored. `git diff --check` passes.
- Deferred: a password-protected share mode is not built. If wanted, it
  returns as a stage of its own with a generated password, a warning and a
  local-credentials mode of `Socks5AuthRelay` (architecture section 5.1).
- Real problems not fixed because of price: none in this stage. Acceptance
  noticed a pre-existing defect outside the stage: in the SSH VPN mode
  `MainActivity.kt` starts `DnsttVpnService` with `EXTRA_PROXY_PORT = 7000`
  while `SshTunnelClient` binds its SOCKS5 proxy on 1080, so tun2socks is
  pointed at a port where nothing listens. The mismatch exists at the stage
  base and is neither caused nor worsened by this stage; it needs its own plan.
