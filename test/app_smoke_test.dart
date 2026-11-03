// Smoke test of the app's start screen.
//
// There is one widget test in this file on purpose: VpnService is a
// process-wide singleton with a one-shot init flag (lib/services/vpn_service.dart),
// so a second test would not start from a fresh state.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dnstt_xyz_app/main.dart';
import 'package:dnstt_xyz_app/providers/app_state.dart';

void main() {
  testWidgets('start screen shows the empty state', (WidgetTester tester) async {
    // AppState keeps its start-screen fields in their declarations and its
    // getters do not read storage, so init() and SharedPreferences are not
    // needed here.
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const DnsttClientApp(),
      ),
    );

    // App bar title.
    expect(find.text('DNSTT.XYZ'), findsOneWidget);

    // Empty state: no config, no DNS server, nothing selected.
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('No config selected'), findsOneWidget);
    expect(find.text('No DNS selected'), findsOneWidget);
    expect(
      find.text('Select a config and DNS server to connect'),
      findsOneWidget,
    );

    // Menu cards.
    expect(find.text('Configs'), findsOneWidget);
    expect(find.text('DNS Servers'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    // The power button of the connection card.
    expect(find.byIcon(Icons.power_settings_new), findsOneWidget);

    // Without a config and a DNS server the tap does nothing.
    await tester.tap(find.byIcon(Icons.power_settings_new));
    await tester.pump();
    expect(find.text('Disconnected'), findsOneWidget);
  });
}
