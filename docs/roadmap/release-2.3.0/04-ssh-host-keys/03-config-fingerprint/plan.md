---
kind: task
status: done
detailed: true
---

# Store the SSH host key fingerprint in the config

## Task

Make the SSH host key fingerprint a first-class config field:
`sshHostKeyFingerprint` next to `sshUsername` and `sshPrivateKey` in
`lib/models/dnstt_config.dart`, so it travels with the config through
`StorageService`, import and export, and can be cleared from the config
editor. The connection logic and the method channel are separate tasks:
[01-tofu-host-key-repository](../01-tofu-host-key-repository/plan.md) produces
the fingerprint and [04-connect-wiring](../04-connect-wiring/plan.md) passes
it in and persists the accepted value. This task is the Dart side only: no
Kotlin, method channel, `vpn_service.dart` or SSH logic changes.

The value is the display form used by `ssh-keygen -lf`:
`SHA256:` plus unpadded standard base64 of the key blob's SHA-256. A config
without the field (every config written before this change) means "no key
remembered" and accepts the first key it sees.

The field is Android-only in effect: desktop SSH runs the system `ssh`
command and OpenSSH's `known_hosts`, so a desktop connection ignores the
field. The model, storage, import/export and editor stay platform-neutral;
[05-docs-and-review](../05-docs-and-review/plan.md) writes the split down. Do
not add platform checks in the Dart code and do not add a UI for typing or
pasting a fingerprint by hand.

## Steps

1. `lib/models/dnstt_config.dart`: add the field and carry it through every
   serialization path.
   - Declare `String? sshHostKeyFingerprint;` after `sshPrivateKey` (line 41)
     with a comment naming the format (`SHA256:` plus unpadded standard
     base64 of the SHA-256 of the key blob) and stating that `null` means no
     key is remembered.
   - Add the constructor parameter after `sshPrivateKey` (line 67).
   - Add `'sshHostKeyFingerprint': sshHostKeyFingerprint,` to `toJson` after
     `sshPrivateKey` (line 84), and
     `sshHostKeyFingerprint: json['sshHostKeyFingerprint'],` to `fromJson`
     after `sshPrivateKey` (line 101). Keep the raw value in the model like
     the other optional strings; the importer and the exporter treat a missing
     or empty value as absent (step 2), and the editor only shows a non-empty
     value (step 4).
   - Add the `copyWith` parameter after `sshPrivateKey` (line 181) and
     `sshHostKeyFingerprint: sshHostKeyFingerprint ?? this.sshHostKeyFingerprint,`
     after line 197. Keep the null-coalescing semantics: `copyWith` cannot
     clear the field. The editor and the save path assign the field directly,
     as they already do for the other SSH fields.
2. `lib/services/config_import_export_service.dart`:
   - Add a small private helper next to `_parseConfigList`, for example
     `static String? _nonEmpty(dynamic value)`, returning the trimmed string
     or `null` when the value is missing, not a string, empty or whitespace.
   - Import: after `sshPrivateKey` (line 85) add
     `sshHostKeyFingerprint: tunnelType == TunnelType.ssh
         ? _nonEmpty(item['sshHostKeyFingerprint'])
         : null,`.
     Gate on the tunnel type so a stray field in a SOCKS5 entry does not become
     a stored value; the exporter and the editor apply the same rule.
   - Export: inside the SSH block (lines 159-163), after the password, emit a
     trimmed non-empty value only:
     `final fingerprint = c.sshHostKeyFingerprint?.trim(); if (fingerprint !=
     null && fingerprint.isNotEmpty) configMap['sshHostKeyFingerprint'] =
     fingerprint;`. An SSH config without a value emits no key, and a SOCKS5
     config never emits one.
   - Bump the exported `version` from `1.3` to `1.4` at line 132. This follows
     the existing precedent: adding the SSH and SOCKS5 fields bumped `1.2` to
     `1.3`. Import ignores the version today; keep it that way so `1.3` files,
     bare arrays and future versions still import.
   - Do not add `sshPrivateKey` to the export: it is absent there today, and
     exporting credentials is outside this task. The fingerprint is public and
     must be exported, otherwise a config moved to another device would
     silently trust on first use again.
