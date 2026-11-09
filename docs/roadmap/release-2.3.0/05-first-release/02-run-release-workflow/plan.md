---
kind: stage
status: done
base: 21d5446dc4c07d10ad0a2a546135ab0b13f45b71
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

Children, in order:

1. [01-macos-path-remap](01-macos-path-remap/plan.md) (task): build
   `slipstream-client` in both macOS jobs through one script that remaps the
   C/C++ compilation and the OpenSSL module strings the way
   `scripts/build_slipstream_android.sh` does, and check the built binary
   before it replaces the tracked file.
2. [02-move-tag-and-rerun](02-move-tag-and-rerun/plan.md) (task): publish the
   fix, wait for green `ci.yml` on the fixed head, then re-create the
   lightweight tag there and follow the second `release.yml` run. The branch
   push and the tag move are outward actions and need the user's explicit
   go-ahead.

The `aar`, `slipstream-android` and `build-android` jobs passed and
`create-release` was not reached, so they get no children while they stay
green. If the second run fails in another step, the stage is planned again from
that run's log: the fix nodes are added after 02, each with its own failing
step and evidence.

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

## Outcome

The first `Build and Release` run failed in both macOS jobs on machine paths in
the staged Slipstream client. The fix from
[01-macos-path-remap](01-macos-path-remap/plan.md) was published, the tag moved
to the fixed head, and the second run published the release page.

- Run [42682231223](https://github.com/FreedomCats/dnstt_xyz_app/actions/runs/42682231223)
  on `21d5446` failed in `build-macos-arm64` and `build-macos-intel` at
  `Check libraries for machine paths`; `create-release` was skipped and no
  release page existed. The offending strings were the runner's checkout path
  in the picoquic C sources, which keep `__FILE__`, and in the vendored
  OpenSSL `engines-3` and `ossl-modules` directories. The inline `cargo build`
  remapped only Rust paths.
- The fix (commit `c9019d0`) replaced both inline builds with
  `scripts/build_slipstream_macos.sh`, which adds the C/C++
  `-ffile-prefix-map` values and the `ENGINESDIR`/`MODULESDIR` overrides that
  `scripts/build_slipstream_android.sh` already uses, and runs
  `scripts/check_binary_paths.sh` on the built binary before it replaces the
  tracked one. Step names and the following path-check steps stayed unchanged;
  no test, path check, signature step or artifact step was changed, skipped or
  widened, and no other workflow, script or tracked binary changed in the
  stage: the code change is `release.yml` and the new script only, the rest of
  the range is map files.
- The fix was published as `f74e7d5`; `ci.yml` run
  [42690405232](https://github.com/FreedomCats/dnstt_xyz_app/actions/runs/42690405232)
  on that head was green (`aar`, `slipstream-android`, `test`,
  `build-android`). With a separate go-ahead,
  [02-move-tag-and-rerun](02-move-tag-and-rerun/plan.md) force-updated the
  lightweight tag `v2.3.0-beta` from `21d5446` to `f74e7d5`; the remote tag is
  still a `commit` object, without a peeled entry.
- Run [42706971253](https://github.com/FreedomCats/dnstt_xyz_app/actions/runs/42706971253)
  (`Build and Release`, `push`, head `f74e7d5`) completed `success`: `aar`,
  `slipstream-android`, `build-android`, `build-macos-arm64`,
  `build-macos-intel` and `create-release` green; `build-linux` and
  `build-windows` skipped as configured. Both macOS jobs passed
  `Check libraries for machine paths` on the staged binary, so the remaps took
  effect on a cold runner for both architectures.
- `create-release` published the page with `draft: false`, `prerelease: true`
  and the tag target `f74e7d5`. It carries exactly the five expected assets,
  all non-zero, and nothing else:
  `DNSTT-Client-v2.3.0-beta-Android-arm64-v8a.apk`,
  `DNSTT-Client-v2.3.0-beta-Android-armeabi-v7a.apk`,
  `DNSTT-Client-v2.3.0-beta-Android-x86_64.apk`,
  `DNSTT-Client-v2.3.0-beta-macOS-arm64.dmg` and
  `DNSTT-Client-v2.3.0-beta-macOS-intel.dmg`.
- Checked at the stage acceptance: `bash -n`, ShellCheck 0.9.0 and
  `git diff --check` over `21d5446..HEAD` pass; the tracked
  `macos/Runner/Libraries/slipstream-client` is unchanged and passes
  `scripts/check_binary_paths.sh`. The full build and test gate was not rerun
  locally: the green `ci.yml` and `release.yml` runs on exactly `f74e7d5` are
  the evidence, as they were for the child tasks.
- Left outside this stage: the artifacts themselves are verified by
  [03-verify-artifacts](../03-verify-artifacts/plan.md), the install and start
  on a device by [04-install-on-device](../04-install-on-device/plan.md), and
  the page notes by [05-release-notes](../05-release-notes/plan.md).
- Real problems not fixed because of price: none in this stage. Acceptance
  confirmed a pre-existing gap that stays as it was:
  `scripts/build_slipstream_desktop.sh` builds the macOS client without the
  remaps and without the path check, so a local desktop build can put machine
  paths back into the tracked binary ([01-macos-path-remap](01-macos-path-remap/plan.md),
  "Outcome"); it predates the stage and is not part of a release built in CI.
