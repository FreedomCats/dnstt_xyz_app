---
kind: stage
status: blocked
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

## Acceptance blocked

The stage-wide review found no functional regressions and its declared gate
criteria are supported by the completed task evidence. Final acceptance is
pending a decision on the fresh local Android integration check. The configured
SDK already contains platform 36, build-tools 35.0.0, NDK 28.2.13676358 and
platform-tools; only platform 34 is missing. The SDK directory is not writable
by the current user, so that package was not installed. Existing green CI and
the earlier successful local debug APK build remain valid evidence; no further
SDK installation has been performed.

The two smoke-test commit bodies were rewritten in English in the local branch.
Their trees, authors, dates and required trailers are unchanged. The user
authorized publishing the rewritten branch history; this does not change the
Android-check blocker.
