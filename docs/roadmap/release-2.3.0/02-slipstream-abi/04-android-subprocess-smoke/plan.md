---
kind: task
status: blocked
detailed: true
depends: [03-apk-packaging]
---

# Verify Slipstream subprocess startup on Android ABIs

## Task

Add one Android instrumentation smoke test for the packaged
`libslipstream_client.so`. The test must initialize `SlipstreamBridge` with the
target application context, start the subprocess with documentation-only values,
and prove the local TCP startup contract without contacting a tunnel server or a
real resolver. Run that same test against an x86_64 APK on an x86_64 Android
runtime and an armeabi-v7a APK on an ARMv7-capable Android runtime.

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
6. Prepare the ignored `jniLibs/<abi>/libslipstream_client.so` inputs from the
   accepted task 03 artifact or an authorized local source build, preserving
   executable mode. Because the Gradle guard requires all supported ABIs,
   stage all three ABI files even though runtime acceptance exercises only
   x86_64 and armeabi-v7a. Build ABI-specific debug APKs for the instrumentation
   runs without committing APKs, executables, test APKs, or other generated
   output.
7. Build split debug APKs with `flutter build apk --debug --split-per-abi` and
   build the instrumentation APK with
   `(cd android && ./gradlew :app:assembleDebugAndroidTest)`, keeping all
   outputs untracked. Install `app-x86_64-debug.apk` together with the generated
   `app-debug-androidTest.apk` on an x86_64 Android runtime, then invoke
   `xyz.dnstt.app.test/androidx.test.runner.AndroidJUnitRunner` with the focused
   test class. Repeat the same flow with `app-armeabi-v7a-debug.apk` on an
   ARMv7-capable Android runtime. Before each run, verify
   `adb shell getprop ro.product.cpu.abi` and use only the matching APK; do not
   record device identifiers. Use a suitable existing emulator/device or only
   runtime prerequisites explicitly authorized by the user; do not install
   unrelated SDK or system packages.
8. Run the focused instrumentation test with
   `adb shell am instrument -w -e class
   xyz.dnstt.app.SlipstreamBridgeInstrumentationTest
   xyz.dnstt.app.test/androidx.test.runner.AndroidJUnitRunner`, run the existing
   Android JVM unit tests with `(cd android && ./gradlew :app:testDebugUnitTest)`,
   and run whitespace checks for the documentation change. Keep CI and release
   workflow files unchanged; do not dispatch or rerun a workflow and do not
   run a release workflow.

## Done when

- `android/app/build.gradle.kts` declares
  `androidx.test.runner.AndroidJUnitRunner` and the AndroidX Test runner,
  JUnit extension, and core Kotlin dependencies, and the project still passes
  its existing Kotlin unit-test task.
- The instrumentation test is in the target package and uses the installed
  app's `applicationInfo.nativeLibraryDir`; it fails clearly for a missing or
  non-executable `libslipstream_client.so`, an unavailable bridge, an early
  subprocess exit, or a missing local TCP listener.
- The test starts the packaged executable with `example.com`, a loopback-only
  resolver sink, and a `127.0.0.1` listener; it observes `isRunning()`, accepts
  a TCP connection, and always stops the subprocess. No tunnel server, real
  resolver, credentials, or external network is used.
- The unchanged focused test passes with the matching x86_64 APK on an x86_64
  Android runtime and with the matching armeabi-v7a APK on an ARMv7-capable
  Android runtime. The node outcome records only the reported ABI and APK
  filename for each acceptance run, with no device identifiers or environment
  details.
- Any required `SlipstreamBridge.kt` adjustment is limited to the tested
  startup/cleanup contract and is covered by the instrumentation test; no
  unrelated runtime, packaging, CI, release, or live-tunnel behavior changes.
- Generated APKs, native executables, instrumentation APKs, logs, and runtime
  output remain outside the tracked tree. No release workflow or remote CI run
  is used for completion.

## Risks and what is needed from the user

An x86_64 Android runtime and an ARMv7-capable Android runtime are required for
the two acceptance runs. The user authorized the necessary emulator/system-image
packages and their associated licenses. If a suitable ARMv7 runtime cannot be
provisioned within that scope, ask the user for a compatible runtime; do not
substitute another ABI or a real device/server check. No
server, resolver access, credentials, or account is needed. Keep all test
arguments on loopback and use reserved documentation values only. Do not put
runtime logs, device identifiers, dates, paths, or other environment details in
the public node outcome.

## Blocker

The two required acceptance environments are not currently available. The user
authorized installing the necessary Android emulator/system-image packages and
accepting their associated licenses. Storage remediation is complete, and
runtime provisioning is the next execution step; no runtime package has yet been
installed under this grant. The focused test still requires both an x86_64
Android runtime and an ARMv7-capable Android runtime; another ABI, a real tunnel
server, or a host-only test cannot substitute for either acceptance run.
