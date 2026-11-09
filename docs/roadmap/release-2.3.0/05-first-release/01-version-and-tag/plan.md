---
kind: task
status: done
detailed: true
---

# Bump the version to 2.3.0+6 and tag the commit

## Task

The release is built by `release.yml` from a tag. The workflow also has a
`workflow_dispatch` trigger, but that button builds the default branch, where
the work of this map is not, and its `version` input still defaults to
`v2.2.0-beta`; the tag is the only correct trigger. The app must report version
2.3.0 with a build number higher than the installed one, or the release APK
cannot install over it.

`pubspec.yaml:5` is the single source of the version: Flutter derives
`versionName`/`versionCode` for Android (`android/app/build.gradle.kts:55-56`)
and `CFBundleShortVersionString`/`CFBundleVersion` for macOS
(`macos/Runner/Info.plist:21-24`) from it, so nothing else is edited.

This task ends with the lightweight tag on the remote and the release workflow
started. The branch push and the tag push are outward actions and need the
user's explicit go-ahead; the tag itself publishes nothing, but its run is what
[02-run-release-workflow](../02-run-release-workflow/plan.md) follows.

## Steps

1. If the device is attached, read the installed version before changing
   anything: `adb shell dumpsys package xyz.dnstt.app | grep -E
   'versionCode|versionName'`. A debug build of this fork reports 2.2.0 (5), so
   the planned 6 installs over it. If the installed code is 6 or higher, the
   release cannot install over it: report that to the lead and do not tag. If
   the installed app is the upstream build with another signature and a higher
   code, its uninstall in [04-install-on-device](../04-install-on-device/plan.md)
   makes the order moot, and that task decides by the install result.
2. Set `version: 2.3.0+6` in `pubspec.yaml:5`. Leave the `version` input of the
   `workflow_dispatch` trigger (`release.yml:9-12`) as it is: it is unused on
   the tag path, and its stale default makes an accidental dispatch visibly
   wrong instead of plausible.
3. Check that no other tracked file pins the app version:
   `git grep -n '2\.2\.0'` leaves only that input default. The Fastlane store
   changelog `fastlane/metadata/android/en-US/changelogs/3.txt` mentions
   version 2.0.0, but it is a store note, not the app version, and the GitHub
   release does not read it; leave it alone.
4. Build a debug APK and read the version Gradle computed. The ignored
   `android/app/libs/dnstt.aar` and the three
   `android/app/src/main/jniLibs/<abi>/libslipstream_client.so` must be in
   place; if they are not, run `scripts/build_aar.sh` and
   `scripts/build_slipstream_android.sh` (their outputs are ignored and are not
   committed). Then run `flutter pub get`,
   `flutter build apk --debug --target-platform android-arm64`, and read the
   manifest with the newest build-tools, the way `ci.yml:183` picks
   `apksigner`: `AAPT2=$(ls -d "$ANDROID_HOME"/build-tools/*/ | sort -V |
   tail -1)aapt2; "$AAPT2" dump badging
   build/app/outputs/flutter-apk/app-debug.apk | head -1`. The first line must
   read `package: name='xyz.dnstt.app' versionCode='6' versionName='2.3.0'`.
   Do not build a release APK locally: its Dart AOT snapshot carries the project
   path (`AGENTS.md`, "Builds").
5. `git diff --check` passes and the tracked diff is `pubspec.yaml` only. If
   Flutter rewrote the generated `linux/` or `windows/` plugin files, restore
   them to `HEAD`. The lead commits the change the way `AGENTS.md` requires.
6. With the user's go-ahead, push `develop` and wait for `ci.yml` on that
   commit. Two things are read from its Android job: the run is green, and the
   `Show signing certificate` step printed a `certificate SHA-256`. If it
   printed the `No release signing key in secrets` warning instead, the release
   run will fail in `Set up release signing key`: stop, have the user add the
   four secrets listed in `CLAUDE.md` ("Signing in CI"), and wait for a green
   run. Record the digest in the task report so the lead puts it in the journal;
   it is the expected value for
   [03-verify-artifacts](../03-verify-artifacts/plan.md).
