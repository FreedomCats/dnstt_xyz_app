/// Transport of a DNS resolver.
enum ResolverKind {
  udp('UDP'),
  doh('DoH'),
  dot('DoT');

  const ResolverKind(this.label);

  /// Short name for display.
  final String label;
}

/// Choices for the TLS fingerprint setting of DoH and DoT connections: uTLS
/// fingerprint labels of the Go library, '' for its default distribution
/// (common browsers) and 'none' for Go's own TLS.
const tlsFingerprintChoices = {
  '': 'Auto',
  'Chrome': 'Chrome',
  'Firefox': 'Firefox',
  'Safari': 'Safari',
  'iOS': 'iOS',
  'Edge': 'Edge',
  'none': 'Off (Go TLS)',
};

/// Whether two resolver specs name the same resolver.
bool sameResolver(String a, String b) {
  if (a == b) return true;
  final ra = ResolverSpec.tryParse(a);
  return ra != null && ra == ResolverSpec.tryParse(b);
}

/// A parsed resolver spec, as `client.ParseResolver` in `go_src/client`
/// accepts it:
///
///     192.0.2.1, 192.0.2.1:5353          UDP (port 53 by default)
///     2001:db8::1, [2001:db8::1]:5353    UDP
///     dns.example, udp://host[:port]     UDP
///     https://host[:port][/path][?query] DoH (port 443, path /dns-query by default)
///     tls://host[:port]                  DoT (port 853)
///
/// The app validates and normalizes specs with it; the native side parses
/// them again with the Go parser, which accepts everything this one does.
class ResolverSpec {
  final ResolverKind kind;

  /// IP address or lower-case host name, without brackets.
  final String host;
  final int port;

  /// DoH request path with the query string, starting with "/"; empty for
  /// other kinds.
  final String path;

  const ResolverSpec._(this.kind, this.host, this.port, [this.path = '']);

  static const _defaultPorts = {
    ResolverKind.udp: 53,
    ResolverKind.doh: 443,
    ResolverKind.dot: 853,
  };

  /// Parses [spec]; returns null if it is not a valid resolver.
  static ResolverSpec? tryParse(String spec) {
    final s = spec.trim();
    if (s.isEmpty) return null;
    final i = s.indexOf('://');
    if (i < 0) return _parseUdpAddr(s);

    final kind = switch (s.substring(0, i).toLowerCase()) {
      'udp' => ResolverKind.udp,
      'https' => ResolverKind.doh,
      'tls' => ResolverKind.dot,
      _ => null,
    };
    if (kind == null || s.contains('#')) return null;

    final rest = s.substring(i + 3);
    var end = rest.indexOf(RegExp(r'[/?]'));
    if (end < 0) end = rest.length;
    final authority = rest.substring(0, end);
    final pathAndQuery = rest.substring(end);
    if (authority.isEmpty || authority.contains('@')) return null;

    String hostPart;
    String? portPart;
    if (authority.startsWith('[')) {
      final close = authority.indexOf(']');
      if (close < 0) return null;
      hostPart = authority.substring(1, close);
      final after = authority.substring(close + 1);
      if (after.isNotEmpty) {
        if (!after.startsWith(':')) return null;
        portPart = after.substring(1);
      }
    } else {
      final colon = authority.lastIndexOf(':');
      hostPart = colon < 0 ? authority : authority.substring(0, colon);
      if (colon >= 0) portPart = authority.substring(colon + 1);
    }
    final host = _checkHost(hostPart);
    if (host == null) return null;
    var port = _defaultPorts[kind]!;
    if (portPart != null) {
      final p = _parsePort(portPart);
      if (p == null) return null;
      port = p;
    }

    final q = pathAndQuery.indexOf('?');
    final path = q < 0 ? pathAndQuery : pathAndQuery.substring(0, q);
    final query = q < 0 ? null : pathAndQuery.substring(q + 1);
    if (kind != ResolverKind.doh) {
      if (pathAndQuery.isNotEmpty) return null;
      return ResolverSpec._(kind, host, port);
    }
    if (!_pathPattern.hasMatch(path) || (query != null && !_queryPattern.hasMatch(query))) {
      return null;
    }
    var fullPath = path.isEmpty ? '/dns-query' : path;
    if (query != null && query.isNotEmpty) fullPath += '?$query';
    return ResolverSpec._(kind, host, port, fullPath);
  }

