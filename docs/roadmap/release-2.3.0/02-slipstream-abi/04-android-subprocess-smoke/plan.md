---
kind: task
status: done
detailed: true
depends: [03-apk-packaging]
---

# Verify Slipstream subprocess startup on Android ABIs

## Task

Add Android instrumentation smoke coverage for the packaged
`libslipstream_client.so`. On x86_64, the test initializes `SlipstreamBridge`
with the target application context, starts the subprocess with
documentation-only values, and proves the local TCP startup contract without
contacting a tunnel server or a real resolver. The accepted ARMv7-capable
runtime is an x86_64 Android image with ARM translation, because the current
emulator cannot boot 32-bit ARM system images. On that runtime the app's
existing Go library `libgojni.so` crashes under `libndk_translation` before the
bridge reaches the subprocess, so the ARMv7 side runs a separate small
instrumentation test that launches the same packaged `libslipstream_client.so`
directly and proves the same local TCP startup contract. The user accepted this
narrowed ARMv7 acceptance.

This task owns the test runner/dependencies and any narrowly required
`SlipstreamBridge.kt` startup or cleanup correction. It does not add CI or
release-runtime orchestration, repeat task 03's APK-content acceptance, or
perform a live tunnel check.

## Steps

1. Extend `android/app/build.gradle.kts` with
   `testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"` in
   `defaultConfig` and test-only AndroidX Test dependencies
   `androidx.test:runner:1.6.2`, `androidx.test.ext:junit:1.2.1`, and
   `androidx.test:core-ktx:1.6.1`. Preserve the existing JUnit unit-test setup
   and `preBuild` checks; do not change application dependencies or add a
   workflow/release dependency for this local runtime check.
2. Add
   `android/app/src/androidTest/kotlin/xyz/dnstt/app/SlipstreamBridgeInstrumentationTest.kt`
   using the repository's JUnit 4 style and an AndroidX runner. Obtain
   `InstrumentationRegistry.getInstrumentation().targetContext`, resolve
   `libslipstream_client.so` below `applicationInfo.nativeLibraryDir`, and fail
   explicitly when the extracted file is missing or not executable. Call
   `SlipstreamBridge.init(context)` and assert that the bridge reports the
   packaged binary as available.
3. In the instrumentation test, obtain a free loopback TCP port with
   `ServerSocket(0)`, close only that reservation immediately before starting,
   then call `startClient` with `host = "127.0.0.1"`, the reserved port,
   `domain = "example.com"`, `dnsServer = "127.0.0.1:9"`, default
   `ResolverOptions`, `dcubic`, and GSO disabled. Treat the resolver as an
   unreachable loopback sink: do not start a DNS listener, tunnel server, or
   external network dependency. Include `lastError` in assertion failures; if
   another process wins the port race, stop the failed bridge and retry the
   complete allocation/start sequence with a new port within a bounded limit.
4. After `startClient` succeeds, assert `isRunning()` and open a bounded-time
   TCP connection to `127.0.0.1:<port>`. A bounded retry is allowed to absorb
   listener scheduling, but the test must fail when the subprocess exits early,
   the listener never accepts the connection, or the bridge reports a startup
   error. Do not send a tunnel or application payload after the connection is
   established; listener acceptance is the complete smoke-test result.
5. Guarantee cleanup for every test outcome with `stopClient()` in the test's
   teardown/finally path, and assert that the bridge is no longer running after
   cleanup. Preserve the existing `nativeLibraryDir` lookup and public bridge
   API. If the installed-APK test exposes a genuine startup/readiness or
   lifecycle defect, make only the minimal corresponding change in
   `android/app/src/main/kotlin/xyz/dnstt/app/SlipstreamBridge.kt` and keep the
   same smoke test as its regression coverage; do not add a fallback binary
   location or weaken executable/process checks.
6. Add
   `android/app/src/androidTest/kotlin/xyz/dnstt/app/SlipstreamExecutableInstrumentationTest.kt`
   for the narrowed ARMv7 acceptance. It resolves the same packaged
   `libslipstream_client.so` under `applicationInfo.nativeLibraryDir`, fails
   explicitly when the file is missing or not executable, and starts it directly
   with `ProcessBuilder` and the same documentation-only arguments (loopback
   `--tcp-listen-host 127.0.0.1`, a fresh reserved port, `--domain example.com`,
   `--resolver 127.0.0.1:9`, `--congestion-control dcubic`, no GSO). Assert the
   process stays alive, open a bounded-time TCP connection to the reserved port,
   fail clearly on an early exit or missing listener, and always destroy the
   process in a finally path. This test must not call `Mobile` or
   `SlipstreamBridge`, must not start a DNS listener or tunnel server, and must
   not send a tunnel or application payload after the connection is accepted.
