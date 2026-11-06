---
kind: task
status: done
detailed: true
depends: [01-smoke-test]
---

# Run the whole Dart suite in both workflows

## Task

`ci.yml` and `release.yml` still pass three Dart test file paths explicitly and
retain comments about the removed `test/widget_test.dart`. This excludes the
new `test/app_smoke_test.dart` and any future test file from those workflow
steps. Let Flutter discover and run the full Dart suite in both workflows.

## Steps

1. In `.github/workflows/ci.yml`, remove the stale-test comment above the
   `Dart tests` step and change its command to exactly `flutter test`, with no
   file arguments. Keep the step name, dependency setup, job dependencies and
   all other CI checks unchanged.
2. In `.github/workflows/release.yml`, make the same change to its `Dart tests`
   step: remove the stale-test comment and use exactly `flutter test`. Leave
   the release triggers, signing, build and publication steps unchanged. Do
   not edit `CLAUDE.md`; its test instructions are handled by
   `07-describe-the-gate`.
3. Run `flutter test` locally with no arguments. Confirm that all four current
   test files pass, including `test/app_smoke_test.dart`. Review the diff to
   ensure changes caused by dependency resolution, including generated plugin
   files noted in `CLAUDE.md`, are not included in this task's diff.
4. After the workflow change is available to GitHub Actions, inspect a normal
   `ci.yml` run. Confirm the `Dart tests` step executes the smoke test and
   passes, and that the overall CI workflow is green. Verify `release.yml` by
   inspecting its workflow definition; do not dispatch a release run just to
   test it, because it can publish a release.

## Done when

- `ci.yml` and `release.yml` run `flutter test` without file arguments.
- Neither workflow has a comment about the removed stale test.
- Local `flutter test` passes all four current Dart test files, including
  `test/app_smoke_test.dart`.
- A `ci.yml` run shows the smoke test passing in its `Dart tests` step, and the
  overall CI workflow is green.
- Outside the map, the task's diff touches only these two workflow files.

## Outcome

Both workflows now run `flutter test` without file arguments, and the stale
test comments have been removed. The local full Dart suite passed all 75 tests,
including `test/app_smoke_test.dart`; the diff passed `git diff --check`, and
review approved the changes. The normal GitHub Actions CI run passed after the
branch update, including the test and Android build jobs. The release workflow
was not run.
