/// Coverage for the `taildrop` namespace. All operations are stubs in
/// Phase 2; this file currently covers the [FileTarget] / [WaitingFile]
/// value-type equality contract and will fill in as later phases wire
/// up the actual transfer surface.
library;

import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';

void main() {
  group('FileTarget', () {
    test('==', () {
      const a = FileTarget(
        nodeId: 'n1',
        hostname: 'peer',
        userLoginName: 'alice',
      );
      const b = FileTarget(
        nodeId: 'n1',
        hostname: 'peer',
        userLoginName: 'alice',
      );
      const different = FileTarget(
        nodeId: 'n2',
        hostname: 'peer',
        userLoginName: 'alice',
      );

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(different)));
    });
  });

  group('WaitingFile', () {
    test('==', () {
      const a = WaitingFile(name: 'notes.txt', size: 42);
      const b = WaitingFile(name: 'notes.txt', size: 42);
      const different = WaitingFile(name: 'notes.txt', size: 43);

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(different)));
    });
  });
}
