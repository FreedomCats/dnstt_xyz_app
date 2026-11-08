---
kind: stage
status: in-progress
base: c1d64b9ded8d0ffc3146fa0d8f6c8c6b3179c842
---

# Slipstream binary for every Android ABI

## Goal

Slipstream works on 32-bit ARM devices and on x86_64 emulators, not only on
`arm64-v8a`, and the binary is built from the vendored source in CI instead of
being committed prebuilt from upstream. Closes `docs/CODE_REVIEW.md` item 3.3.

Today only `android/app/src/main/jniLibs/arm64-v8a/libslipstream_client.so` is
in git (`.gitignore` ignores the rest of `jniLibs`), so an APK of another ABI
starts with no Slipstream binary.

## What to do, what is touched

- `scripts/build_slipstream_android.sh`: cross-compile `slipstream-client` for
  `arm64-v8a`, `armeabi-v7a` and `x86_64` with the NDK pinned in `CLAUDE.md`
  (28.2.13676358), `--remap-path-prefix` (or a build in a copy) so no
  checkout path ends up in the binary.
- CI builds the three binaries with the pinned NDK, caches Rust and picoquic
  build outputs, uploads an ABI-layout artifact, and runs
  `scripts/check_binary_paths.sh` on every binary.
- `.gitignore`, `android/app/build.gradle.kts`, `ci.yml` and `release.yml`:
  keep all generated binaries out of git, remove the committed ARM64 binary,
  provide the checked CI artifact to Gradle, and verify that every split APK
  contains its matching ABI binary.
- `SlipstreamBridge.kt` already resolves the executable under
  `applicationInfo.nativeLibraryDir`; verify that behavior through an Android
  subprocess smoke test rather than changing the ABI selection unnecessarily.
- `CLAUDE.md`, `docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md` and
  `docs/CODE_REVIEW.md`: describe the build and close review item 3.3.

Children, in order:

1. [01-android-cross-build](01-android-cross-build/plan.md) (task): build the
   vendored `slipstream-client` executable for exactly the three supported
   Android ABIs, with remapped paths and verified output names.
2. [02-ci-build-artifacts](02-ci-build-artifacts/plan.md) (task): run the
   cross-build in CI with ABI-safe caches, path checks and an uploaded artifact.
3. [03-apk-packaging](03-apk-packaging/plan.md) (task): remove the committed
   ARM64 binary, feed the CI artifact into CI/release Gradle builds, require the
   local source-build prerequisite, and verify each split APK's native entry.
4. [04-android-subprocess-smoke](04-android-subprocess-smoke/plan.md) (task):
   prove the packaged subprocess starts and accepts a local TCP connection on
   x86_64 and armeabi-v7a Android runtimes, without a tunnel server.
5. [05-document-and-close-review](05-document-and-close-review/plan.md)
   (task): align build documentation and record the evidence closing review
   item 3.3.

## Done when

- The APKs contain `libslipstream_client.so` for all three ABIs.
- `scripts/check_binary_paths.sh` reports "ok" for every binary.
- Slipstream starts from an `armeabi-v7a` and an `x86_64` build (emulator or
  device; the full live check belongs to the live-checks stage, here it is
  enough that the subprocess starts and listens).

## Depends on

Nothing.

## Risks and what is needed from the user

The accepted delivery model is CI-only artifacts: all generated executables,
including the existing committed ARM64 file, stay out of Git. CI and release
APK jobs download the checked artifact in the standard `jniLibs/<abi>/` layout.
A local APK build must first run `scripts/build_slipstream_android.sh` from the
project root against the pinned vendored source and NDK; there is no remote
download fallback or checked-in-binary option. Cross-compiling OpenSSL and
picoquic for three ABIs is slow, so cache Cargo and per-target picoquic build
outputs. Confirm the APK size increase from the actual ABI builds rather than
relying on an estimate.
