---
kind: task
status: done
detailed: true
depends: [02-ci-build-artifacts]
---

# Package the CI-built executable in each Android APK

## Task

Consume the accepted `slipstream-android-jni` artifact from
[02-ci-build-artifacts](../02-ci-build-artifacts/plan.md) in normal CI and
release Android builds. Remove the remaining tracked ARM64 executable, keep all
generated `jniLibs` outputs out of git, fail early with a local source-build
instruction when any supported ABI executable is absent, and inspect the
resulting split APK archives rather than inferring their contents from the
Gradle input directory. The producer contract is exactly three ABI-relative
`libslipstream_client.so` files, downloaded from the same workflow run; GitHub
artifact ZIPs do not preserve executable mode. Keep runtime behavior in
`SlipstreamBridge.kt` unchanged; the Android subprocess proof belongs to
[04-android-subprocess-smoke](../04-android-subprocess-smoke/plan.md), and build
documentation/review closure belong to
[05-document-and-close-review](../05-document-and-close-review/plan.md).

## Steps

1. Update the root `.gitignore` so every generated file below
   `android/app/src/main/jniLibs/` is ignored, without an exception for the
   committed ARM64 executable. Remove the tracked
   `android/app/src/main/jniLibs/arm64-v8a/libslipstream_client.so`; do not
   touch vendor submodules or generated build outputs outside this path.
2. Extend `tasks.named("preBuild")` in `android/app/build.gradle.kts` to require
   non-empty files at the three explicit paths:
   `jniLibs/arm64-v8a/libslipstream_client.so`,
   `jniLibs/armeabi-v7a/libslipstream_client.so`, and
   `jniLibs/x86_64/libslipstream_client.so`. Preserve the existing AAR and
   hev-socks5-tunnel checks. If any executable is absent, fail with an
   actionable message to initialize the pinned recursive source as needed and
   run `./scripts/build_slipstream_android.sh` from the project root before
   Gradle; do not add an artifact download, credential or network fallback to
   local builds.
3. Wire the artifact into both Gradle consumers in `.github/workflows/ci.yml`.
   Make `test` depend on `slipstream-android` as well as `aar`; after checkout,
   submodule/AAR setup, download artifact `slipstream-android-jni` from the
   current workflow run into `android/app/src/main/jniLibs/`. Immediately before
   `flutter build apk --config-only` and again immediately before
   `(cd android && ./gradlew :app:testDebugUnitTest)`, apply `chmod 0755` and
   `test -x` to each of the three expected files. This explicitly covers both
   Gradle-capable invocations in the test job.
   Make `build-android` depend directly on `slipstream-android` in addition to
   its existing `aar` and `test` dependencies; download the same named
   same-run artifact and apply `chmod 0755` plus `test -x` to all three files
   immediately before `flutter build apk --release --split-per-abi --obfuscate
   --split-debug-info=...`. Preserve the existing test gates, AAR handling,
   signing behavior and artifact upload.
4. Add the reusable producer call to `.github/workflows/release.yml` as a
   separate job using `./.github/workflows/build-slipstream-android.yml`.
   Make `build-android` depend on both `aar` and this producer, and download
   `slipstream-android-jni` from that same release workflow run into the same
   `jniLibs` directory. Immediately before each of `flutter build apk
   --config-only`, `(cd android && ./gradlew :app:testDebugUnitTest)`, and the
   release Flutter APK build, apply `chmod 0755` and `test -x` to each explicit
   file. Keep signing,
   macOS jobs and release assembly unchanged. Do not use a cross-run/latest
   artifact lookup; the called producer and Android consumer are jobs in this
   same workflow run.
5. Add one shared checker, for example
   `scripts/check_slipstream_apks.sh`, and a focused shell test for it. Have the
   checker inspect ZIP entry names in the three known split outputs and require
   exactly one `lib/<abi>/libslipstream_client.so` entry for that APK's ABI
   (`armeabi-v7a`, `arm64-v8a`, or `x86_64`), rejecting a missing/duplicate
   matching entry or a Slipstream executable under another ABI path. Test
   success with fixture APK archives and failure for missing, duplicate and
   wrong-ABI entries. Call this same checker in both workflows after the split
   APK build and before upload/release assembly; continue running
   `scripts/check_binary_paths.sh` on every APK with the workflows' existing
   CI checkout-path allowance.
6. Validate the changed YAML and embedded shell blocks with available workflow
   lint/parsing tools, run `bash -n` and ShellCheck on the new checker and its
   test, and run the focused fixture test plus `git diff --check`. Do not install
   new local tools just for optional linting; report unavailable tools. Confirm
   the tracked-file list no longer contains the ARM64 executable and that the
   ignore rules do not mask source in `vendor/`.
7. For remote acceptance, obtain separate user authorization before publishing
   the implementation and observing a normal `ci.yml` run. Verify the producer,
   Kotlin test consumer and Android build consumer all succeed, and that the
   three split APKs pass the shared content checker and existing machine-path
   check. A release workflow run also requires its own scoped authorization:
   it uses signing secrets and can publish a real release. Do not create a tag,
   dispatch either workflow, use secrets or publish a release under the prior
   CI authorization. Record no remote result until the specifically authorized
   run is actually observed.

## Done when

- `.gitignore` ignores all generated files under
  `android/app/src/main/jniLibs/`, and the tracked
  `arm64-v8a/libslipstream_client.so` is removed. No generated native binary is
  committed.
