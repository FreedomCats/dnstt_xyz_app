---
kind: stage
status: done
base: c1d64b9ded8d0ffc3146fa0d8f6c8c6b3179c842
---

# Slipstream binary for every Android ABI

## Goal

Slipstream works on 32-bit ARM devices and on x86_64 emulators, not only on
`arm64-v8a`, and the binary is built from the vendored source in CI instead of
being committed prebuilt from upstream. Closes `docs/CODE_REVIEW.md` item 3.3.

At the start of this stage, only
`android/app/src/main/jniLibs/arm64-v8a/libslipstream_client.so` was in git
(`.gitignore` ignored the rest of `jniLibs`), so an APK of another ABI started
with no Slipstream binary.

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
6. [06-fix-process-destroy-guard](06-fix-process-destroy-guard/plan.md)
   (task): guard the production force-kill path for the API 24 minimum, found
   while accepting task 04.

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

## Outcome

The integration review covered the cumulative range `c1d64b9..949cf1b` after all
six tasks. It found one real local-build defect and no regression in the
delivered flow: on a clean Cargo target the build script let Cargo link host
build scripts through the NDK `cc` wrapper placed first in `PATH` — the same
failure the first producer CI run hit. The script now pins the discovered host
compiler in `CARGO_TARGET_<host>_LINKER` unless the environment already sets it
(CI does), which fixes the documented local build path without changing the
produced binaries. The review otherwise required documentation alignment only.

All three "Done when" criteria are met:

- The APKs contain `libslipstream_client.so` for all three ABIs. The accepted
  normal CI run `42545281750` (task 03) built the three split release APKs,
  passed `scripts/check_slipstream_apks.sh` and the machine-path check, and
  uploaded them. A fresh local debug split build has exactly one matching
  `lib/<abi>/libslipstream_client.so` entry per APK and no other Slipstream
  entry.
- `scripts/check_binary_paths.sh` reports `ok` for the `arm64-v8a`,
  `armeabi-v7a` and `x86_64` executables.
- Slipstream starts and accepts a local TCP connection from the `x86_64` and
  the accepted ARMv7-capable build. The bridge instrumentation test passed with
  `app-x86_64-debug.apk` on an x86_64 runtime, and the direct-executable test
  passed with `app-armeabi-v7a-debug.apk` on the accepted runtime
  (`primaryCpuAbi=armeabi-v7a`).

The build chain is implemented as designed:
`scripts/build_slipstream_android.sh` cross-compiles the pinned
`vendor/slipstream-rust` source with cargo-ndk 4.1.2 and NDK 28.2.13676358 for
three ABIs, remaps checkout and home paths, verifies ELF machines, runs the
path checker, and reuses only stamped native caches.
`build-slipstream-android.yml` runs it in CI with an exact cache key and the
`slipstream-android-jni` artifact; the Kotlin-test, CI APK and release APK jobs
download the same-run artifact, restore `0755` and check `test -x` before each
Gradle invocation. The tracked ARM64 executable is removed and all generated
`jniLibs` files are ignored; `android/app/build.gradle.kts` fails early when a
local build lacks one of the three executables.

Fresh local integration checks passed: `flutter analyze`; the full Dart suite
(75 tests); fresh Go tests and the filtered vet; forced `:app:testDebugUnitTest`
(11 tests); `bash -n`, ShellCheck and the APK-checker fixtures; the debug split
APK build and its ZIP inspection; and the path checker on all three binaries.
The fixed script also passed a cold Cargo-target run with warm native caches,
with all three outputs path-checked; an A/B run of the old script with the host
linker exported produced byte-identical outputs, so the fix is neutral. No
release APK was built locally, no workflow was dispatched, and nothing was
pushed. Flutter's local regeneration of the tracked Linux and Windows plugin
files was restored to `HEAD`.

Documentation matches the implementation: `CLAUDE.md` covers the prerequisites,
the script-first local flow, the CI artifact and the runtime lookup;
`docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md` section 5.4 describes the flow and the
measured APK growth (about 2-3 MB per ABI); `docs/CODE_REVIEW.md` closes item
3.3 and, because the last committed prebuilt binary is gone, also marks item 6
resolved.

Deferred and unverified by design: release-workflow acceptance remains separate
and must not be inferred from normal CI; a full bridge run on a real ARMv7
runtime stays in the live-checks stage (the accepted ARMv7-capable runtime is an
x86_64 image with ARM translation, where the existing Go JNI library crashes,
so the direct-executable test covers the subprocess contract); the API 24/25
`destroy()` fallback is covered statically only; and a warm producer-cache
restore has not been observed in CI — the accepted producer run was cold, the
script validates every stamp, and the next run after this script change will be
cold because the builder identity is part of the cache key.

Real problems not fully fixed because of cost: none in the delivered flow. The
`README.md` Android build section omitted the AAR and Slipstream prerequisite
steps and kept an unpinned cargo-ndk; it was already stale for the AAR and
outside this stage's scope. It was fixed in a follow-up documentation commit
together with the pinned cargo-ndk version.
