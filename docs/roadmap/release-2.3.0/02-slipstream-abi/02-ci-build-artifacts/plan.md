---
kind: task
status: todo
depends: [01-android-cross-build]
---

# Build and publish checked Slipstream ABI artifacts in CI

## Goal

Run the verified Android cross-build as a reusable CI job, keep its expensive
Rust and per-ABI picoquic outputs cached without mixing architectures, and
publish the three path-checked executables as one Gradle-ready artifact.

## Done when

- A reusable `.github/workflows/build-slipstream-android.yml` initializes
  `vendor/slipstream-rust` recursively, installs the pinned NDK and the Rust
  Android targets, and invokes `scripts/build_slipstream_android.sh`.
- The cache key separates operating system, NDK/toolchain, Cargo lockfile and
  vendored Slipstream/picoquic revisions; target and CMake outputs for different
  Android triples cannot be reused as if they were interchangeable.
- CI runs `scripts/check_binary_paths.sh` on all three final executables and
  fails if any output is absent or contains a machine path.
- The workflow uploads the three files in `jniLibs/<abi>/` layout with
  missing-file failure enabled. A normal `ci.yml` run invokes this producer
  workflow and completes the build/artifact job. Downloading the artifact into
  APK consumer jobs and wiring `release.yml` belong to
  [03-apk-packaging](../03-apk-packaging/plan.md).

## Risks and what is needed from the user

The first uncached run compiles OpenSSL and picoquic three times and may take a
long time. Cache CMake outputs by target triple as well as the Cargo target
directory; a cache hit is an optimization, never a substitute for the path and
output checks. This producer task does not add a local or remote binary
fallback: local APK builds use the source build script, while CI/release jobs
consume the uploaded artifact in the next child. No secrets or external
workflow dispatch are needed.
