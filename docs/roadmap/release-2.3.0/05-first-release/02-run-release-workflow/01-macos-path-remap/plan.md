---
kind: task
status: done
detailed: true
---

# Remap the paths in the macOS Slipstream build

## Task

The first `Build and Release` run of `v2.3.0-beta` failed in both macOS jobs at
`Check libraries for machine paths` (`release.yml:179-180`,
`release.yml:256-257`). `go_src/libdnstt.dylib` is clean, but
`macos/Runner/Libraries/slipstream-client` embeds the runner's checkout path
from two independent sources: the picoquic C sources (`DBG_PRINTF` keeps
`__FILE__`, `vendor/slipstream-rust/vendor/picoquic/picoquic/picoquic_utils.h:130-136`)
and the vendored OpenSSL `engines-3` and `ossl-modules` strings that its
Configure writes from the build prefix. The two `cargo build` steps
(`release.yml:171-177`, `release.yml:248-254`) remap only Rust paths through
`RUSTFLAGS`; the C/C++ compilation and the OpenSSL string macros are untouched.

`scripts/build_slipstream_android.sh:236-247` already solved both problems for
the three Android ABIs: Rust `--remap-path-prefix`, `-ffile-prefix-map` in
`CFLAGS`/`CXXFLAGS`, and `-UENGINESDIR`/`-UMODULESDIR` with neutral values in
`CPPFLAGS`. Its outputs pass `scripts/check_binary_paths.sh` without an
allowlist ([02-slipstream-abi/01-android-cross-build](../../../02-slipstream-abi/01-android-cross-build/plan.md),
"Outcome").

This task applies the same pattern to macOS through one script called by both
jobs, so the two jobs cannot drift, and runs the path check on the built binary
before it replaces the tracked `macos/Runner/Libraries/slipstream-client`.

## Steps

1. Create `scripts/build_slipstream_macos.sh` with `#!/bin/bash`, mode `0755`
   and `set -euo pipefail`. Resolve the project directory and
   `vendor/slipstream-rust` from the script's own location using
   `cd … && pwd -P`, not `readlink -f` (macOS `/bin/bash` is 3.2). Require
   `uname -s` to be `Darwin`, `HOME` to be set, and the vendored `Cargo.toml`
   and `vendor/picoquic/CMakeLists.txt` to exist; on a missing submodule, fail
   with the `git submodule update --init --recursive vendor/slipstream-rust`
   instruction instead of building something else.
2. Export into the environment of the `cargo build` the values the
   `slipstream-ffi` build script and its picoquic CMake step inherit:
   - `CARGO_ENCODED_RUSTFLAGS` with
     `--remap-path-prefix=<vendor/slipstream-rust>=/build/s` and
     `--remap-path-prefix=$HOME=/_`, the same pair the workflow uses today, in
     the encoded form of `scripts/build_slipstream_android.sh:239-240`;
   - `CFLAGS` and `CXXFLAGS` built with `printf '%q %q'` from
     `-ffile-prefix-map=<vendor/slipstream-rust>=/build/s` and
     `-ffile-prefix-map=$HOME=/_`, with `CC_SHELL_ESCAPED_FLAGS=1`, as in
     `scripts/build_slipstream_android.sh:241-244`. `slipstream-ffi/build.rs`
     compiles its C helpers through `cc` and invokes
     `vendor/slipstream-rust/scripts/build_picoquic.sh`, which inherits
     `CFLAGS` into the picoquic and picotls CMake configure
     (`crates/slipstream-ffi/build/picoquic.rs:31-59`);
   - `CPPFLAGS` with the OpenSSL overrides, copied verbatim:
     `-UENGINESDIR -DENGINESDIR=\"/build/s/openssl/engines\" -UMODULESDIR -DMODULESDIR=\"/build/s/openssl/modules\"`
     (`scripts/build_slipstream_android.sh:245-247`). A compile-time prefix map
     cannot rewrite the values Configure defines as macros; the vendored build
     is static and has no external modules, so the neutral values are not read
     at run time.
3. Build from `vendor/slipstream-rust` with exactly the command the two
   workflow steps run now: `cargo build -p slipstream-client --release
   --features openssl-vendored`. First unset `PICOQUIC_INCLUDE_DIR`,
   `PICOQUIC_LIB_DIR`, `PICOTLS_INCLUDE_DIR` and `OPENSSL_NO_VENDOR`, as
   `scripts/build_slipstream_android.sh:252` does, so the build cannot silently
   use a preinstalled library that the remaps do not cover. Do not add
   `--locked`, a cache, a target directory override or an architecture
   argument; the macOS jobs are uncached and each builds for its own runner.
4. Run `scripts/check_binary_paths.sh` on the built
   `target/release/slipstream-client` **before** copying it. Only a clean file
   is copied to `macos/Runner/Libraries/slipstream-client` and made executable
   (`chmod 0755`); a failure leaves the tracked file untouched. The workflow's
   existing check then verifies the staged file together with
   `go_src/libdnstt.dylib`.
5. Replace the bodies of `Build slipstream-client for macOS ARM64` and `Build
   slipstream-client for macOS Intel` with `run:
   scripts/build_slipstream_macos.sh`. Keep the step names and the following
   `Check libraries for machine paths` steps unchanged; do not add a matrix, an
   `env:` block with duplicate flags or an architecture input.
