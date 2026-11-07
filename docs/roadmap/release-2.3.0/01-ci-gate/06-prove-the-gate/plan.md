---
kind: task
status: done
detailed: true
depends: [03-full-dart-suite, 04-go-vet, 05-analyzer-gate]
---

# Prove that the gate fails on a broken change

## Task

A check nobody has seen fail may be green for the wrong reason. Demonstrate
three isolated failures in the normal `.github/workflows/ci.yml`: an enabled
Dart analyzer finding, a runtime Dart test failure, and a finding in the
explicit `Go vet` step. Finish with a green normal CI run on the restored tree.

Use one disposable validation branch, with ordinary probe-addition and removal
commits. Keep all six experimental commits outside `develop`; the final tested
tree must equal the reviewed baseline. The validation branch retains its
add/remove history. Publishing or deleting that branch needs explicit user
authorization after the local experiment is prepared and reviewed.

The baseline comes from
[03-full-dart-suite](../03-full-dart-suite/plan.md),
[04-go-vet](../04-go-vet/plan.md) and
[05-analyzer-gate](../05-analyzer-gate/plan.md): plain `flutter analyze` is
clean, all 75 Dart tests pass, and the dynamic vet selection excludes only the
exact `noise` package. Node 05's green CI and local analyzer rejection establish
the starting point; they do not replace this task's red CI evidence. Preserve
the accepted rule set from
[02-analyzer-baseline](../02-analyzer-baseline/plan.md), which supersedes the
count-baseline proposal in `docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md`, section 5.3.
Documentation alignment belongs to
[07-describe-the-gate](../07-describe-the-gate/plan.md).

## Steps

1. Record baseline `B`, the clean, reviewed `develop` head after the lead has
   committed this plan, and record its tree ID. Keep the primary worktree on
   `develop` for persistent roadmap work. Create an isolated local worktree
   starting at `B`, with an unused neutral branch name such as `ci-gate-probes`;
   perform all checks and probes there. Check that `ci.yml` still runs
   `Dart analysis`, `Dart tests`, `Generate Gradle wrapper`, `Kotlin unit tests`,
   `Go tests`, then `Go vet`; `test` needs `aar`, and `build-android` needs both
   `aar` and `test`. Use the existing Flutter 3.38.7 and Go 1.26.10 toolchains.
   Confirm clean plain `flutter analyze`, the full `flutter test` (75 passing
   tests in four files), and `go test ./...` from `go_src`. From `go_src`, also
   require the unchanged CI vet command to pass and confirm its selection
   includes `dns` and excludes only `noise`:

   ```sh
   set -euo pipefail
   noise_package=$(go list ./noise)
   go list ./... | grep -Fvx "$noise_package" | xargs -r go vet
   ```

   Local commands must preserve CI's analyzer and vet behavior, including
   implicit vet inside `go test`. If the baseline fails unexpectedly, report
   the actual failure before preparing a probe; do not repair unrelated code
   or weaken checks in this task.
2. Prepare this linear local history, using the symbolic labels below in the
   evidence record and recording the actual SHA of each commit:

   | Commit | Tree relative to `B` |
   |---|---|
   | `A` | Only the analyzer probe is added. |
   | `A-clean` | Analyzer probe removed; tree equals `B`. |
   | `T` | Only the Dart test probe is added. |
   | `T-clean` | Dart test probe removed; tree equals `B`. |
   | `V` | Only the Go vet probe is added. |
   | `V-clean` | Go vet probe removed; tree equals `B`. |

   Use ordinary removal commits, preserving this history. Never merge or
   cherry-pick any experimental commit into `develop`. No workflow, production
   code, existing test, analyzer configuration, dependency declaration or
   resolution policy needs a change. Follow `AGENTS.md` for every commit's
   identity, metadata, message and privacy review.
3. For `A`, add only `test/analyzer_gate_probe.dart` with:

   ```dart
   Object analyzerGateProbe() => new Object();
   ```

   Plain `flutter analyze` must report the enabled info-level
   `unnecessary_new` diagnostic in that file and exit non-zero. This is the
   same minimal finding established locally in node 05; `avoid_print` and
   `deprecated_member_use` are intentionally disabled and cannot serve as
   probes. Capture the diagnostic and exit status. Remove the file in
   `A-clean`; require clean plain analysis before proceeding.
