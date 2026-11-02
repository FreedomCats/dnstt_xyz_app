---
kind: task
status: todo
depends: [01-smoke-test]
---

# Run the whole Dart suite in both workflows

## Task

`ci.yml` and `release.yml` run three Dart test files by name because of the
stale `test/widget_test.dart`, so a new test file does not run. With the stale
file gone, both workflows run the whole suite.

## Done when

- `ci.yml` and `release.yml` run `flutter test` without file arguments.
- Neither workflow has a comment about a stale test.
- The "Dart tests" step of a CI run is green and includes the smoke test.
- Outside the map, the task's diff touches only these two workflow files.

## Outcome
