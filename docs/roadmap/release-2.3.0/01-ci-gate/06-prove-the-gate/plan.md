---
kind: task
status: todo
depends: [03-full-dart-suite, 04-go-vet, 05-analyzer-gate]
---

# Prove that the gate fails on a broken change

## Task

A check nobody has seen fail may be green for the wrong reason. Break the
analyzer, a Dart test and `go vet` one at a time with temporary commits, watch
CI go red on the expected step, and remove the temporary commits.

## Done when

- A CI run failed on each of the three steps, with the deliberate finding as
  the failure message.
- A green CI run with all three checks exists after the temporary commits are
  gone, and no temporary commit is left in `develop`.
- The `## Outcome` names each run and the step it failed on.

## Outcome
