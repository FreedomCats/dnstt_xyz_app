---
kind: task
status: done
detailed: true
depends: [01-android-cross-build]
---

# Build and publish checked Slipstream ABI artifacts in CI

## Task

Run the verified Android cross-build as a reusable CI job, keep its expensive
Rust and per-ABI picoquic outputs cached without mixing architectures, and
publish the three path-checked executables as one Gradle-ready artifact.

Use the accepted script from
[01-android-cross-build](../01-android-cross-build/plan.md) unchanged. Its
`## Outcome` records successful cold and warm builds and strict native-cache
validation. The design is in `docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md`, section
5.4; the delivery policy and scope are in the [parent](../plan.md).

The implementation touches only `.github/workflows/build-slipstream-android.yml`
and the producer call in `.github/workflows/ci.yml`. Artifact downloads in APK
consumers, release wiring, the tracked ARM64 removal, `.gitignore`, Gradle
guards and APK checks belong to [03-apk-packaging](../03-apk-packaging/plan.md).
Android runtime checks and general documentation belong to children 04 and 05.

## Steps

1. Add `.github/workflows/build-slipstream-android.yml` with `workflow_call`,
   `permissions: contents: read` and one `ubuntu-latest` build job, following
   `.github/workflows/build-aar.yml`. Use `actions/checkout@v7` at the caller's
   revision with recursive submodules; do not fetch moving submodule branches
   or use `git submodule update --remote`. Keep the pinned Slipstream/picoquic
   gitlinks, vendored source and build script unchanged. The job needs no
   signing secrets, inherited secrets or additional workflow trigger.
2. Provision tools inside that CI job before deriving cache keys. Install NDK
   `28.2.13676358` through the runner SDK and set both `ANDROID_NDK_HOME` and
   `ANDROID_NDK_ROOT` to its resolved directory, overriding runner defaults.
   Verify `source.properties`. Follow the existing
   `dtolnay/rust-toolchain@stable` convention in `release.yml`, installing only
   the Android targets `aarch64-linux-android`, `armv7-linux-androideabi` and
   `x86_64-linux-android`; install cargo-ndk with
   `cargo install cargo-ndk --version 4.1.2 --locked` and verify its version.
   Check the script's remaining prerequisites, including CMake, make, Perl and
   pkg-config. This CI setup authorizes no local Rust upgrade, installation of
   SDK/system packages or license acceptance.
3. In the new workflow, derive a versioned Android-only build-cache key after
   checkout and tool setup. Hash all compatibility inputs rather than using
   `github.sha` or a run ID, so unrelated app commits can reuse the cache.
   Include runner OS/architecture and hosted image identity, NDK revision,
   API 21, the exact three-target set, release/client-only/`openssl-vendored`
   settings, resolved Rust/Cargo and cargo-ndk versions, both pinned source
   revisions, the Cargo lockfile and build-script content identities, and the
   producer workflow's content identity. Reproduce the script's `native_context`
   calculation at `scripts/build_slipstream_android.sh:150`: the Slipstream
   source path, `HOME`, canonical NDK path, full `rustc --version` and
   `cmake --version` output, and `CMAKE_GENERATOR`, including the empty value.
   Include any additional native build settings supplied by the workflow.
   Keep these values unchanged between key calculation and script execution;
   put their digest in the key rather than exposing paths in summaries.
