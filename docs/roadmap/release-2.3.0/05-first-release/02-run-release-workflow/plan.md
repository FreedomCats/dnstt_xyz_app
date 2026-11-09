---
kind: stage
status: todo
depends: [01-version-and-tag]
---

# Run the release workflow to a published release

## Goal

`.github/workflows/release.yml` has never run. This stage follows the run
started by the tag `v2.3.0-beta` to the end — `aar`, `slipstream-android`,
`build-android`, `build-macos-arm64`, `build-macos-intel`, `create-release` —
fixes what fails, and ends with the release page published with the three APKs
and the two DMGs.

The Android half is already exercised by `ci.yml` on every push with the same
split release build, signing and checks; the macOS jobs, the packaging of the
macOS libraries and `create-release` are new. The release is published by the
first fully green run: `create-release` has `draft: false` and marks a tag
containing `beta` as a pre-release (`release.yml:562-563`), so there is no
draft step to catch mistakes.

## What to do, what is touched

- Follow the `Build and Release` runs for the tag; read the failing job's log
  and identify the first real cause, not the symptom further down.
- Fix the cause where it lives: `.github/workflows/release.yml`, a reusable
  workflow it calls (`build-aar.yml`, `build-slipstream-android.yml`), a
  `scripts/` script, the macOS or Android build configuration, or a pinned
  toolchain version. Do not disable a check, skip a test or widen a `--allow`
  to make a job pass.
- Each fix commit goes on `develop`. The tag is re-created at the fixed commit
  and force-pushed so the workflow runs again; the push and the force-push are
  outward actions and need the user's explicit go-ahead. Cancel the superseded
  run and wait until it is cancelled before pushing: a run that finishes after
  the move would publish the older commit under the same tag name.
- A fix that changes the app version or build number reopens
  [01-version-and-tag](../01-version-and-tag/plan.md); a fix that would drop a
  platform from the release is a user decision.

Children, in order: not planned yet. The failures are unknown and they set the
split. If the first run is fully green, this stage has no children. If it
fails, the likely nodes are the Android job with `create-release`, the macOS
arm64 job and the macOS Intel job, each only if it needs work of its own; the
stage is planned again from the first failing run.

## Done when

- One `Build and Release` run for `v2.3.0-beta` completes with every job green,
  including `create-release`.
- The release page for the tag exists and carries
  `DNSTT-Client-v2.3.0-beta-Android-*.apk` for the three ABIs and
  `DNSTT-Client-v2.3.0-beta-macOS-*.dmg` for arm64 and Intel.
- The workflow and script changes are limited to what the failures required; no
  test, path check, signature check or artifact check was weakened, and every
  changed step is explained by a failure that is named in the stage outcome.

## Depends on

[01](../01-version-and-tag/plan.md): the version bump and the tag are what the
run builds and names.

## Risks and what is needed from the user

- The macOS jobs are the slow and fragile part, roughly twenty to forty minutes
  each. `macos-latest` is currently a macOS 26 arm64 image and `macos-15-intel`
  an Intel image; Flutter 3.38.7, the default Xcode, CocoaPods, Go cgo, the Rust
  `openssl-vendored` build, `codesign --deep` and `hdiutil` are unproven on
  them. The Android job, by contrast, repeats steps that `ci.yml` already runs.
- The four signing secrets must be present or `build-android` fails at its first
  step. [01](../01-version-and-tag/plan.md) checks that before the tag.
- Every failed run costs tens of minutes of CI; the macOS Intel job may need
  more than one round. If a macOS defect turns out to be expensive, dropping a
  platform changes the stage's "Done when" and is the user's decision, not an
  agent's.
- Moving the tag is visible on the remote and is an outward action. It is
  allowed only while no release page exists for the tag: once a release is
  published, its assets are what users may already have downloaded, and
  replacing them is the user's decision.
- `build-windows` and `build-linux` are disabled with `if: false` and stay
  disabled; enabling them is outside this stage.
- The release page is public when the run finishes; the notes on it are
  [05-release-notes](../05-release-notes/plan.md).