7. Prepare the ignored `jniLibs/<abi>/libslipstream_client.so` inputs from the
   accepted task 03 artifact or an authorized local source build, preserving
   executable mode. Because the Gradle guard requires all supported ABIs,
   stage all three ABI files even though runtime acceptance exercises only
   x86_64 and armeabi-v7a. Build ABI-specific debug APKs for the instrumentation
   runs without committing APKs, executables, test APKs, or other generated
   output.
8. Build split debug APKs with `flutter build apk --debug --split-per-abi` and
   build the instrumentation APK with
   `(cd android && ./gradlew :app:assembleDebugAndroidTest)`, keeping all
   outputs untracked. Install `app-x86_64-debug.apk` together with the generated
   `app-debug-androidTest.apk` on an x86_64 Android runtime and run the full
   bridge test class there. Repeat with `app-armeabi-v7a-debug.apk` on the
   accepted x86_64 runtime with ARM translation and run the executable test
   class there. For the x86_64 run verify
   `adb shell getprop ro.product.cpu.abi` is `x86_64`; for the ARMv7 run verify
   that `adb shell getprop ro.product.cpu.abilist` contains `armeabi-v7a` and
   that the installed app's `primaryCpuAbi` is `armeabi-v7a`. Use only the
   matching APK; do not record device identifiers. Use a suitable existing
   emulator/device or only runtime prerequisites explicitly authorized by the
   user; do not install unrelated SDK or system packages.
9. Run the focused x86_64 test with
   `adb shell am instrument -w -e class
   xyz.dnstt.app.SlipstreamBridgeInstrumentationTest
   xyz.dnstt.app.test/androidx.test.runner.AndroidJUnitRunner` and the focused
   ARMv7 test with the same command for
   `xyz.dnstt.app.SlipstreamExecutableInstrumentationTest`; run the existing
   Android JVM unit tests with `(cd android && ./gradlew :app:testDebugUnitTest)`,
   and run whitespace checks for the documentation change. Keep CI and release
   workflow files unchanged; do not dispatch or rerun a workflow and do not
   run a release workflow.

## Done when

- `android/app/build.gradle.kts` declares
  `androidx.test.runner.AndroidJUnitRunner` and the AndroidX Test runner,
  JUnit extension, and core Kotlin dependencies, and the project still passes
  its existing Kotlin unit-test task.
- The bridge and executable instrumentation tests are in the target package and
  use the installed app's `applicationInfo.nativeLibraryDir`; each fails clearly
  for a missing or non-executable `libslipstream_client.so`; the bridge test
  also fails on an unavailable bridge, and both fail on an early subprocess exit
  or a missing local TCP listener.
- The bridge test starts the packaged executable through `SlipstreamBridge` with
  `example.com`, a loopback-only resolver sink, and a `127.0.0.1` listener; it
  observes `isRunning()`, accepts a TCP connection, and always stops the
  subprocess. The executable test starts the same packaged binary directly with
  the same values, accepts a TCP connection, and always destroys the process,
  without calling `Mobile` or `SlipstreamBridge`. No tunnel server, real
  resolver, credentials, or external network is used.
- The focused bridge test passes with the matching x86_64 APK on an x86_64
  Android runtime, and the focused executable test passes with the matching
  armeabi-v7a APK on the accepted ARMv7-capable runtime: an x86_64 Android image
  with ARM translation. The node outcome records the reported ABI, the runtime
  kind and the APK filename for each acceptance run, states that the full bridge
  test cannot run on the ARM runtime because the existing `libgojni.so` crashes
  under `libndk_translation` before the bridge reaches the subprocess, and
  contains no device identifiers or environment details.
- Any required `SlipstreamBridge.kt` adjustment is limited to the tested
  startup/cleanup contract and is covered by the bridge instrumentation test; no
  unrelated runtime, packaging, CI, release, or live-tunnel behavior changes.
- Generated APKs, native executables, instrumentation APKs, logs, and runtime
  output remain outside the tracked tree. No release workflow or remote CI run
  is used for completion.

## Risks and what is needed from the user

