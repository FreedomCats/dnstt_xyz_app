---
kind: task
status: in-progress
detailed: true
---

# Vet the Go packages in CI

## Task

`ci.yml` runs `go test ./...` but not `go vet`. `go vet ./...` in `go_src`
fails only on two `t.Fatal` calls in goroutines in upstream test code
(`go_src/noise/noise_test.go:158` and `:209`); the other eight packages pass.
CI vets every package but `noise`, and a package added later is covered
without a change to the workflow. `go_src/go.mod` is the module root, and
`go list ./...` discovers its packages. Filtering out the exact import path of
the `noise` package leaves the other packages without a hand-written package
list.

## Steps

1. In `.github/workflows/ci.yml`, add a `Go vet` step to the existing `test`
   job after `Go tests`. Keep its `working-directory: go_src`; the earlier
   `Setup Go` step provides the module's toolchain. Do not change other jobs,
   steps, or workflow files.
2. In the new step, use a shell pipeline to discover and vet packages
   dynamically, for example:

   ```sh
   set -euo pipefail
   noise_package=$(go list ./noise)
   go list ./... | grep -Fvx "$noise_package" | xargs -r go vet
   ```

   Resolve the exact excluded import path with `go list ./noise`, then use
   `grep -Fvx` to remove only that whole line. `pipefail` keeps package
   discovery failures visible, and future packages remain covered
   automatically. `xargs -r` avoids invoking `go vet` without package
   arguments; if the filter leaves no packages, `grep` fails the step instead
   of reporting success without vetting anything. Add a YAML comment explaining
   that `noise` is excluded because its upstream test calls `t.Fatal` from
   goroutines, which `go vet` flags.
3. Do not edit, suppress, or otherwise change `go_src/noise/noise_test.go` or
   other Go source. The upstream test issue is intentionally outside this
   task's scope.
4. Check the diff: outside this plan, only `.github/workflows/ci.yml` may
   change. Confirm the vet step uses dynamic discovery and excludes the
   exact `noise` import path rather than relying on a fixed package list.
5. Verify the new step in a subsequent `ci.yml` run. The previously green run
   predates this step and does not verify it; do not run `release.yml` for this
   check.

## Done when

- The `test` job of `ci.yml` has a `Go vet` step that discovers packages with
  `go list ./...`, excludes only the exact import path returned by
  `go list ./noise`, vets every other discovered package, and has a comment
  explaining the upstream test issue.
- The `Go vet` step and the overall `ci.yml` run are green on the current tree.
- No Go source or test is changed; in particular,
  `go_src/noise/noise_test.go` remains unchanged.
- Outside the map, the task's diff touches only `.github/workflows/ci.yml`.

## Risks and what is needed from the user

The known vet failure is in the upstream `noise` test, not production code. Do
not expand scope to fix it; if the dynamic selection cannot exclude exactly
that package while retaining coverage of the others, report back instead of
changing Go tests or introducing another exclusion mechanism.

## Outcome

The CI test job now runs `Go vet` after `Go tests`, dynamically listing packages
and excluding only the import path returned by `go list ./noise`. The filtered
vet passed for the other eight packages with Go 1.26.10; unfiltered vet reports
only the two known upstream `t.Fatal` calls from goroutines in
`go_src/noise/noise_test.go`. The full Go tests and all 75 Dart tests passed.
Review approved the workflow change. Kotlin unit tests could not start locally
because Android SDK target `android-34` is unavailable. The new step has not
been checked by GitHub Actions: a new remote CI run requires separate push
authorization, so this task remains in progress. No Go source or test was
changed, and `release.yml` was not run.
