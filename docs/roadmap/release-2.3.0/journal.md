# Journal: where we are

This file is in git only as a pointer. The journal itself follows `AGENTS.md`,
"Documents in `docs/`": it is written after every node, unattended, and is the
place where the date, the environment, the test device and the resolver used
would otherwise end up in a public repository. It lives in
`docs/local/roadmap/release-2.3.0/journal.md`, which `.gitignore` keeps out of
git.

The journal holds, in this order:

- **Where we left off** — the current node and its state, an open question for
  the user and whether it is answered, the state of the working tree if a task
  was interrupted, what to do next.
- **Log** — appended only: the node, what was decided, by whom (the user or the
  `lead` agent), why, which alternatives were rejected, deviations from the
  plan and what the work turned up. Entries name the node and the commit, not
  the date.

A fresh clone has no journal; work is resumed from the machine that holds
`docs/local/`. If the journal is lost, the map and `git log` still give the
state of the work: the root `plan.md` says which stages are open, and the
`## Outcome` sections of finished tasks say what each one did.
