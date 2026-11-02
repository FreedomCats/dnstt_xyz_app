---
kind: stage
status: in-progress
base: 4c5277994585241777ed37136bcfdeaa4c4071aa
---

# CI gate: analyzer and the full test suite

## Goal

CI catches what the developer would catch by hand, before the release depends
on it. Today `ci.yml` does not run `flutter analyze`, and its `flutter test`
either does not cover the whole tree or is not green because of the stale
`test/widget_test.dart` (see `CLAUDE.md`, "Run the tests": the baseline has one
error in that file and about 110 infos).

## What to do, what is touched

- Replace `test/widget_test.dart` with a smoke test that still means something.
- Run `flutter test` on the whole tree and make it green.
- Run `flutter analyze` in CI and decide the baseline: the ~110 existing infos
  either get fixed or are pinned (a rule set in `analysis_options.yaml`, a
  saved baseline) so that a new issue fails the build.
- `go vet` on the packages that pass today (`go_src/noise` does not, see
  `CLAUDE.md`).
- `.github/workflows/ci.yml`, `analysis_options.yaml`, `test/`.

Children, in order:

1. [01-smoke-test](01-smoke-test/plan.md) (task): a start-screen widget test
   replaces the counter template.
2. [02-analyzer-baseline](02-analyzer-baseline/plan.md) (stage): the
   existing findings are handled the way the user decides.
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

The analyzer baseline can hide new issues. The user decides whether the
existing infos are fixed now, pinned by a baseline file, or narrowed by a rule
set. `docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md`, section 5.3, describes a
recorded count; any other choice changes that text. Children 2 and 5 wait for
this decision.

The per-rule numbers are not known yet: only a `flutter analyze` run gives
them. Grep finds 66 `print` calls and 25 `withOpacity` calls in `lib/`, which
agrees with "mostly `avoid_print`" but does not replace the measurement.

`pubspec.lock` is not in git and `flutter_lints` is `^6.0.0`, so the rule set
can change between two runs of the same commit.