4. For `T`, add only `test/ci_gate_probe_test.dart` with:

   ```dart
   import 'package:flutter_test/flutter_test.dart';

   void main() {
     test('CI gate rejects a failing Dart test', () {
       expect(true, isFalse, reason: 'CI_GATE_DART_TEST_PROBE');
     });
   }
   ```

   Require plain `flutter analyze` to pass first. Then run the full
   `flutter test` without file arguments: the new fifth file must be discovered
   and compile, its named test must fail at runtime with
   `CI_GATE_DART_TEST_PROBE` and the false-versus-true matcher diagnostic, and
   the existing 75 tests must pass. A compile error is not the intended
   evidence. Capture the output and exit status. Remove the file in `T-clean`;
   require clean analysis and the original 75 passing tests again.
5. For `V`, add only `go_src/dns/vet_gate_probe_test.go` with:

   ```go
   package dns

   import "sync"

   func ciGateVetProbe(_ sync.Mutex) {}
   ```

   This test-only, uncalled helper has no runtime side effects and is excluded
   from the normal gomobile/AAR build. Go 1.26.10's `cmd/go/internal/test/test.go`
   leaves `copylocks` out of `defaultVetFlags`, while explicit `go vet` runs it
   and includes test files. Thus a `printf` defect would be caught too early,
   whereas this probe can reach the intended CI step. Confirm the distinction
   locally rather than treating the source inspection as execution evidence:
   plain `flutter analyze` and all 75 Dart tests must pass; from `go_src`,
   unchanged `go test ./...` must exit 0, then the exact dynamic vet pipeline
   from step 1 must exit non-zero with
   `ciGateVetProbe passes lock by value: sync.Mutex` in
   `dns/vet_gate_probe_test.go`. Require this to be the only selected-package
   finding; a pipeline exit code propagated by `xargs` need only be non-zero.
   Do not add `-vet=off`, analyzer-selection flags, a wider exclusion, a build
   tag or a workflow workaround. If the preceding Go tests reject this probe,
   stop and report the toolchain/output mismatch to the lead before publishing.
   Remove the file in `V-clean`; require analysis, all 75 Dart tests, full Go
   tests and the unchanged filtered vet pipeline to pass again.
6. Prepare the complete local result for coordinator review before requesting
   external actions. Each negative tree must differ from `B` by exactly its
   one probe file; `git diff --exit-code B <clean-sha>` must pass for all three
   removal commits, and `V-clean` must have `B`'s tree ID. Use actual recorded
   SHAs in these comparisons. Inspect all six commit diffs and metadata, not
   just the final empty diff. Run `git diff --check B <probe-sha>` for each of
   `A`, `T` and `V`.
   Restore only incidental generated-plugin changes from Flutter checks,
   preserving pre-existing work; do not commit generated files or a lockfile.
   Give the reviewer the probe diffs, expected diagnostics, actual local
   command results, six SHAs, baseline/tree comparison and cleanup evidence.
   Keep raw logs and working evidence under ignored `docs/local/`; published
   summaries follow `AGENTS.md`. If interrupted, leave an exact resume point
   with the lead and keep every probe confined to the isolated worktree.
7. After local review, have the lead obtain user authorization for the exact
   external sequence: four ordinary, single-ref pushes of the reviewed SHAs
   `A`, `T`, `V`, then `V-clean` to the named temporary branch in the existing
   repository, with observation of their push-triggered `ci.yml` runs. First
   check read-only that the proposed remote branch does not already exist;
   resolve any name collision before requesting approval. Include
   any previously unpushed baseline/documentation ancestors in that request,
   and explain that normal CI builds and uploads AAR/APK artifacts and may use
   its existing signing secrets. Earlier push grants are consumed; no new
   publication or remote deletion is currently authorized. Do not push only
   the final head: intermediate ancestors do not each receive a push-triggered
   CI run. A later push of `develop`, a rerun or any extra remote write needs
   authorization covering that action. If approval is unavailable, report the
   prepared local result and leave the remote completion criteria pending.
