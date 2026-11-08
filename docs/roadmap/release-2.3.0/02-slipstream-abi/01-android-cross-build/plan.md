---
kind: task
status: in-progress
detailed: true
---

# Cross-build Slipstream for the supported Android ABIs

## Task

Replace the ineffective target loop in `scripts/build_slipstream_android.sh`
with a checked cross-build of the vendored `slipstream-client` command for
`arm64-v8a`, `armeabi-v7a` and `x86_64`. The script currently also attempts
unsupported `x86`, looks for `libslipstream.so` although the Android app expects
`libslipstream_client.so`, and only warns when outputs are missing. The
Slipstream source is pinned as a gitlink at `vendor/slipstream-rust`; its Cargo
workspace defines `slipstream-client` as a binary package and its `slipstream-ffi`
build script builds picoquic through CMake. See architecture section 5.4 and
`CLAUDE.md`, "Building for Android".

## Steps

1. Use the pinned submodule workspace and lockfile:
   `vendor/slipstream-rust/Cargo.toml`,
   `vendor/slipstream-rust/Cargo.lock`,
   `crates/slipstream-client/Cargo.toml` and
   `crates/slipstream-ffi/build.rs`. Build only package `slipstream-client`,
   with `--locked`, release profile and the existing `openssl-vendored` feature
   used by `release.yml`. Do not build x86/i686 or the server package.
2. Update `scripts/build_slipstream_android.sh` to require the exact NDK
   revision `28.2.13676358` and map only `arm64-v8a` to
   `aarch64-linux-android`, `armeabi-v7a` to `armv7-linux-androideabi`, and
   `x86_64` to `x86_64-linux-android`. Pass Android platform 21, consistent
   with the app's minimum SDK and `scripts/build_aar.sh`; fail immediately when
   a required tool, source/submodule or NDK is missing.
3. Build one target at a time with `cargo ndk`. The Cargo output is an
   executable under `vendor/slipstream-rust/target/<triple>/release/`, not a
   shared library copied by cargo-ndk. Set a distinct `PICOQUIC_BUILD_DIR` for
   each target so CMake does not reuse one ABI's picoquic archives for another.
   Copy each executable into
   `android/app/src/main/jniLibs/<abi>/libslipstream_client.so`, preserving its
   executable permission. Remove stale unsupported-ABI output rather than
   leaving an extra x86 directory to be packaged accidentally.
4. Apply Rust `--remap-path-prefix` flags consistently with the macOS/Linux
   Slipstream build steps in `release.yml`; inspect the native CMake release
   output as well. Keep output verification fail-closed: require all three
   non-empty files, check their ELF machine types with `readelf` (or an
   equivalent NDK tool), and check the final files with
   `scripts/check_binary_paths.sh`.
5. Run the script from a recursive checkout of the pinned submodule and its
   picoquic child submodule. Keep all generated Cargo/CMake output under the
   existing ignored vendor build directories; do not edit vendored source or
   commit generated executables.

## Done when

- The script builds exactly three executable files at
  `jniLibs/arm64-v8a/libslipstream_client.so`,
  `jniLibs/armeabi-v7a/libslipstream_client.so` and
  `jniLibs/x86_64/libslipstream_client.so`; no x86 output is produced.
- Each file has the expected ELF architecture, is executable, and
  `scripts/check_binary_paths.sh` reports `ok` for all three.
- A missing target output or a mismatched NDK causes a non-zero exit instead of
  a successful build with warnings.
- `bash -n scripts/build_slipstream_android.sh` passes, and the three-ABI build
  completes against the pinned vendored source.

## Risks and what is needed from the user

No user decision is needed. The submodule working tree may not be initialized
in a fresh checkout; the implementation and CI workflow must initialize it
recursively. `slipstream-ffi/build.rs` invokes CMake for picoquic during each
target build, so the first uncached build may be long. Validate the exact
cargo-ndk output path and the remapped final executable rather than assuming
that `cargo ndk -o` copies a standalone binary into `jniLibs`.
