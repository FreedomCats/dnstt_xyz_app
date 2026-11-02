---
kind: stage
status: todo
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
