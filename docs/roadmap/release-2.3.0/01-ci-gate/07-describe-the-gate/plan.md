---
kind: task
status: done
detailed: true
depends: [06-prove-the-gate]
---

# Describe the gate as it is in `CLAUDE.md`

## Task

Align `CLAUDE.md` ("Development Workflow") and section 5.3 of
`docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md` with the implemented, verified CI gate.
The guide still describes a broken analyzer baseline, a three-file Dart test
command and manual package selection for vet; the architecture still proposes
a finding-count baseline. These are obsolete instructions, not pending choices.

The accepted results of
[02-analyzer-baseline](../02-analyzer-baseline/plan.md),
[03-full-dart-suite](../03-full-dart-suite/plan.md),
[04-go-vet](../04-go-vet/plan.md),
[05-analyzer-gate](../05-analyzer-gate/plan.md) and
[06-prove-the-gate](../06-prove-the-gate/plan.md) establish the behavior:
plain `flutter analyze` is clean under the narrowed central rule set, both
workflows discover the full Dart suite, and `ci.yml` explicitly vets all Go
packages except the exact `noise` package. The intentional failures and restored
green CI run are already accepted; this task documents that result.

This is one documentation-only change, written, checked and committed directly
by the lead without a task coordinator or programmer. Besides the guide and
architecture, correct only the parent map prose that still presents the
analyzer decision as open or its original broken state as current. Preserve
parent goals, scope, acceptance criteria and frontmatter, and leave completed
children and historical reports unchanged.

## Steps

1. Cross-check the commands and policy against the implementation and completed
   Outcomes: `.github/workflows/ci.yml:51` (analysis before Dart tests),
   `ci.yml:68` (full Go tests followed by dynamic vet),
   `.github/workflows/release.yml:50` (full Dart tests), and
   `analysis_options.yaml:12` and `:27` (central rule configuration).
   Use node 06's recorded evidence for the deliberate red runs and final green
   run `42410803299` at `d1be6f4`; do not repeat the probes or start another run.
2. Rewrite the testing instructions in `CLAUDE.md`, keeping changes within
   "Development Workflow":
   - Replace the three-file `flutter test` command at `CLAUDE.md:545` with
     plain `flutter test` from the repository root, preceded by plain
     `flutter analyze`. Explain that discovery includes
     `test/app_smoke_test.dart`, which checks the empty start screen; the
     counter template `test/widget_test.dart` was removed.
   - Replace the manual-vet advice at `CLAUDE.md:525` and desktop-only vet
     example at `:548` with the exact Bash selection used by CI. Give the Go
     working directory explicitly and retain full `go test ./...` before vet:

     ```bash
     (
       set -euo pipefail
       cd go_src
       go test ./...
       noise_package=$(go list ./noise)
       go list ./... | grep -Fvx "$noise_package" | xargs -r go vet
     )
     ```

     Explain the exclusion in one sentence: the explicit vet step excludes
     `go_src/noise` because its upstream tests contain two `t.Fatal` calls from
     goroutines, which vet rejects. Make clear that full Go tests still include
     `noise`, discovery covers future packages, and the current vet selection
     covers eight of nine packages; do not advertise unfiltered `go vet ./...`
     as passing.
   - Split the prerequisite wording at `CLAUDE.md:542`: analyzer, Dart tests
     and Go checks do not need an AAR or APK build. Keep optional Android
     checks separate with their existing AAR/Gradle-wrapper prerequisites;
     show CI's full `./gradlew :app:testDebugUnitTest` rather than the existing
     single-class filter at `:546`. They are not required to run for this
     documentation task.
   - Replace the sorted-output/stashed-tree baseline advice at
     `CLAUDE.md:555` through its obsolete widget-test error description with
     the current zero-finding gate under `analysis_options.yaml`.
     `avoid_print: false` retains intentional service diagnostics;
     `analyzer.errors.deprecated_member_use: ignore` keeps API migrations in a
     separate change. All other measured findings were fixed, including all
     seven `use_build_context_synchronously` sites; there is no remaining
     analyzer allowance or count comparison. Flutter 3.38.7 defaults fatal
     infos and warnings to on, so the command needs no flags.
   - State workflow coverage precisely: `ci.yml` runs analysis before the
     full Dart suite and explicit vet after full Go tests; a failed check
     prevents its dependent Android APK job. `release.yml` also runs the full
     Dart suite and Kotlin unit tests, but has no analyzer or explicit Go vet
     step. Keep the generated-plugin warning at `CLAUDE.md:551` useful.
     If mentioning 75 tests in four files or old findings, label them as
     observed results or history, never fixed gate thresholds.
