---
kind: task
status: todo
depends: [02-analyzer-baseline]
---

# Run the analyzer in CI

## Task

No workflow runs `flutter analyze`. Add it to the `test` job of `ci.yml`, in
the form that follows from the user's decision in `02-analyzer-baseline`,
so that a new finding fails the build.

## Done when

- The `test` job of `ci.yml` has an analyzer step and it is green on the
  current tree.
- A finding added on purpose makes the same command exit non-zero locally;
  the change is reverted.
- What the step does with infos is stated by the command itself or checked
  with `flutter analyze --help` on Flutter 3.38.7, not assumed.

## Outcome
