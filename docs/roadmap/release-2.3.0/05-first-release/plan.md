---
kind: stage
status: in-progress
base: d6aca13944d6a3e168ad39f3bf0c0156148313f8
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

Children, in order:

1. [01-version-and-tag](01-version-and-tag/plan.md) (task): `version: 2.3.0+6`
   in `pubspec.yaml` and the lightweight tag `v2.3.0-beta` on the work branch,
   with the pre-tag check that `ci.yml` sees the signing secrets.
2. [02-run-release-workflow](02-run-release-workflow/plan.md) (stage): follow
   the run triggered by the tag to a published release and fix what fails. The
   Android half repeats `ci.yml`; the macOS jobs and `create-release` are new,
   so this node is a stage and is planned again from the first failing run.
3. [03-verify-artifacts](03-verify-artifacts/plan.md) (task): the three APKs
   and two DMGs are the ones this project built — project certificate, version
   2.3.0 (6), the per-ABI Slipstream binary, and no machine path other than the
   CI checkout.
4. [04-install-on-device](04-install-on-device/plan.md) (task): install over
   what the phone holds — an in-place update for this project's key, export and
   uninstall for the upstream app's key — and start it; the user acts, the agent
   checks and records.
5. [05-release-notes](05-release-notes/plan.md) (task): the published page and
   its notes — asset names, pre-release flag, certificate SHA-256, what 2.3.0
   adds and the install caveats.

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
and the release publication are done with the user's explicit go-ahead. The
first fully green run publishes: `create-release` has no draft. While
`release.yml` is being fixed, the tag is moved to each fix commit, which is a
force-push and needs the same go-ahead; once a release page exists, the tag and
its assets are not replaced without a separate decision.
