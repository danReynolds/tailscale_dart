import 'package:dune_smoke_flutter/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows smoke probe shell without auto-starting', (tester) async {
    await tester.pumpWidget(const SmokeApp(autoStart: false));

    expect(find.text('[SMOKE] Dune Flutter Probe'), findsOneWidget);
    expect(find.text('READY'), findsOneWidget);
    expect(find.text('Run Smoke Probe'), findsOneWidget);
  });
}
