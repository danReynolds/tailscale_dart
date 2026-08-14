import 'dart:io';

import 'package:dune_core_flutter/main.dart';
import 'package:dune_core_flutter/src/backup_policy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('Apple state preparation verifies backup exclusion', () async {
    const channel = MethodChannel('dev.tailscale.dart.demo/backup-policy');
    String? receivedPath;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'excludeFromBackup');
          receivedPath = call.arguments as String;
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final root = Directory.systemTemp.createTempSync('tailscale_demo_backup_');
    root.deleteSync();
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await preparePersistentStateDirectory(root.path, operatingSystem: 'ios');

    expect(root.existsSync(), isTrue);
    expect(receivedPath, root.path);
  });

  test('Apple state preparation fails closed without readback', () async {
    const channel = MethodChannel('dev.tailscale.dart.demo/backup-policy');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final root = Directory.systemTemp.createTempSync('tailscale_demo_backup_');
    root.deleteSync();
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await expectLater(
      preparePersistentStateDirectory(root.path, operatingSystem: 'macos'),
      throwsStateError,
    );
  });

  test('Android excludes runtime and Keybay state from every backup path', () {
    const statePath = 'tailscale_demo/';
    const keybayPath = '$demoTailscaleAppId.tailscale/';
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final legacyRules = File(
      'android/app/src/main/res/xml/backup_rules.xml',
    ).readAsStringSync();
    final modernRules = File(
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    ).readAsStringSync();

    expect(manifest, contains('android:allowBackup="false"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
    expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));
    for (final path in [statePath, keybayPath]) {
      final exclusion = '<exclude domain="file" path="$path" />';
      expect(legacyRules, contains(exclusion));
      for (final section in ['cloud-backup', 'device-transfer']) {
        final sectionBody = RegExp(
          '<$section>([\\s\\S]*?)</$section>',
        ).firstMatch(modernRules)?.group(1);
        expect(
          sectionBody,
          contains(exclusion),
          reason: '$section must exclude $path',
        );
      }
    }
  });
}
