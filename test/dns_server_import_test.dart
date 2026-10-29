import 'dart:convert';

import 'package:dnstt_xyz_app/models/dns_server.dart';
import 'package:dnstt_xyz_app/models/resolver_spec.dart';
import 'package:dnstt_xyz_app/services/config_import_export_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DnsServer JSON', () {
    test('entries stored before DoH/DoT load unchanged', () {
      final server = DnsServer.fromJson({
        'id': 'a',
        'address': '192.0.2.1',
        'name': 'Old',
        'isWorking': true,
      });
      expect(server.address, '192.0.2.1');
      expect(server.bootstrap, isNull);
      expect(server.kind, ResolverKind.udp);
      expect(server.toJson().containsKey('bootstrap'), isFalse);
    });

    test('bootstrap round trip', () {
      final server = DnsServer(address: 'https://dns.example/dns-query', bootstrap: '192.0.2.1');
      final copy = DnsServer.fromJson(jsonDecode(jsonEncode(server.toJson())));
      expect(copy.address, 'https://dns.example/dns-query');
      expect(copy.bootstrap, '192.0.2.1');
      expect(copy.kind, ResolverKind.doh);
      expect(copy.isEncrypted, isTrue);
    });

    test('an address that does not parse counts as UDP', () {
      expect(DnsServer(address: 'not a resolver').kind, ResolverKind.udp);
    });
  });

  group('import', () {
    test('mixed list: specs are normalized, invalid entries skipped', () {
      final servers = ConfigImportExportService.importDnsServersFromJson(jsonEncode({
        'servers': [
          {'ip': '192.0.2.1', 'name': 'Plain'},
          {'ip': '192.0.2.2:53'},
          {'address': '[2001:db8::1]:5353'},
          {'ip': 'HTTPS://DNS.example/dns-query', 'bootstrap': '192.0.2.3', 'name': 'DoH'},
          {'ip': 'tls://dns.example:853'},
          {'ip': '192.0.2.4', 'bootstrap': '192.0.2.5'},
          {'ip': 'tls://dot.example', 'bootstrap': 'dns.example'},
          {'ip': 'ftp://dns.example'},
          {'ip': '192.0.2.300'},
          {'name': 'No address'},
        ],
      }));
      expect([for (final s in servers) s.address], [
        '192.0.2.1',
        '192.0.2.2',
        '[2001:db8::1]:5353',
        'https://dns.example/dns-query',
        'tls://dns.example',
        '192.0.2.4',
      ]);
      expect(servers[0].name, 'Plain');
      expect(servers[3].bootstrap, '192.0.2.3');
      expect(servers[3].name, 'DoH');
      // A bootstrap address means nothing for plain UDP
      expect(servers[5].bootstrap, isNull);
    });

    test('export and import keep the bootstrap address', () {
      final exported = ConfigImportExportService.exportDnsServersToJson([
        DnsServer(address: 'tls://dns.example', bootstrap: '2001:db8::53', name: 'DoT'),
        DnsServer(address: '192.0.2.1'),
      ]);
      final servers = ConfigImportExportService.importDnsServersFromJson(exported);
      expect(servers.length, 2);
      expect(servers[0].address, 'tls://dns.example');
      expect(servers[0].bootstrap, '2001:db8::53');
      expect(servers[0].name, 'DoT');
      expect(servers[1].address, '192.0.2.1');
      expect(servers[1].bootstrap, isNull);
    });
  });

  test('sameResolver', () {
    expect(sameResolver('192.0.2.1', '192.0.2.1:53'), isTrue);
    expect(sameResolver('https://dns.example', 'https://dns.example/dns-query'), isTrue);
    expect(sameResolver('tls://dns.example', 'https://dns.example'), isFalse);
    expect(sameResolver('garbage', 'garbage'), isTrue);
  });
}