3. `lib/services/storage_service.dart`: no code change and no new
   `SharedPreferences` key. `getDnsttConfigs`/`saveDnsttConfigs` (lines
   64-74) already encode and decode the whole `DnsttConfig` JSON, so the field
   rides in the existing `dnstt_configs` value, and a stored JSON without the
   key loads as null. Prove it with the storage tests in step 5; do not add
   storage code for one field.
4. `lib/screens/config_management_screen.dart`, stateful config dialog
   (`_ConfigDialogState`, from line 783):
   - Add `String? _sshHostKeyFingerprint;` to the dialog state next to
     `showSocksPassword` (line 798), and initialize it in `initState` after the
     SSH password controller (line 807) from
     `widget.existingConfig?.sshHostKeyFingerprint`. Without this
     initialization, editing and saving any SSH config would silently drop a
     stored fingerprint; the widget test in step 6 pins it.
   - In the SSH settings block after the SSH password field (line 1040), show
     the stored value. A small private method of `_ConfigDialogState` keeps
     `build` readable; it returns a column with:
     - a caption such as `SSH host key` (small bold text, like the other block
       captions);
     - when the value is non-null and non-empty: the value in a
       `SelectableText` with `fontFamily: 'monospace'` and a small font, plus
       a `TextButton` labelled `Forget host key` whose `onPressed` runs
       `setState(() => _sshHostKeyFingerprint = null)`. No confirmation
       dialog: the user saves the config afterwards;
     - when there is no value: one grey line saying that the host key will be
       remembered on the first connection. No text field and no way to type or
       paste a fingerprint.
   - `_saveConfig`: pass
     `sshHostKeyFingerprint: selectedTunnelType == TunnelType.ssh
         ? _sshHostKeyFingerprint
         : null,` to the new `DnsttConfig` after `sshPassword` (line 1166), and
     assign the same expression to
     `widget.existingConfig!.sshHostKeyFingerprint` after line 1190. For a new
     config the value is always null because the dialog cannot set it; keep
     the expression symmetrical anyway.
   - Do not clear the value when the domain, public key or transport type
     changes: a changed server must be refused until the user forgets the key,
     and the refusal text points at this editor. Switching the tunnel type
     away from SSH clears the field, because it has no meaning for SOCKS5.
5. Add `test/config_fingerprint_test.dart` with the model, import/export and
   storage tests.
   - Use one documentation value everywhere, for example
     `SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU`; no real server key,
     domain, address or other personal data. Use a 64-character public key such
     as `List.filled(64, '0').join()` and the tunnel domain `t.example.com`
     (RFC 2606), so the imported configs pass `DnsttConfig.isValid`.
   - Model: a JSON map with the old fields and no `sshHostKeyFingerprint` loads
     with null; a config with the value survives
     `DnsttConfig.fromJson(jsonDecode(jsonEncode(config.toJson())))`;
     `copyWith` keeps the value when another field changes.
   - Import/export: `exportConfigsToJson` emits the value for an SSH config
     and no key for a SOCKS5 config or an SSH config without a value; the
     exported `version` is `1.4`; a `'version': '1.3'` object file without the
     field imports with null; a file with the value imports it; an empty or
     whitespace value imports as null; a value on a SOCKS5 entry is ignored; a
     bare array still imports; export followed by import keeps the value; after
     the value is cleared (assign null, as the editor does) the export contains
     no key and the import gives null.
   - Storage: with `SharedPreferences.setMockInitialValues`, seed
     `dnstt_configs` with an old `toJson` map that has no key;
     `StorageService.init()` and `getDnsttConfigs()` return null for the
     field. Then `saveDnsttConfigs` and `getDnsttConfigs` round-trip a config
     with the value through the same key. This is the proof that storage needs
     no new code, and it pins the existing `dnstt_configs` key. Call
     `setMockInitialValues` in each test; it resets the cached instance.
