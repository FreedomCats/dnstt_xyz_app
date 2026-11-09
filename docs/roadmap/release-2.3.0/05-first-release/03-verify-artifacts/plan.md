---
kind: task
status: done
detailed: true
depends: [02-run-release-workflow]
---

# Verify the published artifacts and the signature

## Task

The release page is public and its APKs replace an installed app on the user's
device. Before [04-install-on-device](../04-install-on-device/plan.md) uses
them, prove that the files are the ones this project built: signed with the
project key, at the version of the tag, carrying the Slipstream executable for
every ABI, and free of any machine path other than the CI checkout.

The expected signing certificate is already known: `ci.yml` builds the same
split release APKs on every push and prints the certificate SHA-256 in its
Android job summary, and [01-version-and-tag](../01-version-and-tag/plan.md)
records the digest for the tagged commit. The release notes state it as well, so
three values have to agree.

## Steps

1. Download the five assets of `v2.3.0-beta` into a temporary directory outside
   the repository (`gh release download v2.3.0-beta --dir <tmp>` or the browser).
   Check the names against the README table: three
   `DNSTT-Client-v2.3.0-beta-Android-*.apk` files and two
   `DNSTT-Client-v2.3.0-beta-macOS-*.dmg` files.
2. Certificate of all three APKs: use the newest `apksigner`, the way
   `ci.yml:183` picks it — `APKSIGNER=$(ls -d "$ANDROID_HOME"/build-tools/*/ |
   sort -V | tail -1)apksigner; "$APKSIGNER" verify --print-certs <apk>`. All
   three must print the same `certificate SHA-256`, equal to the digest recorded
   from `ci.yml` for the tagged commit and to the one in the release notes. The
   `certificate DN` must be the project's neutral subject, not `CN=Android
   Debug`. `"$APKSIGNER" verify <apk>` must exit 0; its `--verbose` output names
   the signature schemes, and a `WARNING` line there is written down and
   explained, not ignored.
3. Version and package of all three APKs: with the newest
   `aapt2` (`AAPT2=$(ls -d "$ANDROID_HOME"/build-tools/*/ | sort -V | tail
   -1)aapt2`), `"$AAPT2" dump badging <apk> | head -1` reports
   `package: name='xyz.dnstt.app' versionCode='6' versionName='2.3.0'`, and the
   `native-code:` line names only the ABI of that split.
4. Slipstream payload: copy the three APKs into a temporary directory under the
   names the script expects — `app-armeabi-v7a-release.apk`,
   `app-arm64-v8a-release.apk`, `app-x86_64-release.apk` — and run
   `scripts/check_slipstream_apks.sh <dir>`. Each APK must contain exactly one
   `lib/<abi>/libslipstream_client.so` and no Slipstream entry for another ABI.
5. Machine paths: `scripts/check_binary_paths.sh --allow
   '^file:///home/runner/work/[^/]+/[^/]+/\.dart_tool/' <the three APKs>` must
   print `ok:` for each, with a `note:` listing the allowed CI-checkout URIs.
   That allowance is the one `ci.yml:178` applies to the CI checkout and is not
   a person's path. A path under someone's home, a project checkout or any other
   absolute path is a failure.
6. macOS: `hdiutil` exists only on macOS, so the images may not be mountable
   here. If the available tools can read a DMG (`7z l`, `7z x`), check inside
   `DNSTT_XYZ.app`: `CFBundleShortVersionString` is 2.3.0 and `CFBundleVersion`
   is 6 (`Contents/Info.plist`), `Contents/Frameworks/libdnstt.dylib` and
   `Contents/Frameworks/slipstream-client` are present, are Mach-O and of the
   architecture the file name promises, and `scripts/check_binary_paths.sh`
   passes on the extracted binaries. If the image cannot be read, record that
   the DMGs are covered only by the successful `codesign -vvv` step and the
   artifact upload in the run, and do not claim the macOS app was launched.
7. Record the outcome: the digest, the version codes, what was and was not
   checked, in the journal (the lead writes it) and, where generally useful, in
   the stage report. A mismatch is not papered over by editing the release page:
   write it down as a defect node and tell the lead.

## Done when

- The three APKs share one certificate SHA-256, equal to the `ci.yml` summary of
  the tagged commit and to the release notes, and it is not the debug key.
- Every APK reports `xyz.dnstt.app` version 2.3.0 (6), carries exactly its own
  ABI's `libslipstream_client.so`, and passes the machine-path check with only
  the CI-checkout allowance.
- The two DMGs are present under the expected names; what could be inspected is
  inspected and the limits of the check are written down.
- Any mismatch is a new node with its evidence, not a silent acceptance.

## Risks and what is needed from the user

- Downloading from the release page is a read-only action and changes nothing.
  `gh` may be missing or unauthenticated; the browser download gives the same
  files.
- The DMG checks are limited on a non-macOS machine: the signature and the
  launch of the macOS app can only be judged on macOS or by the CI step that
  signed it. Say which of the two it was instead of implying more.
- The released APK legitimately contains the CI checkout URI in `libapp.so`
  (the Dart plugin registrant, `AGENTS.md`, "Builds"); that is why the allowance
  exists. Any other absolute path means the build did not come from CI.
- Replacing a release asset is an outward action and needs the user's go-ahead;
  this task only verifies and reports.

## Outcome

- The page `v2.3.0-beta` is published (`draft: false`, `prerelease: true`), its
  `target_commitish` is `f74e7d58edcb4dae97dcdd3041d1d0bf7f8593c3`, and the
  lightweight tag points at the same commit. `Build and Release` run
  [42706971253](https://github.com/FreedomCats/dnstt_xyz_app/actions/runs/42706971253)
  is `completed`/`success` (`aar`, `slipstream-android`, `build-android`,
  `build-macos-arm64`, `build-macos-intel`, `create-release`); `build-linux`
  and `build-windows` were skipped as configured.
- The five assets carry the names of the README table, and the SHA-256 computed
  after the download equals the digest the release API reports for each:
  - `DNSTT-Client-v2.3.0-beta-Android-arm64-v8a.apk` —
    `767b13696cdd2e249c400e06bc4a79487b96eb90a037a9920367158a11ab8ebc`
  - `DNSTT-Client-v2.3.0-beta-Android-armeabi-v7a.apk` —
    `9a95122a3b3519d3f7ab7b15f09837d5f5eef3e92531ff9a94d3b6f9a37fd57a`
  - `DNSTT-Client-v2.3.0-beta-Android-x86_64.apk` —
    `ccf8fb348a73045697e7861f8ba9b82a0b58f8fd99a3056e20fd05cc44ccfb53`
  - `DNSTT-Client-v2.3.0-beta-macOS-arm64.dmg` —
    `d75866c632eb620d4cad0aaef211f0efebb582d7551e0d841d305f8f3d88c2ba`
  - `DNSTT-Client-v2.3.0-beta-macOS-intel.dmg` —
    `81b5907b93b6161e9b8533a140b21848cf5d6cc90f19383c12c1373c0f689857`
- Certificate: all three APKs print `certificate DN: CN=FreedomCats` and
  `certificate SHA-256 digest:
  a0463ae9637d96ee9ad8b8ce305aa62b0c78868fa565d19111f26eca74e0500c`
  (`apksigner` 0.9 from build-tools 35.0.0); `verify` exits 0 for each and
  prints no `WARNING`. The same digest is in the release body and in the
  `Show signing certificate` output of `ci.yml` run
  [42690405232](https://github.com/FreedomCats/dnstt_xyz_app/actions/runs/42690405232)
  on `f74e7d5`; the three values agree and the digest is not the debug key.
- Signature schemes: v2 only (v1, v3, v3.1, v4 false). That is `apksigner`'s
  default for the manifest's `minSdkVersion 24`, so the JAR signature is not
  needed; no warning was printed about it.
- Version: `package: name='xyz.dnstt.app'` and `versionName='2.3.0'` in all
  three APKs (`aapt2` 2.19 from the same build-tools). `versionCode` is the
  base 6 from `pubspec.yaml` plus the per-ABI offset Flutter adds for
  `--split-per-abi` (`ABI_VERSION` 1/2/4 × 1000): `1006` for armeabi-v7a,
  `2006` for arm64-v8a, `4006` for x86_64. The plan's literal `versionCode='6'`
  describes an unsplit build; the split release necessarily reports the
  offset, so 6 is the build number, not the full code. The `native-code:` line
  of each APK names only its own ABI. For
  [04-install-on-device](../04-install-on-device/plan.md): the installed
  release app will report `2006` on an arm64 device, not `6`.
- Slipstream: `check_slipstream_apks.sh` reports exactly one
  `lib/<abi>/libslipstream_client.so` in each APK and no Slipstream entry for
  another ABI.
- Machine paths in the APKs: `check_binary_paths.sh --allow
  '^file:///home/runner/work/[^/]+/[^/]+/\.dart_tool/'` prints `ok:` for every
  library of all three APKs. The only `note:` is
  `file:///home/runner/work/dnstt_xyz_app/dnstt_xyz_app/.dart_tool/flutter_build/dart_plugin_registrant.dart`
  in `libapp.so`, the CI-checkout URI the allowance covers.
- macOS: 7-Zip reads the APFS payload of both images, so both app bundles were
  unpacked and inspected without mounting. In each bundle
  `CFBundleIdentifier` is `xyz.dnstt.app`, `CFBundleShortVersionString` is
  `2.3.0` and `CFBundleVersion` is `6`. `Contents/Frameworks/libdnstt.dylib`
  and `Contents/Frameworks/slipstream-client` are present and are Mach-O (a
  dylib and an executable): arm64 in the arm64 image and x86_64 in the Intel
  image. The Flutter-built parts (`Contents/MacOS/DNSTT_XYZ`,
  `App.framework`, `FlutterMacOS.framework`) are universal (x86_64 + arm64) in
  both images, so the file name describes the architecture of the two
  per-architecture payloads, not of the whole bundle.
- Machine paths in the macOS app: `check_binary_paths.sh` passes without any
  allowance on `libdnstt.dylib` and `slipstream-client`, the two binaries
  `release.yml` checks. Over the whole extracted bundle it reports
  `/Users/runner/...` strings in `App.framework`, the plugin frameworks and the
  Runner executable: Xcode build intermediates, the pub cache and the same
  `dart_plugin_registrant` URI as on Android. Nothing lies outside
  `/Users/runner/`; with the CI-runner allowance (`^/Users/runner/` and
  `^file:///Users/runner/`) all 52 binaries of each bundle print `ok:`. This is
  the same class of CI-runner path as the Android allowance, which is why
  `CLAUDE.md` says the check covers the macOS libraries and not the whole
  bundle. Step 6's wording ("passes on the extracted binaries") therefore holds
  only for the project-built binaries; it is recorded here and not treated as a
  defect in the artifact. No build file was changed for this.
- Limits of the check: `codesign` and `hdiutil` exist only on macOS, so the
  ad-hoc signature was not re-verified here and neither app was launched. The
  signature is covered by the `codesign -vvv` step of run `42706971253` that
  ran before `hdiutil create`, and `_CodeSignature/CodeResources` in both
  bundles lists `libdnstt.dylib` and `slipstream-client` among the sealed
  files. The APKs were not installed or started; that is
  [04-install-on-device](../04-install-on-device/plan.md).
- No mismatch was found that changes an asset. The tree is unchanged apart from
  this file; `flutter analyze`, `flutter test` (103 tests) and `go test ./...`
  with vet (`noise` excluded as in `CLAUDE.md`) are green on it.
