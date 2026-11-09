// Tests for the SSH host key fingerprint config field: model serialization,
// import/export, storage round-trips, AppState import deduplication and the
// config editor's forget and switch-to-SOCKS5 behaviour.
//
// Every value here is documentation data: the domain t.example.com (RFC 2606),
// a made-up public key and the well-known SHA-256 fingerprint of the empty
// input.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dnstt_xyz_app/models/dnstt_config.dart';
import 'package:dnstt_xyz_app/providers/app_state.dart';
import 'package:dnstt_xyz_app/screens/config_management_screen.dart';
import 'package:dnstt_xyz_app/services/config_import_export_service.dart';
import 'package:dnstt_xyz_app/services/storage_service.dart';

const _fingerprint = 'SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU';
const _domain = 't.example.com';

final _publicKey = List.filled(64, '0').join();

/// A plausible but made-up fingerprint, used to prove an import does not
/// replace the locally stored one.
final _otherFingerprint = 'SHA256:${List.filled(43, 'A').join()}';

DnsttConfig _sshConfig({
  String name = 'Test SSH',
  String? fingerprint = _fingerprint,
}) =>
    DnsttConfig(
      name: name,
      publicKey: _publicKey,
      tunnelDomain: _domain,
      tunnelType: TunnelType.ssh,
      sshUsername: 'user',
      sshPassword: 'password',
      sshHostKeyFingerprint: fingerprint,
    );

/// An imported entry in the pre-fingerprint shape, optionally with the field.
Map<String, dynamic> _configJson({
  String name = 'Imported SSH',
  String tunnelType = 'ssh',
  Object? fingerprint = _fingerprint,
  bool includeFingerprint = true,
}) {
  final json = <String, dynamic>{
    'name': name,
    'publicKey': _publicKey,
    'tunnelDomain': _domain,
    'transportType': 'dnstt',
    'tunnelType': tunnelType,
  };
  if (includeFingerprint) {
    json['sshHostKeyFingerprint'] = fingerprint;
  }
  return json;
}

List<DnsttConfig> _importJson(Object data) =>
    ConfigImportExportService.importConfigsFromJson(jsonEncode(data));

/// A pre-change config JSON: no sshHostKeyFingerprint key at all.
Map<String, dynamic> _oldConfigJson() => {
      'id': 'old-config',
      'name': 'Old SSH',
      'publicKey': _publicKey,
      'tunnelDomain': _domain,
      'transportType': 'dnstt',
      'tunnelType': 'ssh',
      'sshUsername': 'user',
      'sshPassword': 'password',
    };

Map<String, dynamic> _singleExportedEntry(List<DnsttConfig> configs) {
  final exported =
      jsonDecode(ConfigImportExportService.exportConfigsToJson(configs))
          as Map<String, dynamic>;
  return (exported['configs'] as List).single as Map<String, dynamic>;
}

Future<AppState> _stateWithStoredConfig() async {
  SharedPreferences.setMockInitialValues({
    'dnstt_configs': jsonEncode([_sshConfig().toJson()]),
  });
  final storage = await StorageService.init();
  final state = AppState();
  await state.init(storage);
  return state;
}