  /// Whether [spec] is a valid resolver spec.
  static bool isValid(String spec) => tryParse(spec) != null;

  /// Returns the canonical form of a bootstrap address (an IPv4 or IPv6
  /// address without zone, optionally in brackets), or null if it is invalid.
  static String? normalizeBootstrap(String s) {
    var t = s.trim();
    if (t.startsWith('[') && t.endsWith(']')) t = t.substring(1, t.length - 1);
    final v4 = _parseIPv4(t);
    if (v4 != null) return v4;
    if (!t.contains(':') || t.contains('%')) return null;
    final v6 = _parseIPv6(t);
    if (v6 == null) return null;
    if (_isV4Mapped(v6)) return v6.sublist(12).join('.');
    return _formatIPv6(v6);
  }

  /// Kind of [spec], or null if it is invalid.
  static ResolverKind? kindOf(String spec) => tryParse(spec)?.kind;

  bool get _isIPv6 => host.contains(':');

  String get _bracketedHost => _isIPv6 ? '[$host]' : host;

  /// host:port, with brackets around an IPv6 address (for UDP resolvers, the
  /// value for `slipstream-client --resolver`).
  String get address => '$_bracketedHost:$port';

  /// Short canonical form, the one stored in `DnsServer.address`: the default
  /// port is left out. The Go parser reads it back to the same resolver.
  @override
  String toString() {
    final defaultPort = port == _defaultPorts[kind];
    switch (kind) {
      case ResolverKind.udp:
        return defaultPort ? host : address;
      case ResolverKind.doh:
        return 'https://${defaultPort ? _bracketedHost : address}$path';
      case ResolverKind.dot:
        return 'tls://${defaultPort ? _bracketedHost : address}';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ResolverSpec &&
      other.kind == kind &&
      other.host == host &&
      other.port == port &&
      other.path == path;

  @override
  int get hashCode => Object.hash(kind, host, port, path);

  // RFC 3986 path characters: unreserved, sub-delims, ':', '@', '/' and
  // percent-encoded octets.
  static final _pathPattern = RegExp(r"^(?:[A-Za-z0-9\-._~!$&'()*+,;=:@/]|%[0-9A-Fa-f]{2})*$");
  static final _queryPattern = RegExp(r"^(?:[A-Za-z0-9\-._~!$&'()*+,;=:@/?]|%[0-9A-Fa-f]{2})*$");

  /// A spec without a scheme: an address, optionally with a port.
  static ResolverSpec? _parseUdpAddr(String s) {
    var host = s;
    var port = 53;
    if (_parseIP(s) == null) {
      if (s.startsWith('[')) {
        final close = s.indexOf(']');
        if (close < 0) return null;
        host = s.substring(1, close);
        final after = s.substring(close + 1);
        if (after.isEmpty) {
          if (_parseIPv6(host) == null) return null;
        } else {
          if (!after.startsWith(':')) return null;
          final p = _parsePort(after.substring(1));
          if (p == null) return null;
          port = p;
        }
      } else {
        final colon = s.lastIndexOf(':');
        if (colon >= 0) {
          host = s.substring(0, colon);
          // Several colons without brackets: neither an address nor host:port.
          if (host.contains(':')) return null;
          final p = _parsePort(s.substring(colon + 1));
          if (p == null) return null;
          port = p;
        }
      }
    }
    final checked = _checkHost(host);
    if (checked == null) return null;
    return ResolverSpec._(ResolverKind.udp, checked, port);
  }

  static int? _parsePort(String s) {
    if (s.isEmpty || s.length > 5 || !RegExp(r'^[0-9]+$').hasMatch(s)) return null;
    final port = int.parse(s);
    return port >= 1 && port <= 65535 ? port : null;
  }

  /// Checks that [host] is an IP address (without zone) or a host name and
  /// returns it in canonical form.
  static String? _checkHost(String host) {
    if (host.isEmpty) return null;
    if (host.contains(':') || host.contains('%')) {
      final v6 = host.contains('%') ? null : _parseIPv6(host);
      return v6 == null ? null : _formatIPv6Addr(v6);
    }
    final v4 = _parseIPv4(host);
    if (v4 != null) return v4;

    var name = host.toLowerCase();
    if (name.endsWith('.')) name = name.substring(0, name.length - 1);
    if (name.isEmpty || name.length > 253) return null;
    final labels = name.split('.');
    for (final label in labels) {
      if (label.isEmpty ||
          label.length > 63 ||
          label.startsWith('-') ||
          label.endsWith('-') ||
          !RegExp(r'^[a-z0-9-]+$').hasMatch(label)) {
        return null;
      }
    }
    // A numeric top-level label is a mistyped IPv4 address, not a name.
    if (RegExp(r'^[0-9]+$').hasMatch(labels.last)) return null;
    return name;
  }

  /// An IPv4 or IPv6 address in canonical form, or null.
  static String? _parseIP(String s) {
    final v4 = _parseIPv4(s);
    if (v4 != null) return v4;
    if (!s.contains(':') || s.contains('%')) return null;
    final v6 = _parseIPv6(s);
    return v6 == null ? null : _formatIPv6Addr(v6);
  }

  /// Dotted decimal IPv4 without leading zeros, as Go's netip.ParseAddr.
  static String? _parseIPv4(String s) {
    final parts = s.split('.');
    if (parts.length != 4) return null;
    for (final p in parts) {
      if (p.isEmpty || p.length > 3 || !RegExp(r'^[0-9]+$').hasMatch(p)) return null;
      if (p.length > 1 && p.startsWith('0')) return null;
      if (int.parse(p) > 255) return null;
    }
    return s;
  }

  static List<int>? _parseIPv6(String s) {
    // Uri.parseIPv6Address accepts IPv4 parts with leading zeros; the
    // embedded IPv4 part is checked again below.
    final lastColon = s.lastIndexOf(':');
    final tail = s.substring(lastColon + 1);
    if (tail.contains('.') && _parseIPv4(tail) == null) return null;
    try {
      return Uri.parseIPv6Address(s);
    } catch (_) {
      return null;
    }
  }

  static bool _isV4Mapped(List<int> b) {
    for (var i = 0; i < 10; i++) {
      if (b[i] != 0) return false;
    }
    return b[10] == 0xff && b[11] == 0xff;
  }

  /// IPv6 address as netip.Addr.String() prints it: IPv4-mapped addresses
  /// keep the dotted form.
  static String _formatIPv6Addr(List<int> b) {
    if (_isV4Mapped(b)) return '::ffff:${b.sublist(12).join('.')}';
    return _formatIPv6(b);
  }

  /// RFC 5952: lower-case hex, the longest run of two or more zero groups
  /// (the first one on a tie) replaced by "::".
  static String _formatIPv6(List<int> b) {
    final groups = [for (var i = 0; i < 16; i += 2) (b[i] << 8) | b[i + 1]];
    var bestStart = -1, bestLen = 0;
    for (var i = 0; i < 8;) {
      if (groups[i] != 0) {
        i++;
        continue;
      }
      var j = i;
      while (j < 8 && groups[j] == 0) {
        j++;
      }
      if (j - i > bestLen && j - i >= 2) {
        bestStart = i;
        bestLen = j - i;
      }
      i = j;
    }
    String hex(Iterable<int> g) => g.map((x) => x.toRadixString(16)).join(':');
    if (bestStart < 0) return hex(groups);
    return '${hex(groups.sublist(0, bestStart))}::${hex(groups.sublist(bestStart + bestLen))}';
  }
}
