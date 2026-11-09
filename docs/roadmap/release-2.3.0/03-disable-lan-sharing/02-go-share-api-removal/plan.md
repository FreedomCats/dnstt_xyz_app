---
kind: task
status: todo
depends: [01-android-share-removal]
---

# Remove the sharing API from the Go mobile library

## Task

Remove the Go-side "share proxy" API: the `shareProxy` field of `DnsttClient`,
`SetShareProxy`, `IsShareProxyEnabled` and the `0.0.0.0` rewrite in `Start`.
`Listen` must use the caller's address unchanged; every app caller passes
loopback.

The same pass removes `GetLocalIPAddresses` and `isPrivateIP`. They are exported
by gomobile but nothing in `android/`, `lib/` or `go_src/desktop` calls them,
and they exist to display a LAN address for the removed mode. Removing them
also makes the `strings` import unused.

`go_src/desktop/desktop.go` and the Dart FFI bindings do not mirror the sharing
API: the C exports take `listenAddr`, and `dnstt_ffi_service.dart` defaults to
`127.0.0.1:1080`. No desktop or Dart change is needed. The Kotlin call sites are
already removed by [01-android-share-removal](../01-android-share-removal/plan.md),
so replacing the AAR after this change cannot break the app build.

## Done when

- `grep -RIn "ShareProxy\|shareProxy\|GetLocalIPAddresses\|isPrivateIP" go_src`
  is empty, and `mobile.go` listens only on the address its caller passes.
- `go test ./...` and the filtered `go vet` from `ci.yml` pass.
- `./scripts/build_aar.sh` succeeds, its path check reports "ok", and `javap`
  on the generated `mobile.DnsttClient` shows neither `setShareProxy` nor
  `isShareProxyEnabled`.
- Outside the map, the diff contains only `go_src/mobile/mobile.go`; the
  generated AAR is not added to git.

## Risks and what is needed from the user

- `scripts/build_aar.sh` installs the pinned `gomobile`/`gobind` into a
  temporary directory and may need the Go module cache or network. If it cannot
  run offline, report it rather than committing a stale AAR or editing
  generated files by hand.
- Dropping `GetLocalIPAddresses` without dropping the `strings` import fails
  compilation; check the import block after the edit.
- The task needs no user action, server or device.