8. Once authorized, push `A`, wait for and inspect its completed normal CI run,
   then do the same for `T`, `V` and `V-clean` in order. Each update is a
   fast-forward along the prepared branch; the pushes of `T` and `V` also carry
   the preceding removal commit. For every run, verify workflow `ci.yml`, event
   `push`, the validation branch and the exact expected head SHA. Require this
   evidence from the actual step logs and job conclusions:

   | Head | Required result |
   |---|---|
   | `A` | `aar / build` passes; `Dart analysis` fails with `unnecessary_new` in `test/analyzer_gate_probe.dart`. Later checks in `test` and `build-android` are skipped. |
   | `T` | `aar / build` and `Dart analysis` pass; `Dart tests` discovers the new file and fails only its runtime probe, naming the test and `CI_GATE_DART_TEST_PROBE`. Existing 75 tests pass; subsequent checks and `build-android` are skipped. |
   | `V` | `aar / build`, `Dart analysis`, the original 75 Dart tests, Kotlin unit tests and `Go tests` pass; the explicit `Go vet` step fails with the recorded lock-copy diagnostic in `dns/vet_gate_probe_test.go`. `build-android` is skipped. |
   | `V-clean` | The entire workflow succeeds: `aar / build`, `test` and `build-android`, including clean analysis, all 75 Dart tests, Kotlin/Go tests, filtered Go vet, AAR/APK builds and machine-path checks. |

   The first three runs must conclude `failure` for the deliberate reason. An
   infrastructure error, a failure in an earlier step, a skipped target check,
   an unrelated finding or a cancelled run does not count. Record and report
   such a result without changing workflow behavior, rules or dependencies.
   Match test identities, counts and diagnostic content rather than one
   reporter's formatting. Local checks and the earlier green run cannot
   substitute for any row.
9. Recheck that `V-clean` has `B`'s exact tree and that all three probe files
   are absent both there and in `develop`. Verify none of the six experimental
   commits is an ancestor of `develop` (each
   `git merge-base --is-ancestor <experimental-sha> develop` must exit 1), and
   inspect any persistent changes since `B` as roadmap bookkeeping only. This
   establishes final green CI after probe removal while retaining ordinary
   `develop` history: the green criterion names no required branch, and the
   validation branch tests the restored baseline with the identical workflow.
   No additional `develop` push is needed for this evidence. Give the
   coordinator the four run IDs/attempts, head SHAs, branch, failed step and
   diagnostic for each red run, complete green results, local review and
   tree/ancestry checks for the task's Outcome. The lead owns the journal.
   Delete the remote validation branch only if that exact deletion is
   separately authorized or expressly included in the approved sequence;
   otherwise report it as retained. Branch deletion does not guarantee erasure
   of published commits or logs. Preserve the evidence and make no promise to
   rewrite or erase remote history.

## Done when

- Three distinct normal push-triggered `ci.yml` runs for the reviewed negative
  SHAs fail respectively at `Dart analysis`, `Dart tests` and explicit `Go vet`,
  with the exact probe file and expected diagnostic/test marker in the logs.
  Each run passes its prerequisites; in particular, analysis passes before the
  runtime Dart failure, and full Go tests pass before the explicit vet failure.
- After all probes are removed, a fourth normal `ci.yml` run for `V-clean`
  succeeds in all three jobs and all existing checks. Its tested tree is
  byte-for-byte identical to `B`; analysis is clean, the original 75 Dart tests
  pass, full Go tests and the exact filtered vet pipeline pass, and the normal
  AAR/APK builds and path checks succeed.
- Local review confirms the same isolated failure/removal behavior. The only
  experimental source changes are the three specified disposable probe files;
  all three removal trees equal `B`. Workflows, production code, existing
  tests, analyzer rules and dependency policy are unchanged.
- No probe file or experimental commit is present in `develop`; the primary
  worktree is back to normal roadmap work with no probe/generated-file diff.
  Tree comparisons and all six ancestry checks establish this. Remote branch
  retention or explicitly authorized deletion is recorded without claiming
  that published history has been erased.
- The coordinator's `## Outcome` names the baseline and final tree comparison,
  local checks/review, each run/attempt and head SHA, each failing step and
  diagnostic, the final green jobs and cleanup. Remote evidence is required
  before the task can be marked done.

