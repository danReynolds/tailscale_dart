/// Coverage for the `profiles` namespace. All operations are stubs in
/// Phase 2; this file currently covers the [LoginProfile] value-type
/// equality contract.
library;

import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';

void main() {
  group('LoginProfile', () {
    test('==', () {
      const a = LoginProfile(
        id: 'p1',
        userLoginName: 'alice',
        tailnetName: 'example.com',
      );
      const b = LoginProfile(
        id: 'p1',
        userLoginName: 'alice',
        tailnetName: 'example.com',
      );
      const different = LoginProfile(
        id: 'p2',
        userLoginName: 'alice',
        tailnetName: 'example.com',
      );

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(different)));
    });
  });
}