7. Confirm the tag target: `git status --porcelain` is empty (the lead has
   committed the map edits), `git fetch origin`, `origin/develop` equals local
   `develop`, and `git log --oneline` shows the accepted work of stages 1-4 as
   ancestors (the Outcomes name the heads `c51f108`, `949cf1b`, `94a6d22` and
   `d6aca13`).
8. Check that the tag does not exist yet: `git tag -l 'v2.3.0*'` is empty and
   `git ls-remote --tags origin 'v2.3.0*'` prints nothing. Create the
   lightweight tag at the pushed head: `git tag v2.3.0-beta origin/develop`.
   Verify `git cat-file -t v2.3.0-beta` prints `commit` (a lightweight tag, not
   an annotated `tag` object) and that
   `git rev-parse 'v2.3.0-beta^{commit}'` equals `git rev-parse origin/develop`.
9. With the user's explicit go-ahead, push the tag:
   `git push origin refs/tags/v2.3.0-beta`. Then
   `git ls-remote --tags origin refs/tags/v2.3.0-beta` returns that same commit
   id and no peeled `^{}` line. A force-push is not part of this task.
10. Confirm the run started: `gh run list --workflow release.yml --limit 1`
    (or the Actions page) shows a `Build and Release` run for the tag. Record
    its id for [02](../02-run-release-workflow/plan.md). Do not use
    `Run workflow`: it builds the default branch.

## Done when

- `pubspec.yaml` has `version: 2.3.0+6`, and a locally built debug APK reports
  `versionCode='6'` and `versionName='2.3.0'` for `xyz.dnstt.app`.
- The version bump is committed and pushed; `ci.yml` is green on that commit and
  its Android job printed a signing certificate SHA-256, not the missing-key
  warning. The digest is in the report, for the journal and the next task.
- `v2.3.0-beta` is a lightweight tag on the remote at the commit that carries
  the version bump and the accepted stages 1-4.
- A `Build and Release` run for the tag is queued or running; no release page
  exists yet and no tag was force-pushed.

## Risks and what is needed from the user

- The branch push and the tag push are outward actions; both need the user's
  explicit go-ahead. The release page becomes public as soon as the first fully
  green run finishes, not at the tag push.
- If the signing secrets are absent, `ci.yml` only warns while `release.yml`
  fails; the pre-tag check in step 6 catches that without a wasted release run.
- The tag is the release's identity. After
  [02](../02-run-release-workflow/plan.md) fixes a failure, the tag is moved to
  the fixed commit while no release exists; this task creates and pushes it once
  and does not move it.
- Deleting and re-pushing a wrong tag is possible but is an outward action and
  the user's decision.
- No live server is used. The device is only read in step 1 and may be absent,
  in which case the user reports the installed version; nothing from the device
  goes into the repository.

## Outcome

- `pubspec.yaml:5` is `version: 2.3.0+6`, in commit `21d5446`. A local debug
  APK built from it reported
  `package: name='xyz.dnstt.app' versionCode='6' versionName='2.3.0'`.
- `develop` was pushed to `21d5446`, and `ci.yml` run
  [42667749110](https://github.com/FreedomCats/dnstt_xyz_app/actions/runs/42667749110)
  on that head was green (`aar`, `slipstream-android`, `test`, `build-android`).
  Its `Show signing certificate` step printed the project certificate, not
  the missing-key warning. Certificate SHA-256 digest:
  `a0463ae9637d96ee9ad8b8ce305aa62b0c78868fa565d19111f26eca74e0500c`.
- `v2.3.0-beta` is a lightweight tag on `21d5446` (a `commit` object, not an
  annotated tag), created and pushed once; the remote tag points at the same
  commit, and no force-push was made.
- Pushing the tag started `release.yml` (`Build and Release`) run
  [42682231223](https://github.com/FreedomCats/dnstt_xyz_app/actions/runs/42682231223)
  on `21d5446`; it was in progress when this task was closed, and no release
  page existed yet. Whether the release is published is the result of that
  run, followed by [02-run-release-workflow](../02-run-release-workflow/plan.md).
