import 'package:dnstt_xyz_app/models/resolver_spec.dart';
import 'package:flutter_test/flutter_test.dart';

/// The cases of TestParseResolver in go_src/client/resolver_test.go, with the
/// short canonical form the app stores. kind == null means invalid.
const _udp = ResolverKind.udp;
const _doh = ResolverKind.doh;
const _dot = ResolverKind.dot;

final _cases = <(String, ResolverKind?, String, int, String, String)>[
  // UDP without scheme: the format stored by the app until now
  ('192.0.2.1', _udp, '192.0.2.1', 53, '', '192.0.2.1'),
  (' 192.0.2.1 ', _udp, '192.0.2.1', 53, '', '192.0.2.1'),
  ('192.0.2.1:5353', _udp, '192.0.2.1', 5353, '', '192.0.2.1:5353'),
  ('192.0.2.1:53', _udp, '192.0.2.1', 53, '', '192.0.2.1'),
  ('2001:db8::1', _udp, '2001:db8::1', 53, '', '2001:db8::1'),
  ('2001:DB8::1', _udp, '2001:db8::1', 53, '', '2001:db8::1'),
  ('2001:db8:0:0:0:0:0:1', _udp, '2001:db8::1', 53, '', '2001:db8::1'),
  ('2001:db8:0:1:0:0:0:1', _udp, '2001:db8:0:1::1', 53, '', '2001:db8:0:1::1'),
  ('[2001:db8::1]', _udp, '2001:db8::1', 53, '', '2001:db8::1'),
  ('[2001:db8::1]:5353', _udp, '2001:db8::1', 5353, '', '[2001:db8::1]:5353'),
  ('::ffff:192.0.2.1', _udp, '::ffff:192.0.2.1', 53, '', '::ffff:192.0.2.1'),
  ('dns.example', _udp, 'dns.example', 53, '', 'dns.example'),
  ('DNS.Example.:54', _udp, 'dns.example', 54, '', 'dns.example:54'),
  ('192.0.2.300', null, '', 0, '', ''),
  ('192.0.2.01', null, '', 0, '', ''),
  ('192.0.2', null, '', 0, '', ''),
  ('192.0.2.1:0', null, '', 0, '', ''),
  ('192.0.2.1:65536', null, '', 0, '', ''),
  ('192.0.2.1:+53', null, '', 0, '', ''),
  ('192.0.2.1:', null, '', 0, '', ''),
  ('fe80::1%eth0', null, '', 0, '', ''),
  ('[fe80::1%eth0]:53', null, '', 0, '', ''),
  ('[192.0.2.1]x', null, '', 0, '', ''),
  ('dns_server.example', null, '', 0, '', ''),
  ('-dns.example', null, '', 0, '', ''),
  ('dns..example', null, '', 0, '', ''),
  ('', null, '', 0, '', ''),
  ('   ', null, '', 0, '', ''),

  // udp://
  ('udp://192.0.2.1', _udp, '192.0.2.1', 53, '', '192.0.2.1'),
  ('UDP://192.0.2.1:5353', _udp, '192.0.2.1', 5353, '', '192.0.2.1:5353'),
  ('udp://[2001:db8::1]:53', _udp, '2001:db8::1', 53, '', '2001:db8::1'),
  ('udp://dns.example', _udp, 'dns.example', 53, '', 'dns.example'),
  ('udp://192.0.2.1/x', null, '', 0, '', ''),
  ('udp://192.0.2.1?x', null, '', 0, '', ''),
  ('udp://2001:db8::1', null, '', 0, '', ''),
  ('udp://', null, '', 0, '', ''),

  // DoH
  ('https://dns.example/dns-query', _doh, 'dns.example', 443, '/dns-query', 'https://dns.example/dns-query'),
  ('https://dns.example', _doh, 'dns.example', 443, '/dns-query', 'https://dns.example/dns-query'),
  ('https://dns.example/', _doh, 'dns.example', 443, '/', 'https://dns.example/'),
  ('HTTPS://DNS.example:8443/q?ct=x', _doh, 'dns.example', 8443, '/q?ct=x', 'https://dns.example:8443/q?ct=x'),
  ('https://192.0.2.1/dns-query', _doh, '192.0.2.1', 443, '/dns-query', 'https://192.0.2.1/dns-query'),
  ('https://[2001:db8::1]/dns-query', _doh, '2001:db8::1', 443, '/dns-query', 'https://[2001:db8::1]/dns-query'),
  ('https://[2001:db8::1]:444/x', _doh, '2001:db8::1', 444, '/x', 'https://[2001:db8::1]:444/x'),
  ('https://dns.example/a%20b', _doh, 'dns.example', 443, '/a%20b', 'https://dns.example/a%20b'),
  ('https://dns.example:443/dns-query', _doh, 'dns.example', 443, '/dns-query', 'https://dns.example/dns-query'),
  ('https://user@dns.example/dns-query', null, '', 0, '', ''),
  ('https://dns.example/dns-query#x', null, '', 0, '', ''),
  ('https://dns.example:/dns-query', null, '', 0, '', ''),
  ('https://dns.example:0/', null, '', 0, '', ''),
  ('https:///dns-query', null, '', 0, '', ''),
  ('http://dns.example/dns-query', null, '', 0, '', ''),
  ('https://dns.example/a b', null, '', 0, '', ''),

  // DoT
  ('tls://dns.example', _dot, 'dns.example', 853, '', 'tls://dns.example'),
  ('tls://192.0.2.1:8853', _dot, '192.0.2.1', 8853, '', 'tls://192.0.2.1:8853'),
  ('tls://[2001:db8::1]', _dot, '2001:db8::1', 853, '', 'tls://[2001:db8::1]'),
  ('tls://dns.example/x', null, '', 0, '', ''),
  ('tls://dns.example/', null, '', 0, '', ''),

  ('ftp://dns.example', null, '', 0, '', ''),
  ('://dns.example', null, '', 0, '', ''),
];

void main() {
  group('ResolverSpec.tryParse', () {
    for (final (spec, kind, host, port, path, short) in _cases) {
      test('"$spec"', () {
        final r = ResolverSpec.tryParse(spec);
        if (kind == null) {
          expect(r, isNull);
          return;
        }
        expect(r, isNotNull);
        expect(r!.kind, kind);
        expect(r.host, host);
        expect(r.port, port);
        expect(r.path, path);
        expect(r.toString(), short);
        expect(ResolverSpec.tryParse(r.toString()), r);
      });
    }
  });

  test('address', () {
    expect(ResolverSpec.tryParse('192.0.2.1')!.address, '192.0.2.1:53');
    expect(ResolverSpec.tryParse('2001:db8::1')!.address, '[2001:db8::1]:53');
    expect(ResolverSpec.tryParse('dns.example:5353')!.address, 'dns.example:5353');
  });

  test('normalizeBootstrap', () {
    expect(ResolverSpec.normalizeBootstrap('192.0.2.1'), '192.0.2.1');
    expect(ResolverSpec.normalizeBootstrap(' 2001:DB8::1 '), '2001:db8::1');
    expect(ResolverSpec.normalizeBootstrap('[2001:db8::1]'), '2001:db8::1');
    expect(ResolverSpec.normalizeBootstrap('::ffff:192.0.2.1'), '192.0.2.1');
    expect(ResolverSpec.normalizeBootstrap(''), isNull);
    expect(ResolverSpec.normalizeBootstrap('dns.example'), isNull);
    expect(ResolverSpec.normalizeBootstrap('192.0.2.1:53'), isNull);
    expect(ResolverSpec.normalizeBootstrap('fe80::1%eth0'), isNull);
  });
}
