---
kind: task
status: todo
---

# Vet the Go packages in CI

## Task

`ci.yml` runs `go test ./...` but not `go vet`. `go vet ./...` in `go_src`
fails only on two `t.Fatal` calls in goroutines in upstream test code
(`go_src/noise/noise_test.go:158` and `:209`); the other eight packages pass.
CI vets every package but `noise`, and a package added later is covered
without a change to the workflow.

## Done when

- The `test` job of `ci.yml` has a `go vet` step that covers every package
  except `noise`, without a hand-written package list, and a comment gives the
  reason for the exclusion.
- The step is green on the current tree.
- `go_src/noise/noise_test.go` is unchanged.

## Outcome
