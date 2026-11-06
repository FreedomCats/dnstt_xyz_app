---
kind: task
status: done
depends: [01-smoke-test]
detailed: true
---

# Narrow the analyzer rule set to make the tree clean

## Task

The tree reports about 110 infos, mostly `avoid_print` and
`deprecated_member_use` on `withOpacity`. The user chose to disable the noisy
rules in `analysis_options.yaml` rather than fix them: `avoid_print` would
silence logs that carry server addresses and domains, which is a privacy
decision outside this stage; `withOpacity` is a performance micro-optimisation.
Disabling these rules gives a clean `flutter analyze` with no flags, the
strictest gate.

This task measures the real distribution, disables the rules responsible for
most findings, and either fixes or accepts the rest so `flutter analyze` exits
0.

## Steps

1. Run `flutter analyze` on the tree after `01-smoke-test` removes
   `test/widget_test.dart`. Group findings by analyzer diagnostic code and
   record the counts per code in the `## Outcome`. The grep estimates (66
   `print(`, 25 `withOpacity(`) are a starting point, not a substitute: only
   the analyzer knows the real breakdown.
2. Rewrite `analysis_options.yaml` to disable the rules that account for most
   findings. Start with `avoid_print` and `deprecated_member_use`, which the
   measurements put at 69 and 30. Keep `include:
   package:flutter_lints/flutter.yaml`; configure lint rules under
   `linter: rules:` and analyzer diagnostic codes such as
   `deprecated_member_use` under `analyzer: errors:`, with a comment for each
   explaining why it is disabled.
   Do **not** add `// ignore:` or `// ignore_for_file:` comments to the code:
   a suppression belongs in the rule file, not scattered through the tree.
3. Run `flutter analyze` again. If it reports findings for other rules, decide
   for each: disable it if the rule is not wanted (with the reason in the
   YAML), or fix the findings if they are few and the fix is mechanical (for
   example `unused_import`). Do not leave a finding unfixed if it can be fixed
   in this task without changing behaviour. Record what was done with each
   rule in the `## Outcome`.
4. Stop condition: if the remaining findings after disabling the noisy rules
   are many and need design changes — for example 50+
   `use_build_context_synchronously` sites, each needing a `mounted` guard —
   do not fix them here and do not force them. Record the count, explain why
   they are not fixed, and report back. The stage then gets a child for them,
   or the user accepts that the gate will not cover that rule. This is the
   only case where the node stays a stage.
5. The goal is `flutter analyze` exiting 0 with no flags. Do not use
   `--no-fatal-infos` or `--no-fatal-warnings` to make it green: the user
   wants the strictest gate, and a flag would weaken it. Every finding either
   has its rule disabled in `analysis_options.yaml` or is fixed.
6. Run `flutter test` (all four files after `01-smoke-test`) to confirm the
   YAML change does not break the test step, and `flutter build apk --debug`
   to confirm the tree still compiles. Do not run these until
   `flutter analyze` is clean: a broken tree stays broken.
7. Check `flutter analyze --help` and the Flutter 3.38.7 command configuration
   to establish what `--fatal-infos` does by default. The stage assumes it is
   on, based on CI fix PRs; if it is not, the command for `05-analyzer-gate`
   adjusts. Write the finding into the `## Outcome`.
8. `flutter analyze` runs `pub get` and can rewrite
   `linux/flutter/generated_plugins.cmake` and
   `windows/flutter/generated_plugins.cmake`: revert them.

## Done when

- `flutter analyze` with no flags exits 0 on the tree.
- The `## Outcome` lists the per-rule counts from step 1 and what was done
  with each: disabled, fixed, or left (with the reason if left).
- `analysis_options.yaml` has a `linter: rules:` section with each disabled
  rule commented, and no rule is disabled without a recorded reason.
- `flutter test` passes all four files and a debug APK builds.
- The diff touches `analysis_options.yaml` and possibly a few files in `lib/`
  or `test/` if step 3 fixed mechanical findings; it contains no `// ignore`
  comment.

## Outcome

Re-running Flutter 3.38.7 analyzer on the pre-task tree reported 109 issues:
108 infos and one warning (`unused_element`). Per-rule counts were
`avoid_print` 69, `deprecated_member_use` 30,
`use_build_context_synchronously` 7, `unintended_html_in_doc_comment` 1,
`prefer_final_fields` 1, and `unused_element` 1. These counts sum to 109; the
`unused_element` diagnostic is the warning and the other 108 are infos.

Disabled `avoid_print` in `analysis_options.yaml`: existing service diagnostics
intentionally use `print`. Suppressed `deprecated_member_use` through
`analyzer.errors` rather than `linter.rules`, because it is an analyzer
diagnostic code, not a recognized lint rule; defer API migrations to a separate
change. Kept `use_build_context_synchronously` enabled and fixed all seven
occurrences with lifecycle guards. Fixed `unintended_html_in_doc_comment` by
escaping the angle-bracket placeholder, made `_testingDns` final, and removed
the unused `_importFromDnsttXyz` method. No findings remain, and no inline
ignores were added.

Flutter 3.38.7's `flutter analyze --help` confirms `--fatal-infos` defaults to
on; the command configuration sets `defaultsTo: true`. Thus `flutter analyze`
with no flags is the strict gate. It exits 0 with no issues.
`flutter test` passes all four test files (75 tests), and
`flutter build apk --debug` succeeds.
