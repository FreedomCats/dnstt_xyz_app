---
kind: task
status: todo
depends: [03-verify-artifacts]
---

# Install the release APK on the device and start it

## Task

The stage is done when the user can install the release and run it. This node
covers the install over what the phone already holds and the app starting; the
feature checks are [06-live-checks](../../06-live-checks/plan.md). The device,
the decision to uninstall an old app and the tap on the icon are the user's; the
agent prepares the commands, reads the results and records them.

`xyz.dnstt.app` is the same application ID as the upstream app, and Android
installs an update only if it is signed with the certificate of the installed
app. If the phone holds the upstream app, the install fails with
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`; the old app is uninstalled after its
configs are exported. If the installed build is this project's, the release
APK updates it in place and keeps the data, which is the "install replaces
nothing" case of the map.

## Steps

1. Ask the user to export the configs of any installed `xyz.dnstt.app` build
   (the app has an export action) and to keep the file outside the repository.
   This is the only way back if the old app has to be removed.
2. Read what is installed. `adb devices` shows the phone; then
   `adb shell dumpsys package xyz.dnstt.app | grep -E 'versionCode|versionName'`
   prints its code and name. No output means a fresh install; a code of 5 is a
   debug build of this fork, which the release updates in place.
3. Install the matching split. Read the phone's main ABI with
   `adb shell getprop ro.product.cpu.abi` and pick the file for it: `arm64-v8a`
   on a modern phone, `armeabi-v7a` on a 32-bit one. Then
   `adb install -r DNSTT-Client-v2.3.0-beta-Android-<abi>.apk`. If adb is not
   available, the user installs the same file on the phone from the release page
   instead and reports the result.
4. Android itself decides whether the installed app has the same certificate:
   a successful `install -r` proves it, and `INSTALL_FAILED_UPDATE_INCOMPATIBLE`
   proves the opposite. In the second case, with the user's agreement and after
   step 1, `adb uninstall xyz.dnstt.app` and install again. Record which of the
   two happened, so the release notes and the report can name it.
5. Verify what got installed. `adb shell dumpsys package xyz.dnstt.app | grep
   -E 'versionCode|versionName'` must report 6 and 2.3.0. If
   `adb shell pm path xyz.dnstt.app` and `adb pull` of that file are permitted,
   check its certificate SHA-256 with `apksigner` and compare it with the
   release digest from [03](../03-verify-artifacts/plan.md). If the pull is
   refused, record that the signer was proven by the install of the verified
   file in step 4, not by reading the installed APK.
6. Start the app: the user taps the icon, or `adb shell monkey -p
   xyz.dnstt.app -c android.intent.category.LAUNCHER 1`. Right after launch,
   `adb logcat -d -t 300 | grep -E 'FATAL EXCEPTION|AndroidRuntime'` must be
   empty for this package, and the user confirms the home screen appears. A
   VPN permission prompt is not expected until a connection is started.
7. Record in the task report, for the journal: the installed version, whether
   the old app was updated or uninstalled, and what the user saw. Keep log
   excerpts and any device detail in `docs/local/`, never in the repository. A
   refusal, a crash or a blank screen becomes a new node with its evidence.

## Done when

- `xyz.dnstt.app` is installed on the device with versionCode 6 and versionName
  2.3.0; its certificate is either read back as the release digest or proven by
  a successful install of the verified file, and the report says which of the
  two.
- The app starts and shows its main screen, with no fatal error in the log at
  startup.
- The user confirms the install and the start; the report records whether the
  install was an in-place update or followed an export and an uninstall.

## Risks and what is needed from the user

- The phone, its USB debugging setting and the uninstall are the user's. An
  uninstall deletes the app data, so the export in step 1 comes first; an
  in-place update keeps it.
- If the installed app is the upstream build, the uninstall is unavoidable, and
  the release notes should say so; that text is
  [05-release-notes](../05-release-notes/plan.md).
- The user may install by opening the APK on the phone instead of adb; then
  steps 2 and 5 still read the installed version, the certificate can be read
  back only when the pull in step 5 is permitted, and a signature mismatch
  shows as the same `INSTALL_FAILED_UPDATE_INCOMPATIBLE` dialog.
- No tunnel server is used here: this task only proves that the app installs and
  opens. Anything that needs a connection belongs to `06-live-checks`.
- Nothing that identifies the device goes into the repository or the map.
