---
kind: task
status: todo
depends: [02-ci-build-artifacts]
---

# Package the CI-built executable in each Android APK

## Goal

Use the CI artifact as the input to CI and release Android packaging, keep
generated Slipstream binaries out of git, remove the existing committed ARM64
binary, and make missing ABI payloads a clear Gradle/CI failure.

## Done when

- `.gitignore` ignores generated `jniLibs` outputs and the prebuilt
  `arm64-v8a/libslipstream_client.so` is removed from the repository; CI and
  release workflows download the artifact into
  `android/app/src/main/jniLibs/` before Gradle runs.
- `android/app/build.gradle.kts` checks for all three expected executables at
  `preBuild` and reports an actionable instruction to run the local build
  script if any is missing.
- The Android APK consumer job in `.github/workflows/ci.yml` depends on the
  producer job and downloads its ABI-layout artifact; `release.yml` invokes the
  producer and downloads the same artifact before packaging.
- A shared APK check verifies that each split output contains exactly its
  corresponding `lib/<abi>/libslipstream_client.so` entry for `armeabi-v7a`,
  `arm64-v8a` and `x86_64`; both workflows run it and the existing
  `scripts/check_binary_paths.sh` succeeds on the APKs.
- Normal CI and release APK build jobs complete with all three architecture
  artifacts. `SlipstreamBridge.kt` continues to use
  `applicationInfo.nativeLibraryDir`, which Android resolves for the installed
  ABI; any runtime behavior change is scoped to the following smoke-test node.
- A local Android APK build has the explicit prerequisite to run
  `scripts/build_slipstream_android.sh` from the project root with the pinned
  vendored source and NDK before Gradle/Flutter packaging. It requires no remote
  artifact, credentials or network fallback.

## Risks and what is needed from the user

The APK check must inspect split APK contents, not infer them from the presence
of source files in `jniLibs`. Keep the executable file name and executable
permission unchanged when downloading the artifact. CI/release artifact wiring
is downstream of the reusable producer task so the producer and APK consumer
have separately verifiable results. Local Gradle builds require the source
build command above, the pinned Android NDK and recursive Slipstream submodule;
they do not fetch remote artifacts.
