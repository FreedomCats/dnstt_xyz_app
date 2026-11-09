---
kind: task
status: done
detailed: true
depends: [04-android-subprocess-smoke]
---

# Guard the force-kill path for the minimum Android API

## Task

Production `android/app/src/main/kotlin/xyz/dnstt/app/SlipstreamBridge.kt`
calls `Process.destroyForcibly()`, which exists from API 26, while the app's
minimum is API 24. On API 24/25 a forced-kill path — a failed `startClient` and
`stopClient` after a graceful stop that did not finish — can throw
`NoSuchMethodError`. Add an API guard with a graceful fallback and cover it with
the existing checks. This was found while accepting
[04-android-subprocess-smoke](../04-android-subprocess-smoke/plan.md); the new
test already uses the same guard.

## Steps

1. In `android/app/src/main/kotlin/xyz/dnstt/app/SlipstreamBridge.kt`, add
   `import android.os.Build` with the other Android imports. Keep `minSdk`,
   Gradle files, dependencies and the public bridge API unchanged.

2. Guard the forced kill in the `startClient` failure handler (currently
   `process?.destroyForcibly()` at line 150). Call `process?.destroyForcibly()`
   only inside `if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)`; in the
   `else` branch call `process?.destroy()` again. Add a one-line comment above
   the condition: `destroyForcibly()` is public API 26, below it the graceful
   `destroy()` is repeated. Leave the surrounding `catch (e: Exception)`,
   `lastError`, `process = null`, `stderrThread = null`, `stopDnsBridge()` and
   the log call as they are.

3. Guard the forced kill in `stopClient()` (currently
   `process?.destroyForcibly()` at line 197) the same way. It stays inside the
   existing `if (isRunning())` after `destroy()` and `Thread.sleep(200)`: call
   `destroyForcibly()` only when
   `Build.VERSION.SDK_INT >= Build.VERSION_CODES.O`, otherwise call
   `destroy()` again. Keep the `catch (e: Exception)` and the final
   `process = null`, `stderrThread = null`, `stopDnsBridge()`.

4. Keep both guards inline at the two call sites, with the same shape as
   `SlipstreamExecutableInstrumentationTest.stopProcess`; do not remove
   `destroyForcibly()` from API 26+, do not wrap it in `catch (Throwable)`, and
   do not use reflection or `android.os.Process.sendSignal`. Do not switch
   `isRunning()` to `Process.isAlive()`: `isAlive()` is also API 26, while the
   current `exitValue()` check is API 1. Do not add a fallback binary location
   or weaken the executable check.

5. Check the API 24/25 result statically:

   ```
   grep -n "destroyForcibly\|SDK_INT" \
     android/app/src/main/kotlin/xyz/dnstt/app/SlipstreamBridge.kt
   ```

   Both `destroyForcibly()` calls must be inside a
   `Build.VERSION.SDK_INT >= Build.VERSION_CODES.O` branch, each with a
   `destroy()` fallback, and no other `destroyForcibly()` call may exist under
   `android/app/src/main`. No API 24/25 runtime is needed for this task, and no
   emulator package or system image is installed for it.