## Risks and what is needed from the user

- Local preparation and review come first; the lead then asks for the exact
  branch publications and normal CI side effects. Use the already verified
  authentication and repository target. Additional credential/scope changes,
  remote branch deletion and later `develop` pushes require their own explicit
  coverage. No force push, reset/rebase of published history, tag, PR, manual
  workflow dispatch or `release.yml` execution is part of this task.
- Go tests run a restricted automatic vet before the explicit vet step. The
  `copylocks` probe and test-only placement address this ordering and the AAR
  prerequisite; confirm both through the specified local checks and actual CI.
  An unexpected earlier rejection is a blocker, not evidence of the requested
  explicit vet failure.
- `pubspec.lock` is ignored and `flutter_lints` is a version range; dependency
  resolution can change findings. Report drift without changing dependencies,
  disabling another rule, using fatality flags or introducing a count baseline.
- Use existing local tools. No new SDK installation, agreement acceptance,
  local release build, live server or device access is needed. The four full
  remote runs can be slow because every run rebuilds the AAR; retain exact-SHA
  evidence so a continuation does not repeat an authorized external action.

## Outcome

Local preparation, review and all four normal CI runs are complete. The three
isolated probes fail at their intended checks, and the restored baseline passes
the entire workflow. The authorized sequence used four ordinary single-ref
pushes, each inspected to completion before the next, followed by deletion of
the temporary remote ref after the final successful run.
Baseline `B` is `7f47d452bd5321fdb9d90255d1e800c20bde4d49`, with tree
`322ebbe43fdedb41a05dbbbadf7dec9da8d3a56d`.

The isolated validation branch `ci-gate-probes` retains six linear ordinary
commits outside `develop`:

| Label | Commit | Result |
|---|---|---|
| `A` | `e160ac192d1e33ad5aaca8cbb74d50f70f61f7b9` | Adds only `test/analyzer_gate_probe.dart`. Plain `flutter analyze` exits 1 with the single enabled `unnecessary_new` info at `test/analyzer_gate_probe.dart:1:31`. |
| `A-clean` | `b99be951d6806c802f614111c81a78398eea3ed6` | Removes the analyzer probe; tree equals `B`. |
| `T` | `1decaba2425765c2b8dda01d14decba8f069b5d4` | Adds only `test/ci_gate_probe_test.dart`. Analysis exits 0; the full test command exits 1 after discovering the fifth file. The only failure is the named probe with `CI_GATE_DART_TEST_PROBE`, `Expected: false`, and `Actual: <true>`; the existing 75 tests pass. |
| `T-clean` | `59d7f0138f113b6660a7fbc8d3dd5e0d25330c2b` | Removes the Dart test probe; tree equals `B`. |
| `V` | `99cad38eee1414e0a5db9bd0c3575f1e9199954f` | Adds only `go_src/dns/vet_gate_probe_test.go`. Analysis, the full Dart suite, and unchanged `go test ./...` exit 0 before the exact filtered vet pipeline exits 123 with the sole diagnostic `dns/vet_gate_probe_test.go:5:23: ciGateVetProbe passes lock by value: sync.Mutex`. |
| `V-clean` | `d1be6f4145280a003c608557841c5425cff43d46` | Removes the Go vet probe; tree is exactly `322ebbe43fdedb41a05dbbbadf7dec9da8d3a56d`, equal to `B`. |

The baseline and every removal tree were compared by tree and full diff. Each
negative tree differs from `B` by exactly its one prescribed probe file. The
dynamic vet selection discovers nine packages, selects eight including `dns`,
and excludes only the exact `noise` package. The Go probe is test-only,
uncalled, and absent from production and gomobile inputs, so the preceding
test and AAR paths are not weakened. No workflow, analyzer rule, dependency,
production source, or existing test changed. Incidental generated-plugin
entries created by Flutter checks were restored before the final cleanup.

Review inspected all six patches, commit metadata and recorded negative
results, and independently repeated the restored-green local checks. No
correctness, regression, privacy, or scope issue was found. No review finding
was rejected; the accepted cleanup restored two incidental generated-plugin
entries. No real problem was deferred or narrowed because of repair cost.
Exact command output and status records remain in ignored task evidence.

