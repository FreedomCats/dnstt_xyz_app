// Tests for the SSH connect wiring: the method channel reply map, the
// fingerprint the Dart service keeps after a successful connection, the
// changed-key text reaching lastError, and the AppState persistence helper.
//
// Every value here is documentation data: the domain t.example.com (RFC 2606),
// a made-up public key and the well-known SHA-256 fingerprint of the empty
// input.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dnstt_xyz_app/models/dnstt_config.dart';
import 'package:dnstt_xyz_app/providers/app_state.dart';
import 'package:dnstt_xyz_app/services/storage_service.dart';
import 'package:dnstt_xyz_app/services/vpn_service.dart';

const _channel = MethodChannel('xyz.dnstt.app/vpn');
const _fingerprint = 'SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU';
const _domain = 't.example.com';
const _configId = 'config-1';

final _publicKey = List.filled(64, '0').join();

/// A plausible but made-up fingerprint, distinct from the stored one, so the
/// test proves the presented value is the one that reaches the getter.
final _presentedFingerprint = 'SHA256:${List.filled(43, 'A').join()}';

DnsttConfig _config({String? fingerprint, String id = _configId}) => DnsttConfig(
      id: id,
      name: 'Test SSH',
      publicKey: _publicKey,
      tunnelDomain: _domain,
      tunnelType: TunnelType.ssh,
      sshUsername: 'user',
      sshPassword: 'password',
      sshHostKeyFingerprint: fingerprint,
    );

String? _storedFingerprint(String rawJson) {
  final stored = jsonDecode(rawJson) as List;
  return (stored.single as Map<String, dynamic>)['sshHostKeyFingerprint']
      as String?;
}

