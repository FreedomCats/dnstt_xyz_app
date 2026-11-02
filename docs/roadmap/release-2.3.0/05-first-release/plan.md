---
kind: stage
status: todo
---

# First release

## Goal

A signed release `v2.3.0-beta` built in CI that the user can install and test
with. `release.yml` has never run, so the stage includes following it to the
end and fixing what fails.

Release APKs are built only in CI: a release APK built on a developer machine
carries the absolute project path in the Dart AOT snapshot (`AGENTS.md`,
"Builds"). The "Run workflow" button runs `main`, so the tag is the trigger.

## What to do, what is touched

- `pubspec.yaml`: `version: 2.3.0+6`.
- A lightweight tag `v2.3.0-beta` on the work branch (`git tag v2.3.0-beta`,
  no `-a`).
- Run and follow `.github/workflows/release.yml` (Android, macOS arm64, macOS
  Intel); fix what fails.
- Check that the APKs are signed with the project key, and record the
  certificate SHA-256 in the release notes.

## Done when

- The release is published with the APK and the macOS artifacts.
- The APKs are signed with the project key (certificate SHA-256 matches the one
  in the release notes).
- The APK installs on the device and the app starts.

## Depends on

1, 2, 3, 4 — the release should carry all of them.

## Risks and what is needed from the user

`release.yml` has never run; the macOS jobs are the slow and fragile part, and
the signing secrets have to be present (the build fails without them). The
phone may hold the upstream app with the same application ID and a different
signature: configs are exported and the app uninstalled first, which is the
user's call.

Publishing the release and pushing the tag are outward actions; the tag push
and the release publication are done with the user's explicit go-ahead.