The temporary remote branch was absent before its authorized creation. The
ordinary pushes also published documentation ancestors
`1ebaa4c56f4f2361b1ab8e751a88a90e31d616b5` and `B`. No `develop` push,
release, tag, dispatch, rerun or pull request was performed.

All four normal `.github/workflows/ci.yml` runs are terminal and verified, each
with event `push`, branch `ci-gate-probes`, attempt 1 and the exact head SHA
identified by its label in the commit table above:

| Head | Run | Verified result |
|---|---|---|
| `A` | [42409236838](https://github.com/FreedomCats/dnstt_xyz_app/actions/runs/42409236838) | `failure`: `aar / build` passes; `Dart analysis` fails only with the enabled info `unnecessary_new` at `test/analyzer_gate_probe.dart:1:31`, exit 1. Later checks and `build-android` are skipped. |
| `T` | [42409547044](https://github.com/FreedomCats/dnstt_xyz_app/actions/runs/42409547044) | `failure`: AAR and clean analysis pass; `Dart tests` discovers `test/ci_gate_probe_test.dart` and reports 75 passing tests and only the runtime failure `CI gate rejects a failing Dart test`, with `CI_GATE_DART_TEST_PROBE`, `Expected: false`, and `Actual: <true>`, exit 1. Later checks and `build-android` are skipped. |
| `V` | [42410023979](https://github.com/FreedomCats/dnstt_xyz_app/actions/runs/42410023979) | `failure`: AAR, clean analysis, all 75 Dart tests, Kotlin unit tests and full Go tests pass. The explicit `Go vet` step fails only with `dns/vet_gate_probe_test.go:5:23: ciGateVetProbe passes lock by value: sync.Mutex`, pipeline exit 123. `build-android` is skipped. |
| `V-clean` | [42410803299](https://github.com/FreedomCats/dnstt_xyz_app/actions/runs/42410803299) | `success`: all three jobs and every existing check pass on the exact restored baseline tree. |

The verified job IDs and conclusions are:

| Head | `aar / build` | `test` | `build-android` |
|---|---|---|---|
| `A` | `128513550930`: success | `128513960885`: failure | `128514341016`: skipped |
| `T` | `128514485102`: success | `128514907052`: failure | `128515344495`: skipped |
| `V` | `128515929584`: success | `128516262215`: failure | `128517821690`: skipped |
| `V-clean` | `128518308287`: success | `128518671955`: success | `128520153209`: success |

The final AAR log confirms the build, `ok` machine-path checks for the native
libraries of all three ABIs, checksums and artifact upload. The final test log
confirms plain `flutter analyze` with `No issues found!`, all 75 Dart tests in
the original four files, Gradle wrapper generation, Kotlin unit tests, full
`go test ./...` and the unchanged dynamic vet pipeline. The Android log confirms
release APK builds for `armeabi-v7a`, `arm64-v8a` and `x86_64`, successful
machine-path checks under the existing CI allowance, signing-certificate
verification and upload of all three APKs. The run has both `dnstt-aar` artifact
`13589347474` and `android-apks` artifact `13590120801`, tied to the exact
`V-clean` SHA. The remote workflow blob matches the reviewed local workflow.

After the final green result was inspected, the authorized ordinary deletion
removed only `refs/heads/ci-gate-probes`; a read-only remote-ref query confirms
its absence. Remote `develop` remains at
`a7cb5062f4a702108c59023567d3e1fd4075eff6`. The local validation branch and
worktree remain intact and clean at `V-clean`, retaining the ordinary add/remove
history. Removing the remote ref does not erase published commits or CI logs.

Final full diffs and tree comparisons confirm that all three removal commits
still equal `B`, including `V-clean` tree
`322ebbe43fdedb41a05dbbbadf7dec9da8d3a56d`, also verified through the remote
commit API. All six `merge-base --is-ancestor` checks against `develop` return
1. All three probe files are absent from both branch trees and worktrees.
Since `B`, only this task's roadmap bookkeeping has changed in `develop`; no
workflow, production code, existing test, generated file or probe diff remains.