Future<AppState> _stateWithConfig({String? fingerprint}) async {
  final config = _config(fingerprint: fingerprint);
  SharedPreferences.setMockInitialValues({
    'dnstt_configs': jsonEncode([config.toJson()]),
    'active_config': config.id,
  });
  final storage = await StorageService.init();
  final state = AppState();
  await state.init(storage);
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VpnService SSH channel', () {
    late String? lastMethod;
    late Map<Object?, Object?>? lastArguments;
    late Future<Object?> Function(MethodCall call) handler;

    setUp(() {
      lastMethod = null;
      lastArguments = null;
      handler = (call) async => null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        lastMethod = call.method;
        lastArguments = call.arguments as Map<Object?, Object?>?;
        return handler(call);
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });

    test('successful connect stores the accepted fingerprint and sends the '
        'expected one', () async {
      handler = (call) async => {
            'connected': true,
            'hostKeyFingerprint': _presentedFingerprint,
            'error': null,
          };

      final result = await VpnService().connectSshTunnel(
        dnsServer: '192.0.2.1',
        tunnelDomain: _domain,
        publicKey: _publicKey,
        sshUsername: 'user',
        sshPassword: 'password',
        sshHostKeyFingerprint: _fingerprint,
      );

      expect(lastMethod, 'connectSshTunnel');
      expect(lastArguments!['sshHostKeyFingerprint'], _fingerprint);
      expect(result, isTrue);
      expect(VpnService().lastSshHostKeyFingerprint, _presentedFingerprint);
      expect(VpnService().lastError, isNull);
    });

    test('changed key reports the native text and clears the observed '
        'fingerprint', () async {
      handler = (call) async => {
            'connected': true,
            'hostKeyFingerprint': _presentedFingerprint,
            'error': null,
          };
      await VpnService().connectSshTunnel(
        dnsServer: '192.0.2.1',
        tunnelDomain: _domain,
        publicKey: _publicKey,
        sshUsername: 'user',
        sshPassword: 'password',
        sshHostKeyFingerprint: _fingerprint,
      );
      expect(VpnService().lastSshHostKeyFingerprint, _presentedFingerprint);

      final message =
          'SSH host key changed: stored $_fingerprint, server presented '
          '$_presentedFingerprint. If the server really changed, forget the '
          'host key in the config.';
      handler = (call) async => {
            'connected': false,
            'hostKeyFingerprint': null,
            'error': message,
          };

      final result = await VpnService().connectSshTunnel(
        dnsServer: '192.0.2.1',
        tunnelDomain: _domain,
        publicKey: _publicKey,
        sshUsername: 'user',
        sshPassword: 'password',
        sshHostKeyFingerprint: _fingerprint,
      );

      expect(result, isFalse);
      expect(VpnService().lastError, message);
      expect(VpnService().lastSshHostKeyFingerprint, isNull);
    });

    test('VPN connect sends the same argument and parses the same map',
        () async {
      handler = (call) async => {
            'connected': true,
            'hostKeyFingerprint': _presentedFingerprint,
            'error': null,
          };

      final result = await VpnService().connectSshTunnelVpn(
        dnsServer: '192.0.2.1',
        tunnelDomain: _domain,
        publicKey: _publicKey,
        sshUsername: 'user',
        sshPassword: 'password',
        sshHostKeyFingerprint: _fingerprint,
      );

      expect(lastMethod, 'connectSshTunnelVpn');
      expect(lastArguments!['sshHostKeyFingerprint'], _fingerprint);
      expect(result, isTrue);
      expect(VpnService().lastSshHostKeyFingerprint, _presentedFingerprint);
      expect(VpnService().lastError, isNull);
    });

    test('a bare boolean reply is tolerated', () async {
      handler = (call) async => true;

      final result = await VpnService().connectSshTunnel(
        dnsServer: '192.0.2.1',
        tunnelDomain: _domain,
        publicKey: _publicKey,
        sshUsername: 'user',
        sshPassword: 'password',
        sshHostKeyFingerprint: _fingerprint,
      );

      expect(result, isTrue);
      expect(VpnService().lastSshHostKeyFingerprint, isNull);
      expect(VpnService().lastError, isNull);
    });
  });

  group('AppState.rememberSshHostKeyFingerprint', () {
    test('writes a null fingerprint into the active config and storage',
        () async {
      final state = await _stateWithConfig();
      expect(state.activeConfig?.sshHostKeyFingerprint, isNull);

      await state.rememberSshHostKeyFingerprint(
        configId: _configId,
        fingerprint: _presentedFingerprint,
      );

      expect(state.activeConfig?.sshHostKeyFingerprint, _presentedFingerprint);
      expect(state.dnsttConfigs.single.sshHostKeyFingerprint,
          _presentedFingerprint);
      final prefs = await SharedPreferences.getInstance();
      expect(
        _storedFingerprint(prefs.getString('dnstt_configs')!),
        _presentedFingerprint,
      );
    });

    test('an equal value leaves the stored value unchanged', () async {
      final state = await _stateWithConfig(fingerprint: _fingerprint);

      await state.rememberSshHostKeyFingerprint(
        configId: _configId,
        fingerprint: _fingerprint,
      );

      expect(state.activeConfig?.sshHostKeyFingerprint, _fingerprint);
      expect(state.dnsttConfigs.single.sshHostKeyFingerprint, _fingerprint);
      final prefs = await SharedPreferences.getInstance();
      expect(_storedFingerprint(prefs.getString('dnstt_configs')!), _fingerprint);
    });

    test('a null or blank value writes nothing', () async {
      final state = await _stateWithConfig(fingerprint: _fingerprint);

      await state.rememberSshHostKeyFingerprint(
        configId: _configId,
        fingerprint: null,
      );
      await state.rememberSshHostKeyFingerprint(
        configId: _configId,
        fingerprint: '   ',
      );

      expect(state.activeConfig?.sshHostKeyFingerprint, _fingerprint);
      expect(state.dnsttConfigs.single.sshHostKeyFingerprint, _fingerprint);
      final prefs = await SharedPreferences.getInstance();
      expect(_storedFingerprint(prefs.getString('dnstt_configs')!), _fingerprint);
    });

    test('a different config id writes nothing', () async {
      final state = await _stateWithConfig();

      await state.rememberSshHostKeyFingerprint(
        configId: 'other-config',
        fingerprint: _presentedFingerprint,
      );

      expect(state.activeConfig?.sshHostKeyFingerprint, isNull);
      expect(state.dnsttConfigs.single.sshHostKeyFingerprint, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(_storedFingerprint(prefs.getString('dnstt_configs')!), isNull);
    });
  });
}
