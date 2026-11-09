---
kind: task
status: done
detailed: true
depends: [01-android-share-removal]
---

# Remove the sharing API from the Go mobile library

## Task

Remove the Go-side "share proxy" API: the `shareProxy` field of `DnsttClient`,
`SetShareProxy`, `IsShareProxyEnabled` and the `0.0.0.0` rewrite in `Start`.
`Listen` must use the caller's address unchanged; every app caller passes
loopback.

The same pass removes `GetLocalIPAddresses` and `isPrivateIP`. They are exported
by gomobile but nothing in `android/`, `lib/` or `go_src/desktop` calls them,
and they exist to display a LAN address for the removed mode. Removing them
also makes the `strings` import unused.

`go_src/desktop/desktop.go` and the Dart FFI bindings do not mirror the sharing
API: the C exports take `listenAddr`, and `dnstt_ffi_service.dart` defaults to
`127.0.0.1:1080`. No desktop or Dart change is needed. The Kotlin call sites are
already removed by [01-android-share-removal](../01-android-share-removal/plan.md),
so replacing the AAR after this change cannot break the app build.

The task also rebuilds `android/app/libs/dnstt.aar` from the edited source and
checks its exported symbols: the prepared AAR still exports `setShareProxy` and
`isShareProxyEnabled` (see the neighbour's `## Outcome`), and node
[03-verify-local-only](../03-verify-local-only/plan.md) builds a debug APK on top
of the rebuilt file. The AAR is not in git (`android/app/libs/` is ignored); CI
builds it from `go_src/` on every commit with `.github/workflows/build-aar.yml`.
`go_src/mobile` has no Go tests, so the exported surface is checked on the built
AAR rather than by a unit test. The documentation mentions of the old API in
`docs/` are left for [04-docs-and-review](../04-docs-and-review/plan.md).

## Steps

1. `go_src/mobile/mobile.go`: delete the `shareProxy` field of `DnsttClient`
   (line 56) and the methods `SetShareProxy` and `IsShareProxyEnabled`
   (111-123). In `Start`, delete the "Determine the listen address based on
   proxy sharing" block (182-191) and pass `c.listenAddr` straight to
   `net.Listen("tcp", c.listenAddr)` (194). Keep the startup log, the mutex and
   every other field and method (`SetBootstrap`, `SetTLSFingerprint`,
   `SetTunFd`, `SetSocketProtector`, `options`, `Stop`, `IsRunning`,
   `DialTunnel`, the accept loop).

2. Same file: delete `GetLocalIPAddresses` (386-427) and `isPrivateIP`
   (429-447), then remove `"strings"` from the import block (12). `"net"` stays:
   `net.Listener`, `net.Conn`, `net.Listen` and `net.TCPConn` are still used. No
   other function uses `strings`, so leaving the import breaks compilation.

3. Check for leftovers before building:
   `grep -RIn "ShareProxy\|shareProxy\|GetLocalIPAddresses\|isPrivateIP" go_src android/app/src/main/kotlin lib`
   prints nothing, and `grep -RIn '0\.0\.0\.0' go_src/mobile` prints nothing.
   `go_src/dnstt-server`, `go_src/desktop`, `lib/` and `docs/` must not change in
   this task. `go_src/desktop` builds against `mobile.NewClient` only; confirm
   that with the grep rather than editing it.

4. Run the Go checks locally:
   `(cd go_src && go build ./... && go test ./...)`, then the filtered vet from
   `ci.yml`:
   `noise_package=$(go list ./noise); go list ./... | grep -Fvx "$noise_package" | xargs -r go vet`
   (the `noise` package is excluded because its upstream test calls `t.Fatal`
   from goroutines). All three must pass before the AAR is built.

5. Rebuild the AAR: run `./scripts/build_aar.sh` from the project root. The
   script copies `go_src/` to a fixed build directory, installs the pinned
   `gomobile`/`gobind`, binds `android/arm`, `android/arm64` and `android/amd64`,
   writes `android/app/libs/dnstt.aar` and runs `scripts/check_binary_paths.sh`
   on it. It needs the Go toolchain pinned in `go_src/go.mod` (downloaded on
   first use), `javac`, the Android SDK and NDK 28.2.13676358 (or a matching
   `NDK_VERSION`), plus the gomobile module in the module cache or network
   access to download it. Success prints `Wrote …/dnstt.aar` and an `ok:` line
   for each of the three `libgojni.so`; any `FAIL` aborts the script.
   **If a prerequisite is missing or the tools cannot be downloaded, stop and
   report the missing piece to the lead. Do not mark this node done with the
   old AAR, do not commit an AAR, and never hand-edit the generated
   `classes.jar` or `jni/` contents.**

6. Check the exported symbols of the rebuilt AAR. The Java stubs are in
   `classes.jar`, and the JNI entry points and Go names are in
   `jni/*/libgojni.so` (the current AAR has them in all three ABIs even with
   `-s -w`, so checking `classes.jar` alone is not enough):

   ```
   tmp=$(mktemp -d)
   unzip -q android/app/libs/dnstt.aar -d "$tmp"
   javap -classpath "$tmp/classes.jar" mobile.DnsttClient mobile.Mobile
   unzip -p "$tmp/classes.jar" '*.class' | strings | grep -iE 'shareProxy|LocalIPAddresses|isPrivateIP'
   strings "$tmp"/jni/*/libgojni.so | grep -iE 'SetShareProxy|IsShareProxyEnabled|GetLocalIPAddresses|isPrivateIP'
   ```

   The `javap` output must list no `setShareProxy`, `isShareProxyEnabled` or
   `getLocalIPAddresses`, and both greps must print nothing. As a sanity check,
   `javap` must still list `newClient`, `resolverKind`, `udpResolverAddr`,
   `startBridge`, `probeResolver` and `connectWithTunFd` on `mobile.Mobile`,
   and `setBootstrap`, `setTLSFingerprint`, `setTunFd`, `setSocketProtector`,
   `start`, `stop` and `isRunning` on `mobile.DnsttClient`.

7. Compile the app against the rebuilt AAR and run the Kotlin unit tests:
   `(cd android && ./gradlew :app:testDebugUnitTest)`. This is the check that no
   Kotlin caller of a removed method remains: the compiler sees the new AAR, not
   the prepared one. Expect the same tests as before the change (11 in the
   neighbour's outcome; the count is observed, not fixed) with 0 failures. The
   Gradle build needs the prepared `jniLibs` executables and the
   `vendor/hev-socks5-tunnel` submodule, both present in the work tree. The full
   Flutter suite and the debug APK belong to
   [03-verify-local-only](../03-verify-local-only/plan.md).

8. Check the diff before reporting: `git status --short` shows only
   `go_src/mobile/mobile.go` outside the map, and
   `git check-ignore -q android/app/libs/dnstt.aar` succeeds. Nothing generated
   is staged; the coordinator commits only the Go file and this plan, never the
   AAR.

## Done when

- `grep -RIn "ShareProxy\|shareProxy\|GetLocalIPAddresses\|isPrivateIP" go_src`
  is empty, `go_src/mobile` contains no `0.0.0.0`, and `Start` passes
  `c.listenAddr` unchanged to `net.Listen`.
- `cd go_src && go build ./... && go test ./...` pass, and the filtered `go vet`
  from `ci.yml` passes (every package except `noise`).
- `./scripts/build_aar.sh` succeeds on the edited tree, prints `Wrote` for
  `android/app/libs/dnstt.aar`, and its path check prints `ok:` for the AAR's
  three `libgojni.so` with no `FAIL`.
- `javap` on the unpacked `classes.jar` shows no `setShareProxy`,
  `isShareProxyEnabled` or `getLocalIPAddresses`, and `strings` over the class
  files and each `jni/*/libgojni.so` finds none of `SetShareProxy`,
  `IsShareProxyEnabled`, `GetLocalIPAddresses` or `isPrivateIP`; the sanity
  methods from step 6 are still present.
- `(cd android && ./gradlew :app:testDebugUnitTest)` passes.
- Outside the map, the diff contains only `go_src/mobile/mobile.go`; the rebuilt
  AAR is ignored by git and is not staged; no other Go package, Kotlin, Dart,
  desktop, Gradle, CI or docs file is changed.
- The node is not reported as done if the AAR was not rebuilt in this session:
  a missing SDK, NDK, JDK, Go toolchain or gomobile download is reported to the
  lead as a blocker, because the old AAR still contains the removed methods and
  would make the `javap` check fail.

## Risks and what is needed from the user

- `scripts/build_aar.sh` installs the pinned `gomobile`/`gobind` into a
  temporary directory and may need the Go module cache or network. If it cannot
  run offline, report it rather than committing a stale AAR or editing
  generated files by hand. The same applies if the Android SDK, NDK
  28.2.13676358 or `javac` is missing.
- Dropping `GetLocalIPAddresses` without dropping the `strings` import fails
  compilation; check the import block after the edit.
- `javap` alone checks only the Java stubs; the native libraries carry the JNI
  entry points and Go method names, so both checks in step 6 are required.
- The Kotlin check is meaningful only after step 5: with the prepared AAR it
  compiles either way and would hide a leftover caller.
- `android/app/libs/dnstt.aar` is already present and ignored by git; a
  successful local build overwrites it in place. The AAR is never committed and
  the generated file must not appear in `git status`.
- The task needs no server or device. If the AAR build cannot run in the
  session's environment, the user has to provide the missing build prerequisite
  or run the build where it is available; a CI artifact is not a substitute
  unless the same symbol check is run on it.

## Outcome

- `go_src/mobile/mobile.go` no longer carries the sharing API: the `shareProxy`
  field, `SetShareProxy`, `IsShareProxyEnabled`, the `0.0.0.0` rewrite in
  `Start`, `GetLocalIPAddresses`, `isPrivateIP` and the then-unused `strings`
  import are gone. `Start` passes `c.listenAddr` unchanged to
  `net.Listen("tcp", c.listenAddr)`; the startup log, the mutex, the other
  fields and methods, the accept loop and `ConnectWithTunFd` are unchanged.
  `go_src/desktop`, `go_src/dnstt-server`, Kotlin, Dart, Gradle, CI and `docs/`
  were not touched; the desktop C exports and the e2e test use only the
  remaining `mobile` API.
- The step-3 greps over `go_src`, `android/app/src/main/kotlin` and `lib` print
  nothing, and `go_src/mobile` contains no `0.0.0.0`. `go build ./...`,
  `go test ./...` and the filtered `go vet` from `ci.yml` (every package except
  `noise`) pass; `gofmt` is clean.
- `./scripts/build_aar.sh` rebuilt `android/app/libs/dnstt.aar` from the edited
  source: it printed `Wrote` and `ok:` for the `arm64-v8a`, `armeabi-v7a` and
  `x86_64` `libgojni.so`, with no `FAIL`. `javap` on the unpacked `classes.jar`
  lists none of `setShareProxy`, `isShareProxyEnabled`, `getLocalIPAddresses`,
  and `strings` over the class files and all three native libraries finds none
  of the removed names; the sanity methods of step 6 (`newClient`,
  `resolverKind`, `udpResolverAddr`, `startBridge`, `probeResolver`,
  `connectWithTunFd`, `setBootstrap`, `setTLSFingerprint`, `setTunFd`,
  `setSocketProtector`, `start`, `stop`, `isRunning`) are still exported.
- `(cd android && ./gradlew :app:testDebugUnitTest)` compiles the app against
  the rebuilt AAR and passes: 11 tests (6 `Socks5AuthRelayTest`, 5
  `Tun2SocksTest`), 0 failures. The review reran the task so Kotlin was
  recompiled against the new AAR instead of being taken `UP-TO-DATE`.
- Outside the map the diff contains only `go_src/mobile/mobile.go`; the AAR is
  ignored by git (`.gitignore`) and is not staged. The step-6 command in this
  plan was corrected during acceptance to unpack the whole AAR
  (`unzip -q android/app/libs/dnstt.aar -d "$tmp"`), because extracting
  `classes.jar` alone left no `jni/` directory for the native-library check.
- The documentation mentions of the removed API are left for
  [04-docs-and-review](../04-docs-and-review/plan.md); the debug APK, the full
  Flutter suite and the listener inventory belong to
  [03-verify-local-only](../03-verify-local-only/plan.md). Independent review
  found no defects or regressions.
