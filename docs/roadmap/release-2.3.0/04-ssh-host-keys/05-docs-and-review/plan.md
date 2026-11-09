---
kind: task
status: todo
depends: [01-tofu-host-key-repository, 02-ssh-vpn-port-fix, 03-config-fingerprint, 04-connect-wiring]
---

# Document SSH host key verification and close review item 4

## Task

Make the project documentation describe the implemented SSH mode and host key
verification, and close `docs/CODE_REVIEW.md` item 4 with evidence. The current
`docs/SSH_TUNNEL_ARCHITECTURE.md` is stale: it shows the DNSTT tunnel on 7000
while the code uses 7001, lists a non-existent `sshLocalPort` field, and says
nothing about host key verification. `CLAUDE.md` has no SSH-mode component
description, which the code review itself notes.

This task changes documentation only. It closes the review item after tasks
01-04 are accepted; the live check is [06-live-check](../06-live-check/plan.md)
and may be deferred, so the closure must cite the unit test and the code, not a
real-server run.

## Steps

1. `docs/SSH_TUNNEL_ARCHITECTURE.md`:
   - Correct the diagram and the data flow: the DNSTT client listens on
     `127.0.0.1:7001`, JSch connects to it, and the local SOCKS5 proxy is
     `127.0.0.1:1080`. Remove the `sshLocalPort` row from the configuration
     table; the port is fixed and exposed as
     `SshTunnelClient.SOCKS5_PROXY_PORT`.
   - Add `sshHostKeyFingerprint` to the table with its format
     (`SHA256:` plus unpadded base64, the value `ssh-keygen -lf` prints) and
     the rule that a config without it accepts the first key.
   - Add a "Host key verification" section: trust on first use; the JSch
     `HostKeyRepository` in `SshHostKeyRepository.kt`; a changed key refuses
     the connection and names both fingerprints with the "forget the key in the
     config if the server really changed" hint; there is no dialog; the config
     editor's "Forget host key" clears the field.
   - State the platform split: Android uses JSch and the config field; desktop
     uses the system `ssh` command and OpenSSH's `known_hosts`, so the config
     field is Android-only.
   - Describe SSH VPN mode: `MainActivity` starts `DnsttVpnService` with
     `SshTunnelClient.SOCKS5_PROXY_PORT`, and the service starts tun2socks on
     that port because it does not start a tunnel in SSH mode.
2. `CLAUDE.md`:
   - Add an `SshTunnelClient.kt / SshHostKeyRepository.kt` subsection under
     "Key Components": JSch over the DNSTT tunnel on `127.0.0.1:7001`, the
     local SOCKS5 proxy on 1080, trust on first use, the
     `sshHostKeyFingerprint` config field, the refusal with both fingerprints,
     "Forget host key", and the shared port constant used by SSH VPN mode.
   - Update the `DnsttVpnService.kt` bullet: in SSH mode it uses the SOCKS5
     proxy that `MainActivity` started, on
     `SshTunnelClient.SOCKS5_PROXY_PORT` (1080), and starts no tunnel of its
     own.
3. `docs/CODE_REVIEW.md`, item 4: add a "Resolved." paragraph in the same style
   as item 3: `SshTunnelClient` now installs a trust-on-first-use
   `HostKeyRepository`, refuses a changed key with both fingerprints, stores the
   fingerprint in the config and offers "Forget host key"; cite this stage and
   the unit test in
   [01-tofu-host-key-repository](../01-tofu-host-key-repository/plan.md), and
   name the live check node as the remaining real-server check when it is
   deferred. Do not mark it resolved on the plan alone. Also remove the
   now-false note in the overview (line 26) that the SSH mode is not described
   in `CLAUDE.md`, and keep only the still-true part of the Documentation
   bullet (line 188).
4. Check the wording against the code: `grep -RIn
   "StrictHostKeyChecking" docs CLAUDE.md` must not claim the app still uses
   `no` (the quoted history in the review item is reworded or marked resolved);
   every referenced file and repository name exists; `git diff --check` passes.
5. Confirm the final diff contains only these three documents and no code,
   test, workflow or dependency change, and that no date, environment name,
   server, resolver, address or other personal data was added.

## Done when

- `docs/SSH_TUNNEL_ARCHITECTURE.md` matches the implemented ports, the new
  config field, the TOFU behavior, the refusal message and the Android/desktop
  split.
- `CLAUDE.md` describes the SSH client and repository under Key Components and
  corrects the `DnsttVpnService` SSH-mode bullet.
- `docs/CODE_REVIEW.md` item 4 is marked resolved with evidence from tasks
  01-04 and names the live check as the remaining real-server step if it is
  deferred; it is not closed on the plan alone.
- Only those three documents changed; no dates, environment or device details,
  servers, resolvers or addresses are present.

## Risks and what is needed from the user

- Close the review item only after tasks 01-04 are accepted. If the live check
  is deferred to stage 06, say so explicitly instead of implying that a real
  server was tested.
- Keep the architecture document a description of behavior, not a copy of the
  code. Do not restate implementation line numbers that will drift.
- The desktop SSH path is not covered by the config field; do not claim it is.
  If a later stage wants desktop TOFU, it is a separate change.
- No user action, server or device is needed for this documentation task.
