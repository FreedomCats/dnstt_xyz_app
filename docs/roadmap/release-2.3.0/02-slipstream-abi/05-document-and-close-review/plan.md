---
kind: task
status: todo
depends: [04-android-subprocess-smoke]
---

# Document the Android build and close review item 3.3

## Goal

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
