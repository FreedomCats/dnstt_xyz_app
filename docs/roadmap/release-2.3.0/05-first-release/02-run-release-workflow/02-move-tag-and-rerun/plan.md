---
kind: task
status: blocked
detailed: true
depends: [01-macos-path-remap]
---

# Move the tag to the fixed commit and rerun the release

## Task

The first `Build and Release` run of `v2.3.0-beta` (`42682231223`) is terminal
and failed in both macOS jobs; `create-release` was skipped and no release page
exists, so the tag may still be moved. `release.yml` is read from the tagged
commit, so the fix from [01-macos-path-remap](../01-macos-path-remap/plan.md)
becomes the workflow only when the tag points at the fixed head.

Two outward actions are involved: pushing the fix to `develop` and
force-updating the tag. Both need the user's explicit go-ahead, and the tag move
is allowed only while no release page exists. The normal `ci.yml` must be green
on the exact head first: it has no macOS job, but a release must not be built
from a commit whose ordinary gate is red.

## Steps

1. Check the premise before anything leaves the machine: the first run is
   `completed`/`failure`, no `release.yml` run is in progress, and
   `gh release view v2.3.0-beta` reports that the release does not exist. If a
   release page exists, stop and report: replacing its assets is a separate
   user decision, not a tag move. If a run is still in progress, wait for it or
   ask for permission to cancel it; a run finishing after the move could publish
   the old commit under the tag name.
2. Confirm the change to publish: the lead has committed the script and
   `release.yml` change from [01](../01-macos-path-remap/plan.md) on top of the
   local map commits, `git status --porcelain` is empty, and
   `git log --oneline` shows that fix above `21d5446`. The tracked
   `macos/Runner/Libraries/slipstream-client` is unchanged.
3. With the lead's and the user's go-ahead, push `develop` as an ordinary
   fast-forward (no force). Verify that `git ls-remote origin
   refs/heads/develop` returns the pushed head.
4. Wait for the normal `ci.yml` run on that exact head and require all four jobs
   green (`aar`, `slipstream-android`, `test`, `build-android`); record the run
   id. A red run stops this task: no tag move, and the failure is reported for
   re-planning.
5. Ask for a separate explicit go-ahead for the tag move, naming what it
   covers: `git tag -f v2.3.0-beta <green head>` and
   `git push --force origin refs/tags/v2.3.0-beta`, plus, only if GitHub starts
   no run for the updated tag, deleting and re-pushing the same tag at the same
   commit. Do not move the tag before the answer.
6. Re-check the premise of step 1 cheaply, then move the tag. Keep it
   lightweight: `git cat-file -t v2.3.0-beta` prints `commit`, not `tag`.
   Verify `git ls-remote --tags origin refs/tags/v2.3.0-beta` returns the new
   commit and no peeled `^{}` line. The old run must not be rerun: it is
   terminal, and rerunning it would rebuild the old commit.
7. Confirm the new run with `gh run list --workflow release.yml --limit 1`:
   a `Build and Release` run for the tag at the new head, distinct from the old
   run's id. If none appears after a short wait, use the delete-and-re-push
   fallback the go-ahead covered, then confirm again. If still no run appears,
   stop and report: the workflow trigger or the tag state needs the lead's
   attention, and guessing with more remote writes is not allowed.
8. Follow the new run to its conclusion. On green: `create-release` succeeded
   and `gh release view v2.3.0-beta` lists the five assets under the README
   names; record the run id and asset names for
   [03-verify-artifacts](../../03-verify-artifacts/plan.md) and
   [05-release-notes](../../05-release-notes/plan.md). On red: read the first
   failing job and step and its first real cause, not a later symptom, and
   record the failing job, step and cause in the report without retrying or
   pushing anything else. The stage is then re-planned from that log; a further
   fix is a new node, and another tag move needs a new go-ahead.

## Done when

- At the moment of the move the first run was terminal, no release page existed
  and no release run was in progress.
- Remote `develop` is the fix head and `ci.yml` on that exact head is green
  (all four jobs), with its run id recorded.
- `v2.3.0-beta` on the remote is a lightweight tag at that head, with no peeled
  entry, moved only after the explicit go-ahead.
- A new `Build and Release` run for the tag started on that head and its result
  is known: either every job green and the release page carrying the five
  expected assets, or the failing job, step and first cause recorded for
  re-planning. No retry, release edit or further push was made without a new
  go-ahead.

## Risks and what is needed from the user

- The tag move rewrites published history and the green run publishes the page
  immediately (`draft: false`, `release.yml:562`); the user's go-ahead is asked
  after the green `ci.yml` is visible, and it covers only this one move.
- The old and the new run share the tag name; compare the run id and `headSha`,
  not the tag display name. The old run could not have published because
  `create-release` never started, but re-check rather than assume.
- The macOS jobs take tens of minutes and may fail again. A new failure is a new
  node from its log; it is not grounds for weakening the path check, skipping
  signing or dropping a platform. Dropping a platform changes the stage's "Done
  when" and is the user's decision.
- If a release page appears, stop: replacing a tag or an asset that users may
  already have downloaded is a separate user decision.
- The `workflow_dispatch` trigger builds the default branch and is not used
  here; the tag is the only correct way to rerun the release.

## Open question

Steps 1–4 are done. The macOS remap fix is published: remote `develop` is
`f74e7d5` (the fix `c9019d0` above `21d5446`, with the tracked
`macos/Runner/Libraries/slipstream-client` unchanged), and the ordinary gate is
green on exactly that head: `ci.yml` run `42690405232`
(https://github.com/FreedomCats/dnstt_xyz_app/actions/runs/42690405232) is
`completed`/`success` with all four jobs green — `aar`, `slipstream-android`,
`test`, `build-android`.

The remote tag `v2.3.0-beta` still points at `21d5446`, the first run
`42682231223` is still the only `release.yml` run and remains terminal
`failure`, and no release page exists. Waiting for a separate explicit
go-ahead that covers only this move: `git tag -f v2.3.0-beta f74e7d5` and
`git push --force origin refs/tags/v2.3.0-beta`, and then following the second
`Build and Release` run for the tag, which publishes the release page when
green. The old run is not rerun; nothing else is pushed, dispatched or
cancelled.