4. Cache one coupled build bundle: `vendor/slipstream-rust/target/` and the
   complete `.picoquic-build/aarch64-linux-android/`,
   `.picoquic-build/armv7-linux-androideabi/` and
   `.picoquic-build/x86_64-linux-android/` directories under that submodule.
   Preserve each directory's `.android-build-stamp`, CMake files, fetched
   headers and archives. CMake references the vendored OpenSSL output inside
   `target`, so do not restore native directories and Cargo target from
   independently selected cache entries. Use explicit `actions/cache/restore@v5`
   and `actions/cache/save@v5`, with no broad `restore-keys` or cross-OS reuse.
   Check for an exact hit with `lookup-only` before restoring; restore only
   when `cache-hit == 'true'` and assert that the actual restore also matched
   the requested key. A miss leaves all four directories cold. Do not restore
   shared desktop `.picoquic-build` outputs, `jniLibs`, source checkouts or an
   automatically restored generic Rust target cache. Save a new bundle only
   on a miss, after a successful three-target build and final output checks,
   never on failure or cancellation. Leave unknown, mismatched or incomplete
   native caches intact and let the script reject them; do not delete caches, rewrite
   stamps, suppress errors or weaken script validation to obtain a green job.
5. Invoke `scripts/build_slipstream_android.sh` once from the project root,
   retaining its sequential, locked release/client-only build with vendored
   OpenSSL and API 21. Do not add an ABI matrix, duplicate the cross-build
   commands in YAML or skip the script on a cache hit. After it succeeds,
   explicitly require a regular, non-symlinked, non-empty executable at each of
   `android/app/src/main/jniLibs/arm64-v8a/libslipstream_client.so`,
   `android/app/src/main/jniLibs/armeabi-v7a/libslipstream_client.so` and
   `android/app/src/main/jniLibs/x86_64/libslipstream_client.so`. Run
   `scripts/check_binary_paths.sh` on those three explicit paths, with no path
   allowlist. Keep the script's ELF checks authoritative. A failed build or
   check must prevent upload, even while the old ARM64 file remains tracked.
6. Copy only those verified outputs, preserving mode, into a temporary artifact
   staging root with exactly these relative entries:
   `arm64-v8a/libslipstream_client.so`,
   `armeabi-v7a/libslipstream_client.so` and
   `x86_64/libslipstream_client.so`. Upload that root once with
   `actions/upload-artifact@v7`, fixed name `slipstream-android-jni`,
   `retention-days: 14` and `if-no-files-found: error`. Do not flatten the ABI
   directories or add an enclosing `jniLibs`/artifact-name directory inside
   the payload. Explicit per-file checks are required because the upload
   action's missing-file option alone does not detect a partially missing set.
   Record source revisions, resolved tool versions, exact-hit/miss status and
   per-file SHA-256 values with relative names in the job summary. Document
   the consumer contract in workflow comments: task 03 downloads this named
   artifact from the same workflow run directly into
   `android/app/src/main/jniLibs/`, requires all three files, applies
   `chmod 0755` to the three explicit paths, and verifies `test -x` before
   Gradle. GitHub's zipped artifact transport does not preserve executable
   mode; do not introduce a tar wrapper, alternate payload layout or download
   fallback to address that.
7. Add an unconditional top-level `slipstream-android` job to
   `.github/workflows/ci.yml` using
   `./.github/workflows/build-slipstream-android.yml`, alongside `aar`.
   Preserve existing test/build job dependencies and gate commands in this
   task; task 03 adds producer dependencies and downloads wherever Gradle runs,
   including the current `test` job's Kotlin unit tests. Do not modify
   `release.yml` or signing behavior here.
8. Validate the two workflow files and their embedded shell blocks using
   available YAML/action lint tools, `bash -n`, ShellCheck and
   `git diff --check`; record any unavailable lint tool without installing new
   local prerequisites. Use focused fixtures for cache-key derivation: equal
   inputs give the same key, and changing each stamp/context component, source,
   script, lockfile, toolchain or target set changes it. Check that a non-exact
   lookup cannot restore build outputs and that failed/partial builds cannot
   save the bundle or upload the payload. Reuse task 01's evidence instead of
   repeating local native builds or its prerequisite/cache rejection harness.
   After review and preparation of the concrete commit, lead obtains separate
   permission for its publication and observes the normal `ci.yml` run at that
   revision. Verify actual producer completion, successful artifact upload and
   downloaded payload names, checksums and ELF machines. Apply the documented
   mode restoration to the downloaded copy and require three executable files.
   Record observed cache behavior honestly; claim a warm CI restore only when
   an authorized ordinary run actually exercises it. Do not dispatch or rerun
   workflows, push, create tags/releases/PRs or change credentials without the
   corresponding authorization. No additional APK/release builds or previous
   CI-gate probes are required by this producer task.

