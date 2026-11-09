---
kind: task
status: todo
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

The APK must be built with the AAR rebuilt from the changed Go sources:
`javap` on `android/app/libs/dnstt.aar` must show neither `setShareProxy` nor
`isShareProxyEnabled`, otherwise run `./scripts/build_aar.sh` first.

## Done when

- The grep and the listener inventory show no SOCKS5 listener outside
  `127.0.0.1`; every `0.0.0.0` match is classified as a non-listener.
- `flutter analyze` is clean, the full `flutter test` passes, the Go tests and
  filtered vet pass, and `:app:testDebugUnitTest` passes.
- `flutter build apk --debug --target-platform android-arm64` succeeds with the
  rebuilt AAR, and `git status` carries no generated artifact; incidental
  rewrites of `linux/flutter/generated_plugins.cmake` and
  `windows/flutter/generated_plugins.cmake` are restored.
- No source, test or workflow file is changed by this task.

## Risks and what is needed from the user

- A stale `android/app/libs/dnstt.aar` lets the APK build pass with the old
  library; the `javap` check exists to prevent that false green.
- Flutter rewrites the two generated plugin files on `pub get`; restore only
  those incidental changes and preserve unrelated work.
- The stage asks for a debug APK; release APKs stay in CI, as `AGENTS.md`
  requires. No device, server or network is needed.
