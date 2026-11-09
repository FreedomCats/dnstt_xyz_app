---
kind: task
status: todo
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
