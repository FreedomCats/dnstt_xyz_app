---
kind: task
status: todo
depends: [06-prove-the-gate]
---

# Describe the gate as it is in `CLAUDE.md`

## Task

`CLAUDE.md` ("Development workflow") still gives the analyzer baseline as a
known broken state, lists the Dart tests by name and says `go vet` runs by hand
package by package. Bring it in line with what CI now does. If the chosen
approach changes the design, section 5.3 of
`docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md` follows it.

## Done when

- `CLAUDE.md` does not call the analyzer baseline broken, does not call
  `test/widget_test.dart` stale, and does not list the Dart tests by name.
- It gives the analyzer, test and vet commands that CI runs, and each of them
  has been run on the final tree.
- It explains the `go_src/noise` vet exclusion in one sentence.
- The diff passes the `AGENTS.md` check: no dates, paths or device data.

## Outcome