6. Add the application-level checks to the same test file.
   - `AppState.importDnsttConfigs` keeps the stored fingerprint for a
     duplicate (same domain and public key): importing the same config without
     the field, and importing it with a different value, both leave the stored
     fingerprint unchanged and only update the name. Give the imported entry a
     different name so the update path actually runs. Seed `dnstt_configs` as
     in step 5 and use the real `AppState.init`.
   - Widget test, edit without forgetting: seed an SSH config carrying the
     fingerprint, pump `ConfigManagementScreen` in a
     `ChangeNotifierProvider<AppState>.value` inside a `MaterialApp`, open the
     card's menu with `find.descendant(of: find.byType(Card), matching:
     find.byIcon(Icons.more_vert))`, tap `Edit`, tap `Save`, and check that
     `state.dnsttConfigs.single.sshHostKeyFingerprint` still has the value.
     This catches a missing `initState` initialization.
   - Widget test, forget and save: same setup, check that the value is shown
     in the dialog, `tester.ensureVisible` on `Forget host key` before tapping
     it (the dialog content is scrollable), then check that the button and the
     value are gone after the tap, tap `Save`, and check
     `state.dnsttConfigs.single.sshHostKeyFingerprint` is null. Decode the
     stored `dnstt_configs` value and confirm the field is null there too.
   - Widget test, switch to SOCKS5: same setup, tap the dialog's `Socks` tag
     with `find.descendant(of: find.byType(AlertDialog), matching:
     find.text('Socks'))` (the config card behind the dialog shows the same
     label), tap `Save`, and check the field is null in the state and in the
     stored JSON.
   - End the three widget tests with
     `await tester.pump(const Duration(seconds: 5))` so the save snackbar timer
     does not outlive the test.
7. Run `flutter analyze` and `flutter test` from the repository root; the
   whole suite must be green, not only the new file. Then inspect the diff:
   only the three production files that change above (the model, the
   import/export service and the editor) plus the new test file change;
   `git diff --check` passes; no Kotlin, Go, Gradle, workflow or documentation
   file is touched. Grep `sshHostKeyFingerprint` in `lib/` and confirm the
   model field, the import/export keys, the editor and the `dnstt_configs`
   JSON use the same spelling, which is also the channel key that
   [04-connect-wiring](../04-connect-wiring/plan.md) reads.

## Done when

- `DnsttConfig` has `sshHostKeyFingerprint` in the constructor, `toJson`,
  `fromJson` and `copyWith`; a map without the key loads with null, and the
  value survives the JSON round trip (the named tests in
  `test/config_fingerprint_test.dart`).
- `dnstt_configs` stores and loads the value through the existing key with no
  change to `storage_service.dart`; a seeded old value without the key loads
  with null.
- Export writes `version: 1.4`, emits the value for an SSH config that has
  one and no key for an SSH config without one or for a SOCKS5 config;
  import reads the value, treats an empty value as null, ignores it on a
  SOCKS5 entry, still imports a `1.3` file without the field and a bare
  array, and export followed by import keeps the value.
- The config editor shows the stored value as selectable monospace text with
  a `Forget host key` button in the SSH block and offers no input for it;
  saving without pressing the button keeps the value, pressing it and saving
  stores null in both `AppState` and `dnstt_configs`, and switching the tunnel
  type to SOCKS5 and saving clears it.
- Importing a duplicate (same domain and public key) neither loses nor
  replaces the stored fingerprint; only the name follows the import.
- `flutter analyze` is clean and `flutter test` passes, including the new
  file; no Kotlin, Go, Gradle, workflow or documentation change.
- No real server key, domain, address or other personal data appears in code,
  tests or comments.

## Risks and what is needed from the user

- The import deduplication in `AppState.importDnsttConfigs` only updates the
  name of an existing config found by domain and public key; a fingerprint in
  an imported duplicate does not replace the stored one. That is existing
  behavior for the other SSH fields and is kept here: the local fingerprint is
  the trusted one. The new tests pin it; making the import overwrite SSH
  fields would be a different decision.
- `copyWith` cannot set a field to null. Do not change its semantics for this
  one field; the editor and the save path assign directly.
- The editor works on the config object it opened. If
  [04-connect-wiring](../04-connect-wiring/plan.md) stores a newly accepted
  fingerprint while the dialog is open, saving the dialog overwrites it with
  the value the dialog read at open time. That matches the existing behavior
  for the SSH fields and the accepted "last save wins" rule of that task; do
  not build a merge or a reload into this task.
- Desktop: the model, storage and editor are platform-neutral and show and
  clear the field there too, but desktop SSH uses the system `ssh` and
  `known_hosts`, so the value does nothing for a desktop connection. Do not
  gate the field on `Platform.isAndroid`, and do not touch the desktop branch
  of `vpn_service.dart`; task 05 documents the Android-only effect.
- The widget tests are the fiddly part: the dialog content is scrollable, so
  `tester.ensureVisible` is needed before tapping `Forget host key`, and the
  save snackbar leaves a timer that the test must pump out. Do not delete the
  editor checks because of that; they are the only automated proof that an
  ordinary edit does not drop a stored fingerprint.
- The shared preferences file is private app data; the fingerprint is public,
  so storing it there adds no secret. Do not add a new preferences key.
- A config written before this change has no field and therefore accepts the
  first key on the next connection (TOFU), as the architecture requires. Do
  not migrate or invent a value in storage.
- Do not log credentials, and do not add the fingerprint to diagnostic
  output; the value is not secret, but the surrounding SSH config is.
- No user action is needed: no network, device or live SSH server is used.

## Outcome

`sshHostKeyFingerprint` is a first-class `DnsttConfig` field next to
`sshPrivateKey`, carried through the constructor, `toJson`, `fromJson` and
`copyWith`; a stored JSON without the key loads as null, which means trust on
first use. The import/exporter treats a missing, empty or whitespace value as
absent, ignores the field on a SOCKS5 entry and bumps the exported version from
`1.3` to `1.4`; `sshPrivateKey` is still not exported, and an SSH config
without a fingerprint emits no key. `storage_service.dart` is unchanged: the
field rides in the existing `dnstt_configs` value, and a test seeds an old
map without the key to prove a pre-change config loads with null.

The config editor keeps the value in `_ConfigDialogState._sshHostKeyFingerprint`,
initialized in `initState` from the opened config, and shows it in the SSH
block as selectable monospace text with a `Forget host key` button and no
confirmation dialog. An empty value shows the trust-on-first-use hint, and
there is no input for typing or pasting a fingerprint. Saving writes the value
for an SSH config and null for SOCKS5, symmetrically for a new and an existing
config; changing the domain, public key or transport type keeps it, switching
the tunnel type to SOCKS5 clears it. No platform check is added: the field has
no effect on desktop, where the system `ssh` runs with host key verification
disabled, as task 05 documents.

`AppState.importDnsttConfigs` keeps the locally stored fingerprint for a
duplicate found by domain and public key; only the name follows the import.
The new tests pin this for a duplicate without the field and for a duplicate
with a different value.

Decisions taken while moving:

- `_nonEmpty` returns null for a non-string value as well, so a number or an
  object in a hand-edited file cannot become a fingerprint.
- The export trims the value before writing it, and emits no key when the
  result is empty.
- The widget tests call `ensureVisible` for both `Forget host key` and the
  `Socks` tag, since the dialog content scrolls, and pump the save snackbar
  timer out with `pump(Duration(seconds: 5))` plus `pumpAndSettle` so no timer
  outlives the test. The ordinary-save test also decodes `dnstt_configs` and
  checks the stored JSON, not only `AppState`.

Checks: `test/config_fingerprint_test.dart` adds 20 tests (model 3,
export 3, import 7, storage 2, `AppState` 2, editor widgets 3); the full
`flutter test` suite passes (95 tests) and `flutter analyze` reports no issues;
`git diff --check` is clean. Apart from this plan, the diff touches only the
model, the import/export service, the editor and the new test file: no Kotlin,
Go, Gradle, workflow or other documentation file is changed.

Noticed while working: the exporter still writes `sshPassword` in clear text
(`config_import_export_service.dart`). That is pre-existing behaviour, kept
out of this task, which only adds the public fingerprint; worth revisiting if
the export format is ever treated as a safe way to move credentials.

Left by design: passing the stored fingerprint to Kotlin and persisting the
accepted one belongs to
[04-connect-wiring](../04-connect-wiring/plan.md); the Android-only effect and
the desktop split are written down in
[05-docs-and-review](../05-docs-and-review/plan.md); the live handshake check
is [06-live-check](../06-live-check/plan.md).
