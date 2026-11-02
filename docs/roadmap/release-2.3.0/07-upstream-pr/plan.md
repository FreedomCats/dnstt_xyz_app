---
kind: stage
status: todo
---

# Upstream pull request for issue #15

## Goal

The SOCKS5 username/password authentication work (upstream issue #15) goes
upstream: a pull request against the upstream repository with a green build.

## What to do, what is touched

- A branch from current upstream `master`.
- Cherry-pick the auth commit and the review fixes; resolve the `CLAUDE.md`
  conflicts (the fork's `CLAUDE.md` and `AGENTS.md` are the fork's own).
- Rerun the Go tests, the Flutter tests and the APK build on that branch.
- Open the PR with `Closes #15`, or hand the branch to the user if the session
  has no write access.

## Done when

- The PR is open upstream and its CI is green.

## Depends on

3 (no relay that lends the upstream account to the LAN), 6 (the auth path
checked live).

## Risks and what is needed from the user

The session has no write access to the upstream repository: the user opens the
PR or provides access. The PR raises the shared-proxy question upstream, where
it may be discussed — that discussion is outside this map.
