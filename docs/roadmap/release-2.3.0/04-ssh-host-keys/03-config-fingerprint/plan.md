---
kind: task
status: todo
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
it in and persists the accepted value.

The value is the display form used by `ssh-keygen -lf`:
`SHA256:` plus unpadded standard base64 of the key blob's SHA-256. A config
without the field (every config written before this change) means "no key
remembered" and accepts the first key it sees.

## Steps

1. `lib/models/dnstt_config.dart`: add
   `String? sshHostKeyFingerprint;` after `sshPrivateKey` (line 41), the
   constructor parameter after `sshPrivateKey` (line 67), the `toJson` entry
   after `sshPrivateKey` (line 84), the `fromJson` entry after `sshPrivateKey`
   (line 101) and the `copyWith` parameter/assignment (lines 181, 197). Keep
   `copyWith`'s null-coalescing semantics: it cannot clear a field to null, so
   the editor clears by assigning the field directly, as it already does for
   the other SSH fields.
2. `lib/services/config_import_export_service.dart`:
   - Parse `sshHostKeyFingerprint: item['sshHostKeyFingerprint']?.toString()`
     in the SSH group (lines 83-85). A missing or empty value stays null.
   - Export it in the SSH block (lines 159-163) only when it is non-null:
     `configMap['sshHostKeyFingerprint'] = c.sshHostKeyFingerprint;`.
   - Bump the exported `version` from `1.3` to `1.4` at line 132. This follows
     the existing precedent: the field addition for transport/SSH settings
     bumped `1.2` to `1.3`. Import ignores the version and must keep accepting
     `1.3` files without the field.
3. `lib/services/storage_service.dart`: no new `SharedPreferences` key and no
   code change. `getDnsttConfigs`/`saveDnsttConfigs` (lines 64-74) already
   round-trip the whole `DnsttConfig` JSON, so the field rides in the existing
   `dnstt_configs` value; an older stored JSON without the key loads as null.
   Verify this with the test in step 5 rather than by adding storage code.
4. `lib/screens/config_management_screen.dart`, stateful config dialog
   (`_ConfigDialogState`, from line 782):
   - Add `String? _sshHostKeyFingerprint` and initialize it in `initState` from
     `widget.existingConfig?.sshHostKeyFingerprint`.
   - In the SSH settings block (lines 1008-1040), after the SSH password field,
     show the stored fingerprint when it is non-null and non-empty: a small
     caption such as "SSH host key" and the value in a monospace, selectable
     text, plus a `TextButton` labelled "Forget host key" that sets
     `_sshHostKeyFingerprint = null` with `setState`. No dialog is needed for
     the reset; the user saves the config afterwards.
   - In `_saveConfig`, pass
     `sshHostKeyFingerprint: selectedTunnelType == TunnelType.ssh ? _sshHostKeyFingerprint : null`
     to the new `DnsttConfig` (lines 1155-1178) and assign the same expression
     to `widget.existingConfig!.sshHostKeyFingerprint` (lines 1180-1202).
     Switching a config away from SSH clears the field.
   - Do not clear the fingerprint when the domain or server changes: a changed
     server must be refused until the user forgets the key. The refusal message
     points at the editor.
5. Add `test/config_fingerprint_test.dart`:
   - A JSON map with the old fields and no `sshHostKeyFingerprint` loads with
     null; `toJson`/`fromJson` round-trips the value.
   - `exportConfigsToJson` emits the field for an SSH config and does not emit
     it for a SOCKS5 config; `importConfigsFromJson` reads it; export→import
     keeps the same value; the exported `version` is `1.4`.
   - Clearing the field (assigning null, as the editor does) exports no key and
     imports back as null.
   - Use a documentation value such as
     `SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU`; no real server key
     and no personal data.
6. Run `flutter analyze` and `flutter test` from the repository root. No Kotlin
   test is needed here; the Kotlin side is covered by tasks 01 and 04.

## Done when

- `DnsttConfig` carries `sshHostKeyFingerprint` through its constructor,
  `toJson` and `fromJson`, and configs stored before the change load with null.
- Import and export carry the field for SSH configs, the exported version is
  `1.4`, and `1.3` files without the field still import.
- The config editor shows the stored fingerprint and "Forget host key" clears
  it on save; switching the tunnel type away from SSH clears it.
- `StorageService` needs no new key: the field is part of the existing config
  JSON, proven by the round-trip test.
- `flutter analyze` and `flutter test` are green; no Kotlin, Go or Gradle
  changes.
- No real server key, address, domain or other personal data appears in code,
  tests or docs.

## Risks and what is needed from the user

- The import deduplication in `AppState.importDnsttConfigs`
  (`lib/providers/app_state.dart:195-220`) only updates the name of an existing
  config found by domain and public key; a fingerprint in an imported duplicate
  does not replace the stored one. That is existing behavior for the other SSH
  fields and is not changed here.
- `copyWith` cannot set a field to null. Do not change its semantics for this
  one field; the editor and the save path assign directly.
- The shared preferences file is private app data; the fingerprint is public,
  but do not log credentials or add the value to diagnostic output.
- No user action is needed: no network, device or live SSH server is used.
