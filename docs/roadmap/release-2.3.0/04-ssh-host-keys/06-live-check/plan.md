---
kind: task
status: todo
depends: [01-tofu-host-key-repository, 02-ssh-vpn-port-fix, 03-config-fingerprint, 04-connect-wiring]
---

# Check host key verification on a real SSH server

## Task

Verify on the user's SSH server and device what the unit tests cannot prove:
the first connection stores the presented key, a changed key refuses with both
fingerprints, forgetting the key lets the new one in, and SSH VPN mode carries
traffic after the proxy-port fix. This check needs the user's server and cannot
be delegated to an agent.

If the user cannot run it before this stage is accepted, this node is dropped
with a note and the check moves to [06-live-checks](../../06-live-checks/plan.md),
which already lists "SSH mode with host key verification"; the stage then
closes on the unit tests and local checks, as its risks allow.

## Steps

1. Install a build from the work branch on the device (a debug APK is enough;
   the release is stage 05). Use an SSH config pointed at the user's tunnel and
   server.
2. First use, VPN mode: connect the SSH tunnel in VPN mode. Expect the tunnel
   to establish and device traffic to pass (for example a page load), and the
   config editor to show an `SHA256:` fingerprint. On the server, compare it
   with `ssh-keygen -lf` for the host key file; the two values must be equal.
3. Changed key: make the server present a different host key (rotate the host
   key of a test SSH server behind a test tunnel, or replace the host key file
   and restart the SSH daemon) and reconnect. Expect a refusal before
   authentication: no VPN start, no traffic, and an error naming both the
   stored and the presented fingerprints plus the "forget the host key" hint.
   Do not accept or overwrite the presented key.
4. Forget: open the config editor, press "Forget host key", save, and connect
   again. Expect the connection to succeed and the editor to show the new
   fingerprint; the old one must not be used.
5. SSH proxy mode: repeat a short first-use and forget check without VPN, so
   the non-VPN path is covered too. Confirm the SOCKS5 proxy is reachable on
   1080, the port the client binds and the VPN mode now passes to the service.
6. Record the results in the journal: pass/fail per step, and the fingerprint
   values if useful for comparison. Do not put the server, its address,
   resolver, date or time into the map or `docs/`; a defect becomes a new map
   node.

## Done when

- The user observes: the first connection stores the key and the editor shows
  the same `SHA256:` value as `ssh-keygen -lf`; a changed key refuses and names
  both fingerprints; forgetting the key lets the new key in; SSH VPN mode
  carries traffic through the port the client binds.
- Both the proxy and VPN SSH paths are covered.
- Results are recorded in the journal outside git; any failure has its own map
  node; no environment or server data is added to the repository.

## Risks and what is needed from the user

- Needs the user's SSH server, a device and the ability to change the server's
  host key or a second test server. Rotating a production host key affects
  other clients; use a test server when possible.
- The live check cannot be delegated to an agent and may be postponed to stage
  06. In that case this node is dropped with a note, not marked done.
- The SSH VPN path is the one the stage 03 acceptance found broken; check the
  data path, not only the connection message.
