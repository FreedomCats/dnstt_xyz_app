---
kind: stage
status: todo
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
- `ci.yml`: build the three binaries, upload them as artifacts, run
  `scripts/check_binary_paths.sh` on each.
- `.gitignore`: decide whether the binaries stay in git or are fetched from CI;
  `SlipstreamBridge.kt` and the Gradle packaging follow that decision.
- `CLAUDE.md` ("How Slipstream is Bundled Per Platform", "Building Slipstream
  Client"), `docs/CODE_REVIEW.md`.

## Done when

- The APKs contain `libslipstream_client.so` for all three ABIs.
- `scripts/check_binary_paths.sh` reports "ok" for every binary.
- Slipstream starts from an `armeabi-v7a` and an `x86_64` build (emulator or
  device; the full live check belongs to the live-checks stage, here it is
  enough that the subprocess starts and listens).

## Depends on

Nothing.

## Risks and what is needed from the user

Cross-compiling OpenSSL and picoquic for three ABIs is slow in CI; a build
cache or artifacts may be needed, and the APK grows by about 3 × 3 MB.
Whether the binaries are committed or produced by CI changes what a developer
needs locally; the recommendation is CI-only with a Gradle-friendly download,
but if the user wants offline builds, the binaries stay in git.
