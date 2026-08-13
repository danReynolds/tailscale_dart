import 'dart:convert';

import 'package:dune_smoke_flutter/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows smoke probe shell without auto-starting', (tester) async {
    await tester.pumpWidget(const SmokeApp(autoStart: false));

    expect(find.text('[SMOKE] Dune Flutter Probe'), findsOneWidget);
    expect(find.text('READY'), findsOneWidget);
    expect(find.text('Run Smoke Probe'), findsOneWidget);
  });

  test('failure stdout receipt stays compact and parseable', () {
    final startedAt = DateTime.utc(2026, 8, 13);
    final result = SmokeResult(
      ok: false,
      startedAt: startedAt,
      finishedAt: startedAt.add(const Duration(milliseconds: 12)),
      hostname: 'dune-smoke-ios',
      platform: 'ios',
      localIp: null,
      targetIp: '',
      services: null,
      nodesSeen: 0,
      report: null,
      events: const [],
      error: 'runner connection failed',
      stackTrace: 'stack\n' * 500,
    );

    final encoded = jsonEncode(result.toStdoutJson());
    final decoded = jsonDecode(encoded) as Map<String, Object?>;
    expect(encoded.length, lessThan(1000));
    expect(decoded['ok'], isFalse);
    expect(decoded['error'], 'runner connection failed');
    expect(decoded, isNot(contains('stackTrace')));
  });
}
