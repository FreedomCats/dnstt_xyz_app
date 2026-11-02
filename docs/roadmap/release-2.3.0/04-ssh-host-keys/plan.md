---
kind: stage
status: todo
---

# SSH host key verification

## Goal

An SSH connection through the tunnel no longer accepts a substituted server
key. Today `SshTunnelClient.kt` uses JSch with the default host key
repository, which accepts any key.

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
- `docs/SSH_TUNNEL_ARCHITECTURE.md`, `CLAUDE.md`.

## Done when

- On a real server the first connection stores the key; a changed key refuses
  and names both fingerprints; forgetting the key lets the new one in.
- The unit test is green, and the existing Android unit test suite still passes.

## Depends on

Nothing.

## Risks and what is needed from the user

A changed key blocks the user until they forget it — accepted. The check on a
real server needs the user's SSH server and cannot be delegated; if it has to
wait, this stage finishes with the unit test and the live check moves to the
live-checks stage with a note.
