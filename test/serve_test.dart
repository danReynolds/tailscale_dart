/// Coverage for the `serve` namespace. [Serve.getConfig] /
/// [Serve.setConfig] are stubs in Phase 2; this file covers the
/// [ServeConfig] value-type equality contract and the `etag` field
/// added for optimistic concurrency.
library;

import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';

void main() {
  group('ServeConfig', () {
    test('==', () {
      const a = ServeConfig(etag: 'v1');
      const b = ServeConfig(etag: 'v1');
      const different = ServeConfig(etag: 'v2');

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(different)));
    });

    test('empty constant has no etag', () {
      expect(ServeConfig.empty.etag, isNull);
    });
  });
}