3. Rewrite architecture section 5.3 (`:401`) as the implemented CI design:
   replacement smoke test, full Dart discovery in both workflows, clean plain
   analysis in `ci.yml`, the two central rule exceptions with their reasons,
   and dynamic explicit vet with only the upstream `noise` exclusion.
   Remove the recorded-count proposal and the claim that CI still lists the
   old three files. Describe only the behavior verified in steps 1–2; do not
   extend the analyzer/vet claim to `release.yml`. Make the minimal qualifier
   adjustment to the section 5 introduction at `:341` so it no longer calls
   the completed CI gate unbuilt; leave sections 5.1, 5.2 and 5.4 unchanged.
4. Align only stale baseline/decision framing in the parent map documents:
   - In `docs/roadmap/release-2.3.0/plan.md`, stage 1's "What to do" (`:72`)
     and "Risks and what is needed from the user" (`:78`) must reflect the
     accepted narrowed rule set, rather than asking the user to choose a
     threshold. Leave other stages and root criteria unchanged.
   - In `docs/roadmap/release-2.3.0/01-ci-gate/plan.md`, qualify the original
     broken-tree description at `:12` as the stage's starting state. Replace
     the open baseline alternatives at `:21` and `:60`, the claim that
     children 2 and 5 wait for a decision, and the unknown-count/grep estimate
     at `:66` with the accepted choice and links to node 02's measured
     Outcome and node 06's verification. Keep the dependency-drift caveat at
     `:70` as a real risk. These edits clarify recorded state and decisions;
     they do not change the parent's goal or Done when.
5. After the documentation edits, the lead verifies the documented commands
   directly using the existing Flutter 3.38.7 and Go toolchain: run
   `flutter analyze` and full `flutter test` from the repository root, then
   `go test ./...` and the exact filtered vet pipeline from `go_src` as shown
   above. Require clean analysis, all 75 current Dart tests in four files,
   full Go tests and the eight-package vet selection to pass. Record command
   directories, results and exit statuses without publishing raw logs or
   local paths. Inspect for incidental generated-plugin or lockfile changes
   and retain no such diff, preserving any pre-existing work.
   Verify that changes since node 06's baseline `7f47d45` are Markdown only:
   its final green run supplies the accepted AAR/APK, Kotlin, path, signature
   and artifact evidence for unchanged executable/workflow inputs. Do not
   describe that run as CI of the later documentation-only commit. No fresh
   local AAR/APK/Gradle build, remote run or SDK installation is needed; the
   later stage integration acceptance remains separate.
6. Check the complete diff and run `git diff --check`. Search the edited
   current-instruction sections for the three-file command, stale-widget
   error, manual vet list and analyzer-count comparison; any retained
   reference must be explicitly historical. Apply `AGENTS.md`'s privacy
   review to every changed Markdown file: English, repository-relative paths,
   no work dates, local environment/home paths, people/account identifiers,
   live server/resolver/device data, secrets or raw logs. Limit the content
   diff to the guide, architecture section 5.3 and its introductory qualifier,
   the parent's obsolete framing, and this task's completion record.
7. The lead commits the checked text as documentation only, following
   `AGENTS.md`, and then fills this task's `## Outcome` with that revision,
   actual command results, scope/privacy checks and the reference to node 06's
   existing CI/build evidence. The lead owns task completion and the private
   journal; no separate coordinator or new external action is a prerequisite
   for accepting this documentation task.

## Done when

