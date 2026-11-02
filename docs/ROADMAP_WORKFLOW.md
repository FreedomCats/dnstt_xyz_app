# Roadmap workflow: how work is planned and tracked

This document describes how project work is planned and handed to the `lead`
agent, and records the decisions taken when the project moved from
`docs/STATUS.md` to a roadmap tree. It follows `AGENTS.md`: no dates, no
environment details, no servers, credentials or other personal data.

## Context: how work was tracked before

Before this change, the state of the project lived in three places that
overlapped:

- `docs/DOH_DOT_TUN2SOCKS_PLAN.md` — the design of the DoH/DoT and tun2socks
  features together with a seven-stage work plan (its section 6).
- `docs/STATUS.md` — the fork state, results of every finished stage, the
  "Next steps" list and working notes (toolchain versions, test commands,
  pitfalls of the build environment).
- `docs/STAGE1_GO_LIBRARY_CI.md` … `docs/STAGE5_TUN2SOCKS.md` — per-stage
  plans and results; `docs/CODE_REVIEW.md` — the review of the fork.

Problems with that layout:

1. **Two sources of truth about what is next.** The stage list in the design
   document and the "Next steps" section of `STATUS.md` were both read as the
   queue of work, and they disagreed: `STATUS.md` carried items (the first
   release, the upstream pull request, live checks) that the plan did not
   have, and the plan carried stages that were already done.
2. **No per-item status.** Finished stages were struck through or described in
   prose; nothing said which items were blocked on the user and which were
   ready to start.
3. **The plan and the state were one document.** Every update rewrote a
   four-hundred-line file, and the reader had to work out what changed.

## Decision: a roadmap tree under `docs/roadmap/`

The project uses the roadmap scheme of the `lead` agent: a tree of nodes,
one `plan.md` per node, work handed to a `coordinator` node by node. The
scheme itself is described in the `lead` agent rules; this document records
only how it is applied here.

```
docs/
  roadmap/
    README.md                     list of maps: slug, status, one line
    release-2.3.0/
      plan.md                     root: goal, already done, stages
      journal.md                  pointer to the journal outside the repository
  local/                          outside git (.gitignore)
    roadmap/
      release-2.3.0/
        journal.md                where we stopped, decisions, rejected options
  DOH_DOT_TUN2SOCKS_ARCHITECTURE.md
  CODE_REVIEW.md
  SSH_TUNNEL_ARCHITECTURE.md
  STAGE1_GO_LIBRARY_CI.md … STAGE5_TUN2SOCKS.md
  ROADMAP_WORKFLOW.md             this document
```

### Why `docs/roadmap/` and not `doc/roadmap/`

The `lead` rules take `doc/roadmap/` as the default and let the project rules
choose another place. The project already keeps all documents in `docs/`, and
`AGENTS.md` governs what may be published there. A second documentation root
next to `docs/` would fall outside those rules and invite a parallel set of
conventions. `AGENTS.md` therefore names `docs/roadmap/` as the place for the
map.

### Why the journal is outside git

`STATUS.md` was published, and so it had to follow the privacy rules: no
dates, no environment, no names. That worked because a human wrote it and read
it before every commit. The journal is different: the `lead` agent appends to it
after every node, unattended, and a journal entry is exactly the kind of text
that picks up the machine, the date, the server tested against and the resolver
used. `AGENTS.md` already has a place for such notes: `docs/local/`, ignored by
git, meant for stage plans and working notes.

So the journal lives in `docs/local/roadmap/<slug>/journal.md`, and the map
keeps a one-line `journal.md` pointing there. A fresh clone has the map but not
the journal; that is accepted, because work is resumed from the machine that
holds `docs/local/`.

The journal records no dates: an entry names the node and the commit instead.

## What goes where

| Question | Answer |
|---|---|
| What is the goal and what are the stages? | `docs/roadmap/<slug>/plan.md` (root) |
| What is a stage or a task, and is it detailed? | `docs/roadmap/<slug>/NN-<name>/plan.md` |
| Where did we stop, and why were decisions made? | `docs/local/roadmap/<slug>/journal.md` |
| What was designed, and why that way? | `docs/*_ARCHITECTURE.md`, the per-stage `docs/STAGE*.md` |
| How do I build, test and avoid the known pitfalls? | `CLAUDE.md`, "Development workflow" |
| Which work is open and known to be broken? | `docs/CODE_REVIEW.md` (the review itself), the map (what is planned) |

Documents are not duplicated between these places. A stage that is finished
lives in its `docs/STAGE*.md` and as a line in the root `plan.md`; it does not
get a map node, because the `lead` creates a directory for every stage listed
and would otherwise redo the work.

## How a new session finds the map

`CLAUDE.md` starts with `@docs/roadmap/README.md`, so the map index is read
at the start of every session that loads the project instructions. The index
lists the maps with their status and links the root `plan.md` of each.

## Decisions taken while moving

| Decision | Rejected alternatives | Reason |
|---|---|---|
| Map in `docs/roadmap/` | `doc/roadmap/` (the default), `docs/local/roadmap/` (outside git) | One documentation root; the map is meant to be published, the journal is not. |
| One map, `release-2.3.0` | One map per topic (DoH/DoT, CI, security, release) | The release depends on all of them; separate maps would need a fourth list saying which goes first. |
| Map files in English | Russian, mixed | `AGENTS.md`, "Language". Only the chat with the user is in another language. |
| Journal outside git, without dates | Journal in git; dates in the journal; two journals | The journal is written unattended and is the most likely place to leak environment details. A date adds nothing to a reader when the commit is named. |
| Finished stages 1–5 are not map nodes | List them as `done` nodes | The `lead` creates a directory for every stage in the root and would plan the work again. |
| Design document keeps the architecture, loses the plan | Keep the plan in the document and link the map to it | Two queues of work was the problem this change solves. |
| Shared LAN access to the proxy is disabled, not implemented | Add a generated password (review item 3), reject `shareProxy` only | No Dart code calls `connectProxyShared` or `setProxySharing`; the mode is unreachable from the UI. A password would be a new feature with UI, storage and tests; disabling removes the exposed paths instead. |
| SSH host keys: trust on first use, refuse on change | Warn and let the user continue, ask the fingerprint in the config dialog | Refusing is what the tunnel needs: the SSH layer is an addition to Noise, not a place to be lenient. The user can forget the key in the config when a server really changed. |

## Open questions

- The tunnel DNS mode (stage 6 of `docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md`)
  stays optional and is not part of the map. It becomes a stage if the live
  checks show applications broken by fake-IP answers.
