---
kind: task
status: todo
depends: [03-apk-packaging]
---

# Verify Slipstream subprocess startup on Android ABIs

## Goal

Exercise the packaged executable through `SlipstreamBridge` on an installed
Android app and prove that it stays alive and listens on its requested local
TCP port on both x86_64 and armeabi-v7a, without needing a tunnel server.

## Done when

- An Android instrumentation test initializes `SlipstreamBridge` from the
  target app context, starts it with documentation-only test values and a
  loopback resolver, confirms the process is running, and opens a TCP connection
  to the configured loopback listener.
- The test stops the subprocess in cleanup and fails if the binary is missing,
  non-executable, exits early, or does not accept a local connection.
- The test passes against an x86_64 emulator install and an armeabi-v7a APK on
  an Android runtime that supports that ABI. The runtime's reported ABI and the
  APK used are recorded in the node outcome without device identifiers or
  environment details.
- No DNS tunnel connection or real resolver/server is required; the loopback
  resolver is only a sink while testing local listener startup.

## What to do, what is touched

- Add the instrumentation runner and test-only AndroidX test dependencies in
  `android/app/build.gradle.kts`.
- Add an instrumentation test under
  `android/app/src/androidTest/kotlin/xyz/dnstt/app/` using
  `SlipstreamBridge.init`, `startClient`, `isRunning` and `stopClient`.
- Run the same focused instrumentation test on an x86_64 emulator and on an
  ARMv7-capable Android runtime with the matching split APK. Do not make a live
  tunnel check part of this node.

## Risks and what is needed from the user

An Android runtime capable of running armeabi-v7a is required for the second
acceptance check; a compatible emulator is sufficient, otherwise the user must
provide access to an ARMv7 device. The runtime does not need to be attached to
CI if no suitable hosted emulator image is available, but the recorded check
must still identify the ABI and APK tested. No server, resolver access or
account is needed. Keep test arguments on loopback and use reserved example
domains only.
