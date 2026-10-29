import 'package:uuid/uuid.dart';
import 'resolver_spec.dart';

class DnsServer {
  final String id;

  /// Resolver spec (see [ResolverSpec]): an IP address for plain UDP, or a
  /// `https://` (DoH) or `tls://` (DoT) URL.
  final String address;

  /// IP address to connect to instead of resolving the host name of a DoH or
  /// DoT resolver (avoids a plain DNS lookup); null to resolve it.
  final String? bootstrap;
  final String? name;
  final String? region;
  final String? provider;
  bool isWorking;
  DateTime? lastTested;
  int? lastLatencyMs;
  String? lastTestMessage;

  DnsServer({
    String? id,
    required this.address,
    this.bootstrap,
    this.name,
    this.region,
    this.provider,
    this.isWorking = false,
    this.lastTested,
    this.lastLatencyMs,
    this.lastTestMessage,
  }) : id = id ?? const Uuid().v4();

  /// Transport of the resolver; entries that do not parse count as UDP, as
  /// they did before resolver specs.
  ResolverKind get kind => ResolverSpec.kindOf(address) ?? ResolverKind.udp;

  bool get isEncrypted => kind != ResolverKind.udp;

  Map<String, dynamic> toJson() => {
        'id': id,
        'address': address,
        if (bootstrap != null) 'bootstrap': bootstrap,
        'name': name,
        'region': region,
        'provider': provider,
        'isWorking': isWorking,
        'lastTested': lastTested?.toIso8601String(),
        'lastLatencyMs': lastLatencyMs,
        'lastTestMessage': lastTestMessage,
      };

  factory DnsServer.fromJson(Map<String, dynamic> json) => DnsServer(
        id: json['id'],
        address: json['address'],
        bootstrap: json['bootstrap'],
        name: json['name'],
        region: json['region'],
        provider: json['provider'],
        isWorking: json['isWorking'] ?? false,
        lastTested: json['lastTested'] != null
            ? DateTime.parse(json['lastTested'])
            : null,
        lastLatencyMs: json['lastLatencyMs'],
        lastTestMessage: json['lastTestMessage'],
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DnsServer &&
          runtimeType == other.runtimeType &&
          address == other.address;

  @override
  int get hashCode => address.hashCode;
}