- `CLAUDE.md` gives root-level plain `flutter analyze` and `flutter test`,
  full Go tests from `go_src` and the exact Bash vet pipeline above. No current
  instruction lists Dart test files, treats the removed counter template as an
  outstanding error, recommends a manual vet package list, or compares
  analyzer findings with a saved count or stashed tree.
- The guide and architecture section 5.3 describe the accepted central
  `avoid_print` and `deprecated_member_use` exceptions and zero findings under
  the remaining rules. Fatal infos/warnings default to on in Flutter 3.38.7;
  no weaker flags, additional suppression or count-baseline policy is proposed.
  The full suite includes the start-screen smoke test; 75 tests in four files
  describes the verified current suite, not an acceptance cap.
- Both documents distinguish `ci.yml`'s analyzer and explicit Go vet from
  `release.yml`'s full Dart suite. The single-sentence upstream `noise` reason
  accompanies exact-package exclusion, dynamic discovery and unchanged full
  Go test coverage. Optional Android checks have separate prerequisites and
  show the full Kotlin unit-test command.
- The parent documents no longer present the analyzer choice as unresolved
  or the initial broken state as current. Their goals, scope, Done when and
  frontmatter are preserved; completed children and historical reports are
  untouched.
- The lead has run the four documented checks on the final documentation tree:
  clean `flutter analyze`, all 75 Dart tests in four files, full `go test ./...`
  and vet on all eight non-`noise` packages, all exiting 0. Node 06's accepted
  green run and a Markdown-only comparison since its baseline cover unchanged
  build inputs; no new APK build or remote execution is required for this task.
- Only the intended Markdown files change, `git diff --check` passes, the
  privacy review passes, and no generated-file, lockfile, code, workflow,
  configuration, script or test change remains. After the documentation-only
  commit, the lead records its revision and actual verification in Outcome.

## Risks and what is needed from the user

- No new user decision, credentials, network publication, device check or SDK
  installation is needed. The strict gate and the upstream-only vet exclusion
  are already settled; do not reopen them through documentation wording.
- `pubspec.lock` is ignored and `flutter_lints` is a version range. If fresh
  checks expose dependency drift or any unexpected failure, report the actual
  result to the lead rather than weakening the gate, changing dependencies or
  silently broadening this documentation-only task.
- Line references identify the pre-edit text; follow the named sections after
  reflow. Historical task text is evidence, not a current command reference.

## Outcome

Documentation revision `73031c0cbe4de87fc7dafa935fdffe0c8d4741fa` aligns
`CLAUDE.md`'s development instructions with the implemented gate: plain analyzer
and full Dart discovery, full Go tests followed by the exact dynamic vet
selection, and separate Android prerequisites with the full Kotlin unit-test
command. It distinguishes analyzer/vet coverage in `ci.yml` from the full
Dart/Kotlin suites in `release.yml` and explains the exact upstream `noise`
exclusion without narrowing Go test coverage.

Architecture section 5.3 now describes the accepted central rule exceptions and
zero findings under the remaining rules. Its section 5 qualifier and the parent
plans no longer present the starting analyzer state or the user's decision as
unresolved. Parent goals, acceptance criteria and frontmatter, other stages,
completed children and historical reports are unchanged.

On the documentation tree, root-level `flutter analyze` reported no issues and
exited 0; plain `flutter test` passed all 75 tests in four files and exited 0.
From `go_src`, full `go test ./...` and the unchanged filtered vet pipeline
both exited 0, with vet selecting all eight non-`noise` packages. Incidental
generated-plugin entries from Flutter were restored; no lockfile, test, source,
configuration or workflow change remains. `git diff --check`, instruction
cross-checks and the staged privacy review passed.

Every change since node 06's baseline `7f47d45` is Markdown only. Its accepted
green CI run `42410803299` supplies the AAR/APK, Kotlin, path, signature and
artifact evidence for unchanged executable inputs; it is not a CI run of the
later documentation revision. No new remote run, build, SDK installation,
credential change or publication was performed. Stage-wide integration
acceptance remains separate. No real problem was deferred because of repair
cost.
