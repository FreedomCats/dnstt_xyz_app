---
kind: stage
status: done
base: 4c5277994585241777ed37136bcfdeaa4c4071aa
---

# CI gate: analyzer and the full test suite

## Goal

CI catches what the developer would catch by hand, before the release depends
on it. At the start of this stage, `ci.yml` did not run `flutter analyze`, its
Dart test selection missed the counter-template failure, and the tree had about
110 analyzer findings. The children replace that starting state with a verified
gate and current development instructions.

## What to do, what is touched

- Replace `test/widget_test.dart` with a smoke test that still means something.
- Run `flutter test` on the whole tree and make it green.
- Run plain `flutter analyze` in CI under the accepted narrowed rule set:
  centrally disable `avoid_print`, ignore `deprecated_member_use`, and fix
  the remaining findings so a new enabled finding fails the build.
- `go vet` on the packages that pass today (`go_src/noise` does not, see
  `CLAUDE.md`).
- `.github/workflows/ci.yml`, `analysis_options.yaml`, `test/`.

Children, in order:

1. [01-smoke-test](01-smoke-test/plan.md) (task): a start-screen widget test
   replaces the counter template.
2. [02-analyzer-baseline](02-analyzer-baseline/plan.md) (task): the existing
   findings are handled the way the user decides — narrow the rule set until
   `flutter analyze` is clean with no flags.
3. [03-full-dart-suite](03-full-dart-suite/plan.md) (task): CI runs
   `flutter test` without a file list.
4. [04-go-vet](04-go-vet/plan.md) (task): CI vets every package but
   `go_src/noise`.
5. [05-analyzer-gate](05-analyzer-gate/plan.md) (task): CI runs the analyzer.
6. [06-prove-the-gate](06-prove-the-gate/plan.md) (task): each check is seen
   failing on a broken change.
7. [07-describe-the-gate](07-describe-the-gate/plan.md) (task): `CLAUDE.md`
   describes the gate as it is.

## Done when

- `ci.yml` runs `flutter analyze`, the full `flutter test` and `go vet`, and
  the run is green.
- A deliberately broken analyzer rule or a deliberately failing test fails the
  build, checked by a temporary commit that is reverted afterwards.
- `CLAUDE.md` ("Development workflow") stops describing the analyzer baseline
  as a known broken state.

## Depends on

Nothing.

## Risks and what is needed from the user

The user chose to narrow the central rule set rather than fix every noisy
finding or compare counts. [Node 02](02-analyzer-baseline/plan.md) records the
measured 109 findings, the two central exceptions with their reasons, and fixes
for all other measured findings. Plain analysis is clean with fatal infos and
warnings enabled by default; there is no outstanding baseline choice.

[Node 06](06-prove-the-gate/plan.md) records actual expected CI failures for
analysis, runtime Dart tests and explicit Go vet, followed by a full successful
run on the restored tree. The temporary probes never entered `develop`.

`pubspec.lock` is not in git and `flutter_lints` is `^6.0.0`, so the rule set
can change between two runs of the same commit.

## Outcome

The stage-wide integration review covered the complete cumulative range
`4c527799..c51f108` after the task commits and the documentation alignment. The
review found no functional regressions, privacy issues or scope problems, and
no code fix was required. The three stage criteria are met:

- `ci.yml` runs plain `flutter analyze`, the full Dart suite and the exact
  dynamic Go vet selection, and the normal workflow is green. The final run for
  the published head was `42495583354`: AAR build, test and Android build jobs
  all passed. Its test job passed analysis, all 75 Dart tests, Kotlin unit
  tests, full Go tests and filtered vet; its Android job built the split APKs,
  checked paths and signatures, and uploaded artifacts.
- The three disposable CI probes produced the intended failures at analyzer,
  runtime Dart test and explicit Go vet, followed by the restored-tree green
  run `42410803299`. Probe commits stayed outside `develop`, and the temporary
  validation ref was deleted after the green run.
- `CLAUDE.md` and the architecture document describe the implemented gate,
  including the full test discovery, strict analyzer policy and the single
  upstream `noise` vet exclusion.

Fresh local integration checks also passed. The forced Gradle command
`./gradlew --offline -Dcom.android.build.gradle.internal.SdkLocator.sdkDownload=false
--rerun-tasks :app:testDebugUnitTest` executed 146 tasks and passed 11 Kotlin
tests with no failures, errors or skips. The ARM64 debug APK build completed
successfully. Flutter-created entries in the Linux and Windows generated plugin
files were restored exactly to `HEAD`; no source, generated or configuration
diff remains. No release build was run.

The user-approved rewrite changed the English bodies of two historical smoke
test commits while preserving every affected tree, author, committer, date and
required trailer. The rewritten `develop` history was published with an exact
force-with-lease, and the remote head now matches local `c51f108`. No other ref
was changed.

Real problems not fully fixed because of cost: none. The pre-existing
`HomeScreen` VPN-state subscription lifetime issue remains outside this stage
and was not introduced by the stage changes.
