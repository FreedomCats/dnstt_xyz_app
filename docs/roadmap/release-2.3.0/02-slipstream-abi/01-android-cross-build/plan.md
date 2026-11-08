---
kind: task
status: done
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

The user authorized cargo-ndk 4.1.2 and the three Android targets for the existing
stable Rust toolchain, without upgrading Rust or installing other SDK packages.
The submodule working tree may not be initialized in a fresh checkout; the
implementation and CI workflow must initialize it recursively.
`slipstream-ffi/build.rs` invokes CMake for picoquic during each
target build, so the first uncached build may be long. Validate the exact
cargo-ndk output path and the remapped final executable rather than assuming
that `cargo ndk -o` copies a standalone binary into `jniLibs`.

## Outcome

- Replaced the target loop with sequential, locked release builds of only
  `slipstream-client`, with `openssl-vendored`, API 21 and NDK 28.2.13676358.
  Source, recursive gitlink, tool and Rust target checks fail before building
  when prerequisites are missing or inconsistent. All three executables are
  verified before staging under their Android library names; no x86 or server
  executable is built.
- The pinned FFI builder invokes the C compiler directly and needs explicit
  CMake flags and vendored OpenSSL locations for Android. Temporary compiler,
  CMake and Cargo-workspace drivers handle these requirements inside the
  ignored target directory, without modifying vendored source. Rust and native
  path remaps and neutral OpenSSL module paths keep machine paths out of the
  final executables.
- Each target has its own picoquic build directory and script-owned metadata
  stamp. Reuse checks include ABI, API, NDK, source revisions, lockfile,
  builder identity and native build context, plus CMake settings and archive
  architectures. Unknown, incompatible or incomplete caches fail without
  deletion. Recognized generated x86 outputs are removed narrowly; unrelated
  files are preserved with an error.
- Installed only the authorized cargo-ndk 4.1.2 and three Android Rust targets
  for the existing toolchain. The pinned Slipstream revision
  `bc772dd07d9a136dbd7553b0da575526de207847` and picoquic revision
  `4bd356c004a50ec46ee8a933ebd024da5d659f75` remained unchanged and clean.
- `bash -n scripts/build_slipstream_android.sh`, ShellCheck and
  `git diff --check` passed. The focused harness passed 36 cases covering
  missing prerequisites and outputs, NDK and ELF mismatches, path leaks,
  non-destructive cache rejection, cold and warm cache use, and stale x86
  handling. Real mismatched and missing NDK metadata also produced non-zero
  exits.
- The real three-ABI build completed successfully. After the cache correction,
  `CARGO_BUILD_JOBS=8 CMAKE_BUILD_PARALLEL_LEVEL=8
  ./scripts/build_slipstream_android.sh` passed with both cold and matching
  warm native caches. Warm caches were unchanged and executable bytes matched
  the cold results. The outputs were executable with mode `0755`: AArch64
  (5,917,936 bytes), ARM (3,983,300 bytes) and x86-64 (6,622,088 bytes).
  ELF class, Android interpreter, API and native archive architectures were
  checked. `scripts/check_binary_paths.sh` reported `ok` for every executable
  and all 12 picoquic/picotls archives, without a path allowlist.
- Independent review passed the full 75-test Dart suite, clean Flutter
  analysis, Go build, fresh full Go tests and the accepted dynamic vet check.
  The optional host Slipstream bridge integration test was skipped because its
  client/server inputs were not supplied. Kotlin, APK and previous CI-gate
  acceptance checks were not repeated for this source-build task.
- Both review findings were accepted and fixed: unchecked native-cache reuse
  and empty-array handling for a stale x86 directory under Bash nounset. Repeat
  review approved the fixes and found no new regressions. No findings were
  rejected or deferred because of repair cost. Bash 3.2 compatibility was
  checked by semantics and focused probes; execution on Bash 3.2 was not tested.
- No generated binary is included in this change. The tracked ARM64 file was
  restored to its original bytes and mode after preserving checked build
  results; other generated executables and native caches remain ignored.
  CI artifact production, removal of the tracked prebuilt, packaging, Android
  runtime smoke tests and general build documentation remain later tasks.