- `android/app/build.gradle.kts` checks all three expected executable paths at
  `preBuild`, retains the AAR and hev checks, and reports the project-root
  `./scripts/build_slipstream_android.sh` prerequisite clearly when one is
  missing. A local build uses the pinned vendored source and NDK and does not
  fetch remote artifacts or require CI credentials.
- In `.github/workflows/ci.yml`, `test` and `build-android` both depend on the
  producer and download the exact `slipstream-android-jni` artifact from their
  run. In `.github/workflows/release.yml`, the reusable producer and Android
  consumer share the release workflow run. Repeat `chmod 0755` and `test -x`
  on all three ABI files immediately before each Gradle-capable invocation:
  `flutter build apk --config-only`, `(cd android && ./gradlew
  :app:testDebugUnitTest)`, and the release Flutter APK build. CI's
  `build-android` job similarly checks immediately before its Flutter APK
  build; no invocation may rely on a one-time mode check.
- One shared APK checker passes for the matching
  `app-armeabi-v7a-release.apk`, `app-arm64-v8a-release.apk` and
  `app-x86_64-release.apk`, and rejects absent, duplicate or wrong-ABI
  Slipstream entries. Its fixture tests, shell syntax checks, available lint,
  YAML validation and `git diff --check` pass. Both workflows invoke it and
  `scripts/check_binary_paths.sh` before publishing their APK artifacts.
- A separately authorized normal CI run completes the producer, Kotlin test
  and split APK jobs with the checked three-ABI payload. Release APK acceptance
  is recorded only after a separately authorized release-workflow run; the
  previous CI permission does not authorize a push, rerun, dispatch, tag,
  signing-secret use or release publication for this task.
- `SlipstreamBridge.kt` and runtime behavior remain unchanged; proving installed
  APK subprocess behavior is left to task 04.

## Risks and what is needed from the user

The APK check must inspect split APK contents, not infer them from the presence
of source files in `jniLibs`; ordinary Flutter/Android native libraries in an
APK are expected and must not be mistaken for Slipstream entries. GitHub ZIP
artifact transport drops executable mode, so each consumer must explicitly
restore and verify it before Gradle. Local Gradle builds require the source
build command above, the pinned Android NDK and recursive Slipstream submodule;
they do not fetch remote artifacts. Remote publication/normal-CI verification
and a release workflow run need new, separately scoped user authorization; the
producer task's authorization is already consumed.

## Remote acceptance

The authorized implementation history was published by one ordinary
fast-forward push of exactly `e4e5a9d` and `d0a088c` on top of `d03d5a1`.
Normal CI run `42545281750` for `d0a088c` completed successfully. The release
workflow remains separately unverified because it uses signing secrets and can
publish a release; no release authorization was granted here. No rerun,
dispatch, tag, PR, force push or other remote action was used.

## Outcome

- Removed the tracked ARM64 Slipstream executable and ignored every generated
  file below `android/app/src/main/jniLibs/`. The vendor source and all other
  generated output paths remain unaffected.
- Added a `preBuild` guard for the three supported ABI executables. It requires
  non-empty regular files, rejects symlinks, preserves the AAR and tun2socks
  checks, and explains how to build the files locally from the pinned recursive
  source without a remote fallback.
- Wired the exact same-run `slipstream-android-jni` artifact into the normal CI
  and release Android consumers. Each config-only, Kotlin test, and APK build
  restores executable mode and verifies all three files immediately before the
  command. Both workflows inspect the resulting split APK ZIP entries before
  their existing machine-path checks and uploads.
- Added the shared split-APK checker and fixture test. The checker accepts one
  matching `lib/<abi>/libslipstream_client.so` entry per APK and rejects missing,
  duplicate, malformed, and wrong-ABI entries. `SlipstreamBridge.kt`, the
  producer workflow, the native build script, and vendor gitlinks are unchanged.
- Local validation passed: focused fixtures, Bash syntax, ShellCheck for new
  scripts, YAML parsing with duplicate-key detection, all embedded Bash blocks,
  mode-restoration probes, ignore checks, and whitespace checks. Flutter
  analysis, the full Dart test suite, Go tests and vet, Kotlin unit tests, and an
  offline debug APK build also passed in a temporary validation copy; the three
  debug APKs passed the shared content check.
- `actionlint` and `yamllint` were unavailable and were not installed. No
  release workflow or native producer rebuild was run. Release acceptance
  remains intentionally pending and must not be inferred from normal CI.
- Independent review found no correctness, regression, security, or scope
  findings. No generated binary, private data, or vendor change is included.
- The first authorized push attempt did not reach GitHub because zsh interpreted
  the unbraced `$head:refs/heads/develop` refspec as a parameter modifier. The
  corrected attempt used the quoted literal refspec
  `d0a088c54fa91e3aad47e4be26f9f7498a361b6b:refs/heads/develop` and published
  only the two authorized commits.
- The resulting normal CI run `42545281750` succeeded. Producer jobs
  `128928822939` (`slipstream-android / build`) and `128928823164` (`aar /
  build`) uploaded `slipstream-android-jni` (artifact `13642623337`) and
  `dnstt-aar` (artifact `13642853943`). The `test` job `128929369497`
  downloaded both artifacts from the same run and passed Kotlin unit tests,
  Dart analysis/tests, Go tests and vet. The `build-android` job
  `128931061301` downloaded the same-run artifacts, built all three split APKs,
  passed the shared APK checker and machine-path checker, and uploaded
  `android-apks` (artifact `13643771980`) containing exactly the three ABI
  APKs. Release workflow acceptance remains separate and unverified.