6. Validate what can be validated without macOS: `bash -n` and ShellCheck on
   the script, a YAML parse of `release.yml` if a parser is available
   (`actionlint` was unavailable in earlier tasks), and `git diff --check`.
   With the host `clang`, compile a temporary file with the same
   `-ffile-prefix-map` value and the `-D`/`-U` macro pair from the `CPPFLAGS`
   line, and confirm with `strings` that the absolute host path is absent. This
   proves the flags' semantics only; the workflow rerun in
   [02-move-tag-and-rerun](../02-move-tag-and-rerun/plan.md) is the real test.
7. After review, commit the new script, the two `release.yml` step bodies and
   this plan following the repository commit rules. Do not push, tag, run a
   workflow or touch the tracked macOS binary. `git status --porcelain` names
   only the new script, `release.yml` and the plan; the tracked
   `macos/Runner/Libraries/slipstream-client` and the vendored tree stay
   unchanged.

## Done when

- `scripts/build_slipstream_macos.sh` exists as mode `0755`, passes `bash -n`
  and ShellCheck, and both macOS jobs call it; the two duplicated `cargo
  build` blocks are gone.
- The environment the script exports carries the Rust remap, both
  `-ffile-prefix-map` values and both OpenSSL macro overrides with the same
  values as `scripts/build_slipstream_android.sh`; the build command is
  unchanged apart from those variables.
- The script checks the built binary with `scripts/check_binary_paths.sh`
  before replacing `macos/Runner/Libraries/slipstream-client`; the workflow
  still checks both libraries in both jobs, with no allowlist and no skipped
  step.
- `git diff --check` and a YAML parse of `release.yml` pass; the diff contains
  only the new script and the two step bodies, and `ci.yml`, the Android build
  script and the Android jobs are untouched.
- The host-compiler probe shows the prefix map and the macro overrides hiding
  the absolute path; the macOS effect is explicitly left to the rerun in
  [02](../02-move-tag-and-rerun/plan.md).

## Risks and what is needed from the user

- Apple clang and the macOS OpenSSL Configure are not available here, so the
  first real proof is the release rerun. If the check still reports paths, the
  stage gets another node built from the strings it prints; do not widen the
  allowlist or skip the check.
- `CFLAGS`/`CPPFLAGS` reach the picoquic CMake configure only through the
  build-script environment. Do not move them into the vendored
  `build_picoquic.sh`, do not edit `vendor/`, and do not rely on a local build
  cache: a stale `.picoquic-build` or Cargo target can hide a flag change,
  while CI starts cold.
- The script must stay macOS-only: on another host it would stage a foreign
  binary over the tracked `macos/Runner/Libraries/slipstream-client`.
- No outward action is part of this task. The push and the tag move in
  [02](../02-move-tag-and-rerun/plan.md) need the user's explicit go-ahead.

## Outcome

- Added `scripts/build_slipstream_macos.sh` (mode `0755`, `#!/bin/bash`,
  `set -euo pipefail`). It resolves the project and the vendored checkout from
  its own location with `cd … && pwd -P`, refuses to run where `uname -s` is
  not `Darwin` or `HOME` is unset, and fails with the
  `git submodule update --init --recursive vendor/slipstream-rust` instruction
  when the pinned sources are missing.
- The exported environment is copied verbatim from
  `scripts/build_slipstream_android.sh`: the `\x1f`-encoded
  `CARGO_ENCODED_RUSTFLAGS` with `--remap-path-prefix` for the checkout and
  `$HOME`, `CFLAGS`/`CXXFLAGS` built with `printf '%q %q'` from two
  `-ffile-prefix-map` values, `CC_SHELL_ESCAPED_FLAGS=1`, and the
  `-UENGINESDIR`/`-UMODULESDIR` overrides with neutral
  `/build/s/openssl/{engines,modules}` values. The four preinstalled-library
  variables are unset before building. The three shared lines are
  byte-identical to the Android script, so the two platforms cannot drift.
- The build command is unchanged:
  `cargo build -p slipstream-client --release --features openssl-vendored`,
  without `--locked`, a cache, a target-directory override or an architecture
  argument.
- `scripts/check_binary_paths.sh` runs on `target/release/slipstream-client`
  before copying; only a clean file replaces
  `macos/Runner/Libraries/slipstream-client` and is made mode `0755`. A failed
  check exits non-zero and leaves the tracked file untouched.
- Both macOS jobs now call the script; the two duplicated `cargo build` blocks
  are gone, while the step names, the following `Check libraries for machine
  paths` steps and every other job are unchanged. `ci.yml`, the Android build
  script, the vendored submodule and the tracked binary are untouched.
- Verified without macOS: `bash -n`, ShellCheck 0.9.0, a YAML parse of
  `release.yml`, `git diff --check`, and the Go tests and vet. The Dart
  analyzer and suite were not run because Flutter was not available in the
  working environment; the change touches no Dart code. A host `clang` probe
  with the same prefix map and the same macro pair showed the absolute path
  absent and the neutral values present, including the exact `CPPFLAGS`
  through a make recipe, which is how OpenSSL and CMake receive it; the same
  probe without the flags kept the absolute path, so it does detect a leak.
  Running the script on a non-Darwin host exited with the Darwin-only error and
  left the tracked binary's hash unchanged.
- Review found no blocking findings and accepted no fixes. What remains
  unproven is the macOS build itself: Apple clang, the macOS OpenSSL Configure
  on a cold runner, and the final `check_binary_paths.sh` on the built binary.
  Only the rerun in [02](../02-move-tag-and-rerun/plan.md) shows that.
- Left as it was: `scripts/build_slipstream_desktop.sh` still builds the macOS
  `slipstream-client` without the remaps and overwrites the tracked binary
  without running the path check. That predates this task and was not widened
  here; a local desktop build can put machine paths back into the tracked file.
