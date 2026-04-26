import 'package:dune_core_flutter/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders validation demo shell', (tester) async {
    await tester.pumpWidget(const DemoApp());
    await tester.pump();

    expect(find.text('Tailscale validation demo'), findsOneWidget);
    expect(find.text('Join as client'), findsOneWidget);
  });

  testWidgets('admin and client credential forms are mutually exclusive', (
    tester,
  ) async {
    await tester.pumpWidget(const DemoApp());
    await tester.pump();

    expect(find.text('Auth key'), findsOneWidget);
    expect(find.text('Control URL'), findsOneWidget);
    expect(find.text('Tailscale API key'), findsNothing);
    expect(find.text('Tailnet ID'), findsNothing);

    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();

    expect(find.text('Auth key'), findsNothing);
    expect(find.text('Control URL'), findsNothing);
    expect(find.text('Tailscale API key'), findsOneWidget);
    expect(find.text('Tailnet ID'), findsOneWidget);
    expect(find.text('Join as admin'), findsOneWidget);
  });
}
