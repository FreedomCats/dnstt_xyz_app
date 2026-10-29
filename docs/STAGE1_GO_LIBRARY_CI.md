# Stage 1: build the Go library from source in CI

Stage 1 of `docs/DOH_DOT_TUN2SOCKS_PLAN.md`. Every later stage changes Go code
in `go_src/`, so the Android library (`dnstt.aar`) must be built from the
sources at each commit, not taken from a prebuilt file.

## Starting point

- `android/app/libs/dnstt.aar` (7 MB) and `dnstt-sources.jar` are committed,
  built by upstream outside CI. The AAR was built from the current `mobile`
  package with the dependency versions in `go_src/go.mod`, with Go 1.25 and
  `-trimpath`, from a copy in `/tmp/dnstt_build` (the path of that copy is
  recorded in the Go build info, `-trimpath` does not remove it). It has four
  ABIs, including `x86`, which Flutter does not build.
- Its Java API: `mobile.Mobile.newClient`, `getLocalIPAddresses`,
  `connectWithTunFd`, and `mobile.DnsttClient` (`start`, `stop`, `isRunning`,
  `setShareProxy`, `isShareProxyEnabled`, `setTunFd`).
- CI (`ci.yml`) and `release.yml` use the committed AAR. Go comes from
  `go-version-file: go_src/go.mod`, which has only `go 1.24.0`, so CI runs Go
  1.24.0, a release that no longer gets security fixes.
- The macOS release jobs already build `libdnstt.dylib` and
  `slipstream-client` from source with path stripping, but nothing checks the
  result for machine paths.

## Steps

1. **Pin the Go toolchain.** Add `toolchain go1.26.10` to `go_src/go.mod`.
   CI (`setup-go` with `go-version-file`) and local builds (`GOTOOLCHAIN=auto`
   downloads it) then use the same supported release. The `go 1.24.0`
   language version stays.

2. **`scripts/check_binary_paths.sh FILE...`.** Fails if a binary contains
   paths from the build machine (`/home/`, `/Users/`, `/root/`,
   `C:\Users`). Archives (`.aar`, `.apk`, `.jar`, `.zip`) are unpacked and
   every native library inside is checked. This is the check `AGENTS.md`
   requires before committing or shipping a binary.

3. **`scripts/build_aar.sh`.**
   - Requires Go, a JDK (gomobile compiles Java classes) and the Android NDK
     (`ANDROID_NDK_HOME`, or `$ANDROID_HOME/ndk/<version>` with the version
     Flutter uses, 28.2.13676358).
   - Copies `go_src` to the fixed directory `/tmp/dnstt_build` (a fixed path:
     it ends up in the build info, and a constant keeps builds reproducible
     and free of user paths).
   - Installs `gomobile` and `gobind` at the version pinned in `go.mod`
     (`golang.org/x/mobile`) into the build directory, not into the user's
     `GOBIN`.
   - `gomobile bind` with `-trimpath`, `-ldflags="-s -w"`, `-androidapi 21`,
     targets `android/arm,android/arm64,android/amd64` (the ABIs Flutter
     builds).
   - Writes `android/app/libs/dnstt.aar` (no `-sources.jar`) and runs the path
     check on it.

4. **Local verification.**
   - The new AAR exposes the same Java API as the old one (`javap` on
     `classes.jar`).
   - The path check passes; two builds in a row give identical `.so` files.
   - Kotlin unit tests pass and the debug APK builds with the new AAR.

5. **Gradle guard.** `android/app/build.gradle.kts` fails `preBuild` with a
   clear message ("run scripts/build_aar.sh") when `libs/dnstt.aar` is missing,
   instead of failing later on unresolved `mobile.*` classes.

6. **Remove the prebuilt files from git.** `git rm android/app/libs/dnstt.aar
   android/app/libs/dnstt-sources.jar`; `.gitignore` ignores them instead of
   whitelisting `*.aar`.

7. **CI.**
   - New reusable workflow `.github/workflows/build-aar.yml`
     (`workflow_call`): JDK 17, Go from `go.mod`, NDK 28.2.13676358 through
     `sdkmanager`, `scripts/build_aar.sh`, upload the `dnstt-aar` artifact.
     The job summary lists the SHA-256 of the AAR and of each `.so`.
   - `ci.yml`: an `aar` job calls it; `test` and `build-android` need it and
     download the artifact into `android/app/libs/` before Gradle runs.
   - `release.yml`: the same for `build-android`; the release does not ship
     the AAR itself.
   - APKs: the path check also runs on the built APKs.
   - macOS release jobs: run the path check on `libdnstt.dylib` and
     `slipstream-client` before bundling.

8. **Documentation.** `CLAUDE.md` (project structure, "Building the Go Mobile
   Library", development workflow, quick reference), `docs/STATUS.md`.

9. **Commit, push, follow CI** until `ci.yml` is green. The APK artifact then
   contains the AAR built in CI.

## Done when

- `ci.yml` is green and builds the AAR from `go_src` at the same commit.
- The repository no longer contains `dnstt.aar`.
- The path check passes on the AAR and the APKs.

## After this stage

- The user installs a CI APK on the phone and checks that DNSTT still connects
  (the Go code is the same; the toolchain and build are new). Slipstream is
  unaffected.
- Not in this stage: building `libslipstream_client.so` for Android in CI and
  for all ABIs (`docs/STATUS.md`, next steps 3.3). It does not block the
  DoH/DoT work and can follow as a separate stage.
