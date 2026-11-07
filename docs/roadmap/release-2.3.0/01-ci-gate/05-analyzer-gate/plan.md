---
kind: task
status: done
detailed: true
depends: [02-analyzer-baseline]
---

# Run the analyzer in CI

## Task

Add `flutter analyze` to the existing `test` job of
`.github/workflows/ci.yml`, so a new finding under the accepted rule set fails
the job before the Dart tests and prevents the dependent Android build.

The user chose to narrow the rule set in
[02-analyzer-baseline](../02-analyzer-baseline/plan.md): `avoid_print` is
disabled, `deprecated_member_use` is ignored centrally, and all other findings
were fixed. Its Outcome establishes that plain `flutter analyze` is clean and
Flutter 3.38.7 treats infos as fatal by default. Use that command without flags
or a finding-count baseline. This implements the CI goal of
`docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md`, section 5.3, with the accepted
decision superseding its older count-baseline proposal.

The permanent implementation changes only `.github/workflows/ci.yml`.
[06-prove-the-gate](../06-prove-the-gate/plan.md) covers deliberately failing
CI runs; [07-describe-the-gate](../07-describe-the-gate/plan.md) covers the
documentation alignment.

## Steps

1. In `.github/workflows/ci.yml`, insert this step in `jobs.test.steps`
   immediately after `Get dependencies` (`flutter pub get`) and before
   `Dart tests` (`flutter test`):

   ```yaml
   - name: Dart analysis
     run: flutter analyze
   ```

   Run from the repository root, as the adjacent Flutter steps do. The existing
   `Setup Flutter` already selects Flutter 3.38.7. Preserve all setup steps and
   the remaining order: `Dart tests`, `Generate Gradle wrapper`,
   `Kotlin unit tests`, `Go tests`, `Go vet`. Preserve `test.needs: aar` and
   `build-android.needs: [aar, test]`. The new step must use ordinary failure
   propagation: no `continue-on-error`, conditional skip, output filter, or
   wrapper that discards its exit status.
2. Using the existing Flutter toolchain, check `flutter analyze --help` on
   Flutter 3.38.7 and confirm that fatal infos and warnings default to on,
   consistent with node 02's result. Run exactly `flutter analyze` from the
   repository root and require exit status 0 with no issues. Keep
   `analysis_options.yaml`, dependency declarations and resolution policy
   unchanged; do not use `--no-fatal-infos` or `--no-fatal-warnings`.
3. Prove the same command rejects an enabled info-level lint locally. Create
   a temporary, untracked `test/analyzer_gate_probe.dart` containing
   `Object analyzerGateProbe() => new Object();`. The included recommended
   lint set enables `unnecessary_new`; require `flutter analyze` to report
   that diagnostic at info level and exit non-zero. Do not use `avoid_print`
   or `deprecated_member_use` as the probe, since they are intentionally
   disabled. Remove the probe after the check, including if it fails to give
   the expected result. Never stage, commit or push the probe.
4. With the probe removed, rerun `flutter analyze` and the full `flutter test`
   without file arguments. Require clean analysis and all four current Dart
   test files to pass (75 tests). No permanent Dart test or production-code
   change is needed for this workflow insertion.
5. Inspect the complete diff and run `git diff --check` before local review.
   Check YAML indentation and placement under the existing `test` job. Outside
   the map, only the new step in `.github/workflows/ci.yml` may remain changed.
   Flutter's implicit dependency resolution can rewrite
   `linux/flutter/generated_plugins.cmake` and
   `windows/flutter/generated_plugins.cmake`; restore only incidental changes
   caused by these checks, preserving any pre-existing work. Include no probe,
   generated-file change, lockfile, analyzer-rule change, dependency update or
   change to another workflow.
6. After the concrete local change passes review, have the lead obtain separate
   authorization for the branch push needed for GitHub verification. No new
   push or workflow dispatch is currently authorized. Once an authorized push
   makes the reviewed change available to Actions, inspect the normal `ci.yml`
   run for that exact commit SHA: `Dart analysis` must execute
   `flutter analyze` and pass, the complete `test` job must pass, and the
   overall workflow must pass, including the AAR and Android build jobs.
   Record the checked SHA, run and results for the coordinator's Outcome and
   the private journal. A previous green run or local checks alone cannot
   satisfy this task's remote criterion; keep it open until that evidence is
   available. Do not dispatch `release.yml`, create tags or publish anything
   for this check.

## Done when

- The `test` job of `ci.yml` runs exactly `flutter analyze` from the repository
  root after `Get dependencies` and before `Dart tests`, with no failure
  suppression. Its existing checks and job dependencies are preserved.
- Local `flutter analyze` exits 0 with no issues; `flutter test` without file
  arguments passes all four current test files (75 tests).
- The temporary `unnecessary_new` finding makes the same `flutter analyze`
  command report an info and exit non-zero locally. The probe is removed, and
  analysis is clean again.
- `flutter analyze --help` on Flutter 3.38.7 confirms fatal infos and warnings
  default to on; the behavior is recorded with the verification results.
- A GitHub Actions `ci.yml` run for the reviewed commit containing this change
  shows the new analyzer step and the complete `test` job green on the current
  tree, and the overall workflow is green. The checked SHA and run are recorded;
  local or older CI results do not substitute for this run.
- Outside the map, the final diff changes only `.github/workflows/ci.yml` by
  adding the analyzer step, and `git diff --check` passes.

## Risks and what is needed from the user

- Remote verification needs a separately authorized branch push after local
  implementation and review. Prepare that concrete result first; do not infer
  permission from earlier pushes or mark the task done before CI passes.
- `pubspec.lock` is ignored and `flutter_lints` is a version range, so dependency
  resolution can expose new findings. Report an unexpected failure rather than
  weakening the gate, changing the accepted rules or pinning dependencies in
  this task.
- Use the existing toolchain. No new SDK packages, agreements, credentials or
  live-device checks are required by this change.

## Outcome

The `test` job now runs `Dart analysis` with plain `flutter analyze` immediately
after `Get dependencies` and before `Dart tests`, from the repository root.
Setup, subsequent checks, job dependencies and normal failure propagation are
preserved. Outside this plan, only the three-line insertion in `ci.yml` changes.

Local verification with Flutter 3.38.7 confirms that `--fatal-infos` and
`--fatal-warnings` both default to on. Plain `flutter analyze` reports no issues
and exits 0. A temporary untracked `unnecessary_new` probe produced one
info-level finding and exit 1; the probe was removed without entering the
index, and analysis was clean again. The full `flutter test` passes all four
test files (75 tests). The workflow structure check and `git diff --check`
pass. Local review approved the implementation and independently repeated clean
analysis and all 75 Dart tests. Analyzer rules, dependencies and other workflows
are unchanged; no generated-file changes remain.

Normal GitHub Actions [CI run `42399754193`](https://github.com/FreedomCats/dnstt_xyz_app/actions/runs/42399754193)
passed for reviewed commit `a7cb5062f4a702108c59023567d3e1fd4075eff6`, with
event `push` and branch `develop`. All three jobs (`aar / build`, `test` and
`build-android`) passed. The `Dart analysis` log confirms `flutter analyze`
and `No issues found!`; the full Dart suite reports 75 tests passed in all four
test files. Kotlin unit tests, Go tests and Go vet passed, as did AAR and APK
builds, machine-path checks and artifact uploads. The remote workflow source
matches the reviewed local file. No analyzer rules or dependencies were changed
to obtain this result, and `release.yml` was not run.