## Done when

- A reusable `.github/workflows/build-slipstream-android.yml` initializes
  the caller's pinned recursive source, provisions NDK `28.2.13676358`,
  cargo-ndk `4.1.2` and exactly the three Android Rust targets, and invokes the
  unchanged script for API 21. It requires only `contents: read` and no secrets.
- The build-cache identity covers every script stamp/context input and the
  remaining CI compatibility inputs above. Cargo target and the three complete,
  stamped per-triple native directories are restored together only on an exact
  key match and saved only after success. Different inputs cannot select a
  stale build bundle; rejected native caches remain preserved and fail the job.
  Focused key/restore/save checks pass.
- Every successful producer invocation builds or revalidates all three expected
  outputs, checks executable mode and ELF machine, and runs
  `scripts/check_binary_paths.sh` with `ok` for each file and no allowlist.
  Missing, empty, non-executable or path-containing outputs prevent upload.
- The single `slipstream-android-jni` artifact contains exactly the three
  `<abi>/libslipstream_client.so` entries, rooted at the contents of `jniLibs`,
  with missing-file failure enabled. Its documented same-run download
  destination and explicit `chmod 0755`/`test -x` contract are usable by task 03;
  downloaded bytes match the producer's per-file checksums and ELF machines.
- Workflow/shell validation and `git diff --check` pass, with unavailable
  optional lint tools reported. After separately authorized publication, a
  real normal `ci.yml` run at the prepared revision invokes and successfully
  completes the producer job, with the named artifact uploaded and inspected.
  Local YAML analysis is not remote acceptance; until that run is observed,
  the task remains unfinished. Existing normal CI jobs may run as usual, but
  APK consumer acceptance and release execution belong to task 03.
- The implementation diff is limited to the new producer workflow and its
  normal CI caller. No generated executable, source/gitlink change, local or
  remote binary fallback, or change owned by tasks 03–05 is included.

## Risks and what is needed from the user

The first uncached run compiles OpenSSL and picoquic three times and may take a
long time. Hosted image/tool updates or a different checkout, home or NDK path
must produce a cold cache miss rather than an incompatible restore. Preserve
the script's stamp and archive validation even after an exact CI cache hit;
cache reuse never replaces the output/path checks. A damaged exact-match entry
is a reported failure, not grounds for destructive repair in the workflow.

The artifact contract intentionally accounts for file-mode loss in GitHub
artifact transport. Task 03 must restore mode and download the payload before
every affected Gradle invocation, including Kotlin unit tests; task 04 proves
Android extraction/subprocess behavior. Local APK builds continue to require
the source script, with no remote download fallback.

The remote completion criterion required separate user permission to publish
the prepared commit and run normal CI. That permission was granted for the exact
pushes described below, and the producer and uploaded artifact have been
verified. It does not authorize any future push, rerun, release, or other remote
action. Any newly discovered need to change the accepted script, cache
validation, delivery policy or sibling scope goes back to lead first.

## Outcome

- Added a reusable producer workflow with read-only repository permission,
  recursive checkout of the caller's pinned revision, the pinned Android NDK,
  stable Rust with the three required targets, and cargo-ndk 4.1.2. The regular
  CI workflow invokes it as an independent producer job; existing job
  dependencies, checks and signing steps are unchanged.
- The versioned cache identity includes the accepted build script's native
  stamp/context inputs, source and picoquic revisions, lockfile and workflow
  identities, runner image, resolved tools, targets and Android build settings.
  Cargo and all three complete native build directories are looked up and
  restored together only on an exact key. The unchanged build script always
  runs; rejected cache data is preserved. A cache miss is saved only after the
  three outputs pass checks and the artifact upload succeeds.