6. Run the existing checks. `(cd android && ./gradlew :app:testDebugUnitTest)`
   compiles the changed production sources and runs the Kotlin unit tests; run
   `flutter analyze` (the project's analyzer; Android lint is not part of the
   project's checks and no lint or CI gate should be added here) and
   `flutter test` from the repository root. Then rebuild the debug and
   instrumentation APKs from the local untracked inputs as in task 04 steps
   7–8 — `dnstt.aar`, the three staged
   `jniLibs` executables, `flutter build apk --debug --split-per-abi`,
   `(cd android && ./gradlew :app:assembleDebugAndroidTest)` — install
   `app-x86_64-debug.apk` with the test APK on the already-provisioned x86_64
   runtime and run the focused bridge test:

   ```
   adb shell am instrument -w -e class xyz.dnstt.app.SlipstreamBridgeInstrumentationTest \
     xyz.dnstt.app.test/androidx.test.runner.AndroidJUnitRunner
   ```

   It must pass on that API 26+ runtime. Its teardown calls `stopClient()` and
   asserts `isRunning()` is false, so the guarded production cleanup path is
   exercised and the force-kill branch stays reachable where the API supports
   it.

7. Keep the tree clean: `git diff` must contain only `SlipstreamBridge.kt`.
   Revert the generated `linux/` and `windows/` plugin files if `flutter pub
   get` rewrote them, and remove `android/build/` left by the unit-test task.
   Do not change CI or release workflows, do not commit APKs, binaries, test
   APKs or logs, and do not dispatch a remote workflow.

## Done when

- Both `destroyForcibly()` calls in
  `android/app/src/main/kotlin/xyz/dnstt/app/SlipstreamBridge.kt` — in the
  `startClient` failure handler and in `stopClient()` after the graceful
  stop — are inside `if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)`, with
  a repeated `destroy()` in the `else` branch; `android.os.Build` is imported.
- API 24/25: reading both call sites shows no unguarded `destroyForcibly()`, and
  the fallback is a repeated `destroy()`; no API 24/25 runtime is used and no
  emulator package or system image is installed for this task.
- API 26+: `(cd android && ./gradlew :app:testDebugUnitTest)` passes, and the
  focused `xyz.dnstt.app.SlipstreamBridgeInstrumentationTest` passes on the
  available x86_64 runtime with the rebuilt APKs; `flutter analyze` and
  `flutter test` pass from the repository root.
- The public bridge API and its behavior on API 26+ are unchanged; `git diff`
  touches only `SlipstreamBridge.kt`, with no Gradle, dependency, `minSdk`, CI,
  release or packaging changes.

## Risks and what is needed from the user

The failing path is rare and needs no API 24/25 runtime to verify: the guard is
visible in the diff. Do not weaken process cleanup, add a fallback binary
location, or change the bridge API. `catch (e: Exception)` does not catch
`NoSuchMethodError` (an `Error`), so a missed guard would escape `startClient`
or `stopClient` and skip the `stopDnsBridge()` cleanup — check both sites.
Below API 26 Android has no public force-kill for a `Process` (there is no
`pid()` to pass to `android.os.Process.sendSignal`), so a repeated `destroy()`
is the accepted fallback even if a process ignores it.

## Outcome

- `SlipstreamBridge.kt` now imports `android.os.Build`. Both
  `Process.destroyForcibly()` calls — in the `startClient` failure handler and
  in `stopClient()` after the graceful stop — are inside
  `if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)`, with a repeated
  `process?.destroy()` in the `else` branch and a one-line comment naming the
  API level. The guards are inline at the two call sites and have the same
  shape as `SlipstreamExecutableInstrumentationTest.stopProcess`. The
  surrounding error handling, `lastError`, `process`/`stderrThread` reset and
  `stopDnsBridge()` are unchanged, and `isRunning()` still uses the API 1
  `exitValue()` check.
- API 24/25 is verified statically, as designed: both call sites are guarded
  with a `destroy()` fallback and no unguarded `destroyForcibly()` remains
  under `android/app/src/main`. No API 24/25 runtime was used, and no emulator
  package or system image was installed for this task.
- API 26+ checks pass: `(cd android && ./gradlew :app:testDebugUnitTest)`,
  `flutter analyze` and `flutter test` are green. The debug and
  instrumentation APKs were rebuilt from the already prepared untracked
  `dnstt.aar` and three staged `jniLibs` executables, and the focused
  `xyz.dnstt.app.SlipstreamBridgeInstrumentationTest` passed on the available
  x86_64 Android runtime. Its teardown calls `stopClient()` and asserts that
  the bridge is no longer running, so the guarded production cleanup path is
  exercised and the force-kill branch stays reachable where the API supports
  it.
- The public bridge API, `minSdk`, Gradle files, dependencies and behavior on
  API 26+ are unchanged; there are no CI, release or packaging changes.
  Generated APKs, executables, test APKs and logs stay outside the tracked
  tree; the `linux/` and `windows/` generated plugin files rewritten by
  `flutter pub get` were reverted.
- Independent review found no issues.
- Left as is by design: the API 24/25 fallback cannot be exercised at runtime
  here, so it is covered only by reading the two call sites; a repeated
  `destroy()` is the accepted fallback because Android has no public force-kill
  for a `Process` below API 26.
