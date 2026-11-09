---
kind: stage
status: done
base: 9ee970ea8843beb4fff6e66462732b40a054030d
---

# SSH host key verification and VPN port wiring

## Goal

An SSH connection through the tunnel no longer accepts a substituted server
key on Android, and the SSH VPN mode actually works: the tunnel service points
tun2socks at the SOCKS5 port that `SshTunnelClient` binds. Today
`SshTunnelClient.kt` uses JSch with the default host key repository, which
accepts any key, and `MainActivity.startVpnServiceForSsh` passes port 7000 while
the SOCKS5 proxy listens on 1080. The desktop SSH path runs the system `ssh`
without host key verification in this release; it is documented and deferred.

The scheme is decided: trust on first use, with a refusal when the key changes
and both fingerprints named. There is no dialog — a changed key is refused, and
the user forgets the key in the config editor when a server really changed
(`docs/ROADMAP_WORKFLOW.md`, "Decisions taken while moving").

## What to do, what is touched

- A JSch `HostKeyRepository` with trust on first use.
- The fingerprint stored in the config (`sshHostKeyFingerprint`), including
  import/export and `StorageService`.
- Refusal on change, with the stored and the presented fingerprints in the
  error text.
- "Forget host key" in the config editor.
- A Kotlin unit test for the repository (first use stores, changed key refuses,
  forgotten key is accepted again).
- Fix the SSH VPN proxy-port wiring: `MainActivity.startVpnServiceForSsh` must
  pass the port `SshTunnelClient` binds (1080) instead of 7000, with a check
  that prevents the two values from drifting apart again.
- `docs/SSH_TUNNEL_ARCHITECTURE.md`, `CLAUDE.md`.

Children, in order:

1. [01-tofu-host-key-repository](01-tofu-host-key-repository/plan.md) (task):
   the JSch `HostKeyRepository` with trust on first use, its refusal message
   with both fingerprints, the `SshTunnelClient` wiring and the Kotlin unit
   test.
2. [02-ssh-vpn-port-fix](02-ssh-vpn-port-fix/plan.md) (task): one public port
   constant used by both the SOCKS5 listener and the VPN intent, so SSH VPN
   mode points tun2socks at the port that actually listens.
3. [03-config-fingerprint](03-config-fingerprint/plan.md) (task): the
   `sshHostKeyFingerprint` field in the model, storage, import/export and the
   config editor with "Forget host key".
4. [04-connect-wiring](04-connect-wiring/plan.md) (task): the method channel
   passes the stored fingerprint to Kotlin and the accepted one back to Dart,
   which persists it; a changed key reaches the UI as an error.
5. [05-docs-and-review](05-docs-and-review/plan.md) (task):
   `docs/SSH_TUNNEL_ARCHITECTURE.md`, `CLAUDE.md` and the closure of
   `docs/CODE_REVIEW.md` item 4.
6. [06-live-check](06-live-check/plan.md) (task): the user's check on a real
   SSH server. If it cannot run before this stage is accepted, it moves to
   [06-live-checks](../06-live-checks/plan.md), which already lists the SSH
   check, and the stage closes on the unit tests and local checks, as the
   risks below allow.

## Done when

- The Android unit tests and local checks pass. The real-server check (first
  connection stores the key, a changed key refuses with both fingerprints,
  forgetting the key lets the new one in) is moved to the
  `06-live-checks` stage because the user has no SSH server; the stage outcome
  records the move and does not claim a real-server run.
- The SSH VPN mode starts `DnsttVpnService` with the SOCKS5 port
  `SshTunnelClient` actually binds; a build or test check prevents the two
  values from drifting apart again.
- The desktop SSH path's lack of host key verification is documented; desktop
  TOFU is a separate later stage.

## Depends on

Nothing.

## Risks and what is needed from the user

A changed key blocks the user until they forget it — accepted. The check on a
real server needs the user's SSH server and cannot be delegated; if it has to
wait, this stage finishes with the unit test and the live check moves to the
live-checks stage with a note. The SSH VPN port fix is local and needs no user
action; it was found during stage 03 acceptance and the user placed it in this
stage.

## Outcome

- The stage is complete with children `22176f7`, `b0dd241`, `1d36b44`,
  `7f0afac` and `6e68ed1`; [06-live-check](06-live-check/plan.md) is `dropped`,
  not done. Android verifies the SSH host key by trust on first use:
  `SshHostKeyRepository` hashes the public key blob as `SHA256:` plus unpadded
  standard base64 (the value `ssh-keygen -lf` prints), accepts and exposes the
  first key when the config has none, accepts the same key later, and refuses a
  different one with both fingerprints and the hint to forget it. The config
  field `sshHostKeyFingerprint` goes through the model, storage, import
  (version 1.4) and export; the editor shows it and has "Forget host key";
  Dart sends the stored value on both channel methods, parses one map reply
  (`connected`, `hostKeyFingerprint`, `error`) and persists the accepted value
  only for the config that was connected; a changed key reaches the UI through
  `lastError`. `SshTunnelClient.SOCKS5_PROXY_PORT` (1080) is the single port
  of the listener and the SSH VPN intent, pinned by `SshTunnelPortTest`, and
  the non-SSH 7000 defaults are unchanged. `docs/SSH_TUNNEL_ARCHITECTURE.md`,
  `CLAUDE.md` and `docs/CODE_REVIEW.md` item 4 describe the implemented mode
  and close the review item.
- Acceptance of `9ee970e..6e68ed1` and of the fixes in this commit found no
  remaining defect or regression. One narrow issue was fixed in review: the
  already-running branch of both SSH channel methods returns no fingerprint,
  because the running client's fingerprint belongs to the config that started
  it and must not be persisted into the config being connected now. The
  acceptance also corrected two document claims (desktop does not use
  `known_hosts`; there is no accept dialog because a changed key is refused,
  not because the client runs in a service) and a stale line reference in a
  test comment.
- Checks run on the accepted tree: `flutter analyze` (`No issues found!`),
  `flutter test` (103 tests, all passed); `go build ./...`, `go test ./...`
  and the `ci.yml`-filtered `go vet`; `(cd android && ./gradlew
  :app:testDebugUnitTest --rerun-tasks)` (21 tests, 0 failures);
  `flutter build apk --debug --target-platform android-arm64` from the
  prepared ignored `dnstt.aar` and the three staged Slipstream libraries. The
  generated `linux/` and `windows/` plugin files rewritten by Flutter were
  restored; `git diff --check` is clean.
- Deferred: the real-server check is moved to
  [06-live-checks](../06-live-checks/plan.md), which lists the SSH mode and
  host key verification. No SSH server was used and this stage claims no live
  run: the first-connection persistence, the changed-key snackbar and the SSH
  VPN data path on a device remain unverified. The desktop SSH path still runs
  the system `ssh` with host key verification disabled; it is documented in
  the architecture and `CLAUDE.md`, and desktop TOFU is a separate later
  change. Outside this stage, the stage 02 API 24/25 `destroy()` fallback
  remains verified statically only; no API 24/25 runtime was used here either.
- Real problems not fixed because of price: none in the delivered flow.
  Acceptance noticed pre-existing defects outside the stage: the SSH
  proxy-mode success message shows `state.proxyPort` while the listener binds
  1080, so a changed proxy port gives a wrong message
  (`lib/screens/home_screen.dart`, `lib/services/vpn_service.dart`); the
  already-running SSH VPN branch returns success without starting the VPN
  service; and config export still writes `sshPassword` in clear text. None is
  caused or worsened by this stage; each needs its own plan.