Future<AppState> _pumpEditor(WidgetTester tester) async {
  final state = await _stateWithStoredConfig();
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: ConfigManagementScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

Future<void> _openEditor(WidgetTester tester) async {
  await tester.tap(find.descendant(
    of: find.byType(Card),
    matching: find.byIcon(Icons.more_vert),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Edit'));
  await tester.pumpAndSettle();
}

String? _storedFingerprint(String rawJson) {
  final stored = jsonDecode(rawJson) as List;
  return (stored.single as Map<String, dynamic>)['sshHostKeyFingerprint']
      as String?;
}

void main() {
  group('DnsttConfig', () {
    test('a config without the field loads with null', () {
      final config = DnsttConfig.fromJson(_oldConfigJson());

      expect(config.sshHostKeyFingerprint, isNull);
    });

    test('the fingerprint survives the JSON round trip', () {
      final config = _sshConfig();
      final decoded = DnsttConfig.fromJson(
        jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>,
      );

      expect(decoded.id, config.id);
      expect(decoded.sshHostKeyFingerprint, _fingerprint);
    });

    test('copyWith keeps the fingerprint when another field changes', () {
      final updated = _sshConfig().copyWith(name: 'Renamed');

      expect(updated.name, 'Renamed');
      expect(updated.sshHostKeyFingerprint, _fingerprint);
    });
  });

  group('export', () {
    test('writes version 1.4 and emits the fingerprint for an SSH config', () {
      final exported = jsonDecode(
        ConfigImportExportService.exportConfigsToJson([_sshConfig()]),
      ) as Map<String, dynamic>;
      final entry =
          (exported['configs'] as List).single as Map<String, dynamic>;

      expect(exported['version'], '1.4');
      expect(entry['sshHostKeyFingerprint'], _fingerprint);
      expect(entry.containsKey('sshPrivateKey'), isFalse);
    });

    test('omits the fingerprint for a SOCKS5 config', () {
      final socks = _sshConfig().copyWith(tunnelType: TunnelType.socks5);
      final entry = _singleExportedEntry([socks]);

      expect(entry.containsKey('sshHostKeyFingerprint'), isFalse);
    });

    test('omits the fingerprint for an SSH config without one', () {
      final entry = _singleExportedEntry([_sshConfig(fingerprint: null)]);

      expect(entry.containsKey('sshHostKeyFingerprint'), isFalse);
    });
  });

  group('import', () {
    test('a 1.3 file without the field imports with null', () {
      final configs = _importJson({
        'version': '1.3',
        'configs': [_configJson(includeFingerprint: false)],
      });

      expect(configs.single.sshHostKeyFingerprint, isNull);
    });

    test('a file with the field imports it', () {
      final configs = _importJson({
        'version': '1.4',
        'configs': [_configJson()],
      });

      expect(configs.single.sshHostKeyFingerprint, _fingerprint);
    });

    test('an empty or whitespace value imports as null', () {
      final configs = _importJson([
        _configJson(name: 'Empty', fingerprint: ''),
        _configJson(name: 'Blank', fingerprint: '   '),
      ]);

      expect(configs, hasLength(2));
      expect(
        configs.map((c) => c.sshHostKeyFingerprint),
        everyElement(isNull),
      );
    });

    test('a fingerprint on a SOCKS5 entry is ignored', () {
      final configs = _importJson([_configJson(tunnelType: 'socks5')]);

      expect(configs.single.tunnelType, TunnelType.socks5);
      expect(configs.single.sshHostKeyFingerprint, isNull);
    });

    test('a bare array still imports', () {
      final configs = _importJson([_configJson()]);

      expect(configs.single.tunnelDomain, _domain);
      expect(configs.single.sshHostKeyFingerprint, _fingerprint);
    });

    test('export followed by import keeps the fingerprint', () {
      final exported =
          ConfigImportExportService.exportConfigsToJson([_sshConfig()]);
      final configs =
          ConfigImportExportService.importConfigsFromJson(exported);

      expect(configs.single.sshHostKeyFingerprint, _fingerprint);
    });

    test('a cleared fingerprint is not exported and imports as null', () {
      final config = _sshConfig();
      // The editor clears the field by assigning null directly, as copyWith
      // cannot clear it.
      config.sshHostKeyFingerprint = null;

      final entry = _singleExportedEntry([config]);
      final configs = ConfigImportExportService.importConfigsFromJson(
        ConfigImportExportService.exportConfigsToJson([config]),
      );

      expect(entry.containsKey('sshHostKeyFingerprint'), isFalse);
      expect(configs.single.sshHostKeyFingerprint, isNull);
    });
  });

  group('storage', () {
    test('a stored old config without the field loads with null', () async {
      SharedPreferences.setMockInitialValues({
        'dnstt_configs': jsonEncode([_oldConfigJson()]),
      });
      final storage = await StorageService.init();

      final configs = await storage.getDnsttConfigs();

      expect(configs, hasLength(1));
      expect(configs.single.sshHostKeyFingerprint, isNull);
    });

    test('the fingerprint round-trips through the dnstt_configs key',
        () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();

      await storage.saveDnsttConfigs([_sshConfig()]);
      final configs = await storage.getDnsttConfigs();
      final prefs = await SharedPreferences.getInstance();

      expect(configs.single.sshHostKeyFingerprint, _fingerprint);
      expect(
        _storedFingerprint(prefs.getString('dnstt_configs')!),
        _fingerprint,
      );
    });
  });

  group('AppState.importDnsttConfigs', () {
    test('a duplicate without the field keeps the fingerprint and updates '
        'the name', () async {
      final state = await _stateWithStoredConfig();

      final result = await state.importDnsttConfigs([
        _sshConfig(name: 'Renamed', fingerprint: null),
      ]);

      expect(result.added, 0);
      expect(result.updated, 1);
      expect(state.dnsttConfigs.single.name, 'Renamed');
      expect(state.dnsttConfigs.single.sshHostKeyFingerprint, _fingerprint);
    });

    test('a duplicate with another fingerprint keeps the stored one',
        () async {
      final state = await _stateWithStoredConfig();

      final result = await state.importDnsttConfigs([
        _sshConfig(name: 'Renamed Again', fingerprint: _otherFingerprint),
      ]);

      expect(result.added, 0);
      expect(result.updated, 1);
      expect(state.dnsttConfigs.single.name, 'Renamed Again');
      expect(state.dnsttConfigs.single.sshHostKeyFingerprint, _fingerprint);
    });
  });

  group('config editor', () {
    testWidgets('saving without forgetting keeps the fingerprint',
        (tester) async {
      final state = await _pumpEditor(tester);
      await _openEditor(tester);

      expect(find.text(_fingerprint), findsOneWidget);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(state.dnsttConfigs.single.sshHostKeyFingerprint, _fingerprint);
      expect(
        _storedFingerprint(prefs.getString('dnstt_configs')!),
        _fingerprint,
      );

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('forget then save clears the fingerprint in state and storage',
        (tester) async {
      final state = await _pumpEditor(tester);
      await _openEditor(tester);

      expect(find.text(_fingerprint), findsOneWidget);

      final forget = find.widgetWithText(TextButton, 'Forget host key');
      await tester.ensureVisible(forget);
      await tester.pumpAndSettle();
      await tester.tap(forget);
      await tester.pumpAndSettle();

      expect(find.text('Forget host key'), findsNothing);
      expect(find.text(_fingerprint), findsNothing);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(state.dnsttConfigs.single.sshHostKeyFingerprint, isNull);
      expect(_storedFingerprint(prefs.getString('dnstt_configs')!), isNull);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('switching to SOCKS5 and saving clears the fingerprint',
        (tester) async {
      final state = await _pumpEditor(tester);
      await _openEditor(tester);

      final socksTag = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Socks'),
      );
      await tester.ensureVisible(socksTag);
      await tester.pumpAndSettle();
      await tester.tap(socksTag);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(state.dnsttConfigs.single.tunnelType, TunnelType.socks5);
      expect(state.dnsttConfigs.single.sshHostKeyFingerprint, isNull);
      expect(_storedFingerprint(prefs.getString('dnstt_configs')!), isNull);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });
}