An x86_64 Android runtime and an ARMv7-capable Android runtime are required for
the two acceptance runs. The user authorized the necessary emulator/system-image
packages and their associated licenses, and accepted an x86_64 image with ARM
translation as the ARMv7-capable runtime after the emulator refused to boot a
32-bit ARM system image. The user then accepted narrowing the ARMv7 side to a
direct packaged-executable test, because the app's existing `libgojni.so`
crashes under that translation before the bridge reaches the subprocess; the
full bridge test is required on x86_64 only. Do not substitute another ABI or a
real device/server check. No server, resolver access, credentials, or account is
needed. Keep all test arguments on loopback and use reserved documentation
values only. Do not put runtime logs, device identifiers, dates, paths, or other
environment details in the public node outcome.

## Runtime prerequisites and the accepted ARMv7 runtime

The user authorized installing the necessary Android emulator/system-image
packages and accepting their associated licenses. Provisioning for the x86_64
runtime is complete. The current emulator refuses to boot 32-bit ARM system
images (`CPU Architecture 'arm' is not supported by the QEMU2 emulator`), so the
user accepted an x86_64 Android image with ARM translation as the ARMv7-capable
runtime: the real armeabi-v7a `libslipstream_client.so` runs on it, and
`ro.product.cpu.abilist` includes `armeabi-v7a`, while `ro.product.cpu.abi` is
`x86_64`. The full bridge test cannot run there: the app's existing `libgojni.so`
crashes under `libndk_translation` before the bridge reaches the subprocess. The
user therefore accepted the narrowed ARMv7 acceptance described above. Neither
another ABI, a real tunnel server, nor a host-only test may substitute for
either acceptance run.

## Outcome

- Added the AndroidX Test instrumentation runner and test-only runner, JUnit
  extension, and core Kotlin dependencies. The existing JVM unit-test setup and
  `preBuild` checks are unchanged, and the Kotlin unit-test task still passes.
- Added `SlipstreamBridgeInstrumentationTest`: it resolves the packaged
  executable under `applicationInfo.nativeLibraryDir`, fails clearly for a
  missing or non-executable `libslipstream_client.so` or an unavailable bridge,
  starts the client with `example.com`, a loopback resolver sink, a loopback
  listener, and a freshly reserved port, checks `isRunning()`, accepts a
  bounded-time TCP connection, and always stops the client. Failed starts retry
  the complete port allocation/start sequence within a bound, and failures
  include `lastError`.
- Added `SlipstreamExecutableInstrumentationTest` for the narrowed ARMv7
  acceptance: it starts the same packaged executable directly with
  `ProcessBuilder` and the same documentation-only values, asserts that the
  process stays alive, accepts a bounded-time TCP connection, and always
  destroys the process. It does not call `Mobile` or `SlipstreamBridge`. The
  forced-kill cleanup path is used only where the runtime API provides it and
  falls back to a graceful destroy at the project's minimum API level.
- Acceptance passed on both required runtimes. The bridge test passed with
  `app-x86_64-debug.apk`, reported ABI `x86_64`, on an x86_64 Android runtime.
  The executable test passed with `app-armeabi-v7a-debug.apk`, reported app ABI
  `armeabi-v7a`, on the accepted ARMv7-capable runtime, an x86_64 Android image
  with ARM translation, where the installed app's `primaryCpuAbi` was
  `armeabi-v7a`.
- The full bridge test cannot run on the accepted ARM runtime: the existing
  `libgojni.so` from `dnstt.aar` crashes under `libndk_translation` before the
  bridge reaches the subprocess. This is a limitation of that translation
  runtime and the existing Go JNI library, not of the packaged Slipstream
  executable or the test; a full bridge check on a real ARMv7 runtime remains
  unverified and led to the user-accepted narrowed ARMv7 acceptance.
- The current emulator cannot boot 32-bit ARM system images, so the ARMv7
  capability was provisioned as an x86_64 image with ARM translation, as
  recorded in the runtime prerequisites.
- `SlipstreamBridge.kt` needed no change: the x86_64 bridge test exposed no
  startup, readiness, or cleanup defect. Application dependencies, CI, and
  release workflows are unchanged. All APKs, test APKs, logs, and staged
  `jniLibs` outputs remain outside the tracked tree.
- Independent review found one minor API-level cleanup issue in the new
  executable test, which was fixed and re-checked; no further findings were
  reported.
