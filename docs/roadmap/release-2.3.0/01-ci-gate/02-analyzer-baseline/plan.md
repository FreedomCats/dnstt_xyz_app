---
kind: task
status: todo
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
   `test/widget_test.dart`. Group by rule code, for example
   `dart analyze --format machine lib test | cut -d'|' -f3,4 | sort | uniq -c`,
   and record the counts per rule in the `## Outcome`. The grep estimates (66
   `print(`, 25 `withOpacity(`) are a starting point, not a substitute: only
   the analyzer knows the real breakdown.
2. Rewrite `analysis_options.yaml` to disable the rules that account for most
   findings. Start with `avoid_print` and `deprecated_member_use`, which the
   estimates put at 66 and 25. Keep `include:
   package:flutter_lints/flutter.yaml` and add a `linter: rules:` section
   that lists the disabled rules with a comment for each saying why it is off.
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
7. Check that `flutter analyze --help` on Flutter 3.38.7 confirms what
   `--fatal-infos` does by default. The stage assumes it is on, based on CI
   fix PRs; if it is not, the command for `05-analyzer-gate` adjusts. Write
   the finding into the `## Outcome`.
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
