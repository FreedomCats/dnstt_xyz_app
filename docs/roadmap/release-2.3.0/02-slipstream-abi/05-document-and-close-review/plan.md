---
kind: task
status: done
depends: [04-android-subprocess-smoke]
---

# Document the Android build and close review item 3.3

## Task

Make the developer instructions and architecture describe the CI-built
three-ABI executable delivery accurately, and close the corresponding
functional finding in the code review with the APK and runtime evidence.

## Done when

- `CLAUDE.md` documents the supported ABIs, pinned vendored source and NDK,
  Rust/cargo-ndk prerequisites and the command that must precede a local APK
  build, CI artifact packaging, executable extraction and current
  `SlipstreamBridge` lookup behavior; stale claims that Android is ARM64-only
  or that four Android targets are built are removed.
- Section 5.4 of `docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md` describes the
  implemented build/cache/artifact/path-check flow without changing unrelated
  architecture decisions.
- `docs/CODE_REVIEW.md` records item 3.3 as resolved and states that each split
  APK contains its matching executable and that the runtime smoke test starts
  and listens on x86_64 and armeabi-v7a, citing the completed outcomes of
  [03-apk-packaging](../03-apk-packaging/plan.md) and
  [04-android-subprocess-smoke](../04-android-subprocess-smoke/plan.md).
- Documentation contains no dates, environment/device identifiers, server
  addresses or private test data.

## Risks and what is needed from the user

This task depends on the runtime-smoke node and closes only after both APK
contents and subprocess-listener criteria have passed. Do not mark the review
item closed based only on successful cross-compilation or APK assembly.

## Outcome

- `CLAUDE.md` now documents the three ABIs, the pinned `vendor/slipstream-rust`
  source and NDK 28.2.13676358, cargo-ndk 4.1.2 and the three Rust targets, the
  script that must run before a local APK build, the CI producer artifact and
  mode restoration, the local Gradle guard, and the current `SlipstreamBridge`
  `applicationInfo.nativeLibraryDir` lookup. The stale ARM64-only claim, the
  four-target Rust list and the committed `jniLibs` layout were removed.
- `docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md` section 5.4 now describes the
  implemented build/cache/artifact/path-check flow and the runtime smoke
  coverage, without changing unrelated architecture decisions.
- `docs/CODE_REVIEW.md` records item 3.3 as resolved, with the APK-content and
  runtime-listener evidence linked to the completed outcomes of tasks 03 and 04.
- No dates, environment or device identifiers, server addresses or private data
  were added. No code, workflow or generated binary changed.
