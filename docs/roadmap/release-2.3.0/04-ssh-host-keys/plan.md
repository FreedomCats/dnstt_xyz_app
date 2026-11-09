---
kind: stage
status: in-progress
base: 9ee970ea8843beb4fff6e66462732b40a054030d
---

# SSH host key verification and VPN port wiring

## Goal

An SSH connection through the tunnel no longer accepts a substituted server
key, and the SSH VPN mode actually works: the tunnel service points tun2socks
at the SOCKS5 port that `SshTunnelClient` binds. Today `SshTunnelClient.kt`
uses JSch with the default host key repository, which accepts any key, and
`MainActivity.startVpnServiceForSsh` passes port 7000 while the SOCKS5 proxy
listens on 1080.

The scheme is decided: trust on first use, with a refusal when the key changes
and both fingerprints named. There is no dialog — the session lives in a
service without UI, and the user forgets the key in the config editor when a
server really changed (`docs/ROADMAP_WORKFLOW.md`, "Decisions taken while
moving").

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

- On a real server the first connection stores the key; a changed key refuses
  and names both fingerprints; forgetting the key lets the new one in.
- The unit test is green, and the existing Android unit test suite still passes.
- The SSH VPN mode starts `DnsttVpnService` with the SOCKS5 port
  `SshTunnelClient` actually binds; a build or test check prevents the two
  values from drifting apart again.

## Depends on

Nothing.

## Risks and what is needed from the user

A changed key blocks the user until they forget it — accepted. The check on a
real server needs the user's SSH server and cannot be delegated; if it has to
wait, this stage finishes with the unit test and the live check moves to the
live-checks stage with a note. The SSH VPN port fix is local and needs no user
action; it was found during stage 03 acceptance and the user placed it in this
stage.