- The producer validates the three explicit executable outputs, checks paths
  without an allowlist, and stages exactly the three ABI-relative
  `libslipstream_client.so` entries. It uploads one `slipstream-android-jni`
  artifact and records source/tool identities, cache status and relative-path
  SHA-256 values. Workflow comments specify same-run download, explicit mode
  restoration and executable checks before every Gradle invocation; consumers
  remain task 03 scope.
- The only authorized remote verification so far was normal `ci.yml` run
  `42526215253`, attempt 1, on push head `ac0986ddc3ad854ca6283930a1a163c1f3467749`.
  It completed with `failure`: `aar / build` (`128870301582`), `test`
  (`128870727651`, including Dart analysis/tests, Kotlin tests, Go tests and
  vet), and `build-android` (`128872126315`, including split APK/path/signing
  checks and upload) succeeded; `slipstream-android / build`
  (`128870301868`) failed at `Build all three Android ABIs`. Its exact cache
  lookup was cold. Cargo linked host build scripts for `x86_64-unknown-linux-gnu`
  through the temporary `cc` wrapper in the leading script directory, which
  invokes Android NDK clang; `rust-lld` could not find `gcc_s`, `util`, `rt` or
  `pthread`, and the step exited 101. The stage, JNI artifact upload and cache
  save were skipped. The run produced only `dnstt-aar` and `android-apks`, not
  `slipstream-android-jni`; no JNI artifact inspection or warm cache claim is
  applicable. The full producer log and terminal metadata are private evidence
  outside the repository.
- The producer workflow now explicitly assigns the discovered native host
  compiler to Cargo's host-triple linker setting while leaving cargo-ndk's
  Android target linkers intact. Its canonical path and version are included
  in the private cache manifest/key, with a schema/key version bump. The public
  summary reports only the compiler version, not its path. The accepted build script,
  Android target configuration, `ci.yml`, submodules and generated binaries
  were not changed. A focused host-linker fixture reproduced failure with an
  Android-like `cc` PATH shim and passed with the explicit host linker; it also
  checked deterministic cache identity and invalidation on host-linker path or
  version changes. Workflow YAML parsing, shell syntax, ShellCheck and
  whitespace checks passed for the correction. No local native ABI rebuild was
  performed.
- Local validation passed: both workflow files parse without duplicate YAML
  keys; `bash -n` passed for all 20 embedded shell blocks; all added shell
  blocks passed ShellCheck; and `git diff --check` passed. Focused cache,
  restore, output and artifact fixtures passed, including partial/missing,
  symlinked, non-executable and path-containing outputs and failed/cancelled
  build gates. `actionlint` and `yamllint` were unavailable and were not
  installed. Running ShellCheck over all of `ci.yml` also reports the existing
  SC2012 warning in the unchanged certificate-display step; new shell blocks
  are clean.
- Independent review found no implementation defects or regressions. Flutter
  analysis, all 75 Dart tests, Go build, the full Go test suite and the
  repository's dynamic vet selection passed. The optional Slipstream bridge
  integration test was skipped because its client/server inputs were not
  supplied. Kotlin/Gradle and APK checks, native rebuilds and previously
  accepted CI-gate probes were not repeated. Task 01's recorded cold/warm
  three-ABI build evidence was reused; generated binaries, the build script,
  gitlinks and vendored sources are unchanged.
- The user authorized exactly one ordinary fast-forward push through
  `ac0986d` and verification of its resulting normal run. The attempted push
  failed authentication; no credentials were changed or retry made, and the
  user then performed the authorized push. Run `42526215253` is terminal and
  failed only in the new producer as described above; the producer artifact is
  absent. Remote `develop` remains exactly at `ac0986d`. That authorization is
  consumed. The local host-linker correction now requires separate permission
  to publish its new exact head and inspect the resulting normal `ci.yml` run
  and producer artifact. Until then this task remains `blocked`; no push,
  dispatch, rerun, tag, release, PR, force push or other remote action has been
  performed for the correction.
- The user has now separately authorized one ordinary fast-forward push of
  exactly local commit `d03d5a1` on top of remote `ac0986d`, and inspection of
  the single resulting normal `ci.yml` run and producer artifact. A previous
  push used HTTPS without the authenticated GitHub CLI helper and was rejected;
  that attempt is distinct from this newly authorized retry. This retry must use
  a command-scoped `gh auth git-credential` helper, without changing persistent
  Git configuration or credentials. Only this exact ordinary fast-forward and,
  if successful, its one normal CI run/artifact inspection are authorized. No
  rerun, dispatch, tag, release, PR, force push, later push or other remote write
  is included.
- The one command-scoped-helper push succeeded and remote `develop` advanced to
  exact SHA `d03d5a1d63ee40dcd4d7ef6d2df92914e170b232`. Its sole normal `ci.yml`
  run `42532923754` (event `push`, branch `develop`) completed successfully:
  producer `128890910980`, AAR `128890911219`, test `128891278786`, and Android
  build `128892797065`. The test job passed analyzer, all 75 Dart tests, Kotlin
  unit tests, full Go tests and vet. The Android job passed split APK builds,
  machine-path/signature checks and artifact upload.
- The producer artifact `slipstream-android-jni` (ID `13637958775`, from the
  exact run/head) downloaded and passed ZIP integrity checks. It contains exactly
  `arm64-v8a/libslipstream_client.so`,
  `armeabi-v7a/libslipstream_client.so`, and
  `x86_64/libslipstream_client.so`, with no wrapper or extra entry. The downloaded
  ZIP SHA-256 `d09d1b1ba7ea8b6affede5459a656bcefb32b67cb910c284a0c82f96900242ca`
  exactly matches the upload action's recorded digest.
- Recomputed per-file SHA-256 values are `8ff4a8fe9ed2ddf45f52c08d0d59f7fb701ce0d86a31acf2c455f6b3ac5ca27d`
  (arm64-v8a), `60c2721d678f58ecb0c317d2bdf342fcd884ebdb78603e8b2c41201354a0e6b7`
  (armeabi-v7a), and `ec48bbb5099dd679fd91e468835f2665d2408146d8944f7ee78d6b8099cd2417`
  (x86_64). GitHub's per-file `GITHUB_STEP_SUMMARY` text is not exposed by the
  available read-only API, so these values could not be compared literally with
  the summary lines. Instead, the downloaded ZIP digest matches the digest
  recorded for the uploaded archive, and each extracted file is byte-identical
  to its independently checked task 01 build output. This verifies the uploaded
  payload contents without claiming direct access to the summary text.
- Artifact files are regular, non-empty executables with sizes 5,917,936,
  3,983,300, and 6,622,088 bytes. `readelf` confirmed AArch64, ARM and X86-64,
  Android interpreters `/system/bin/linker64`, `/system/bin/linker`, and
  `/system/bin/linker64`, and Android build note NDK r28c / build `13676358`.
  ZIP extraction did not preserve executable permissions; after `chmod 0755`,
  `test -x` passed for all three downloaded copies. The producer's path checker
  also reported `ok` for every staged binary.
- This first CI producer run had an exact-cache miss, built and uploaded all
  outputs, then saved the successful cache. A warm CI restore has not been
  observed and is not claimed. The local cold/warm source builds and task 01
  cache tests remain the evidence for script cache reuse.
- Task 02 is complete. The initial producer linker failure was corrected by
  selecting the runner host linker for host build scripts while preserving
  cargo-ndk's Android target linkers. No generated binary or vendored source was
  committed. There are no real problems left unfixed because of repair cost.
  Unavailable optional `actionlint`/`yamllint`, the pre-existing `SC2012` in an
  unchanged certificate step, and the skipped optional host bridge integration
  test are recorded above; all required CI jobs and artifact checks passed.
