/// Coverage for the `diag` namespace. All operations are stubs in
/// Phase 2; this file covers the value-type equality contracts for
/// [PingResult], [DERPMap], [DERPRegion], [DERPNode], and
/// [ClientVersion].
library;

import 'package:test/test.dart';
import 'package:tailscale/tailscale.dart';

void main() {
  group('PingResult', () {
    test('==', () {
      const a = PingResult(latency: Duration(milliseconds: 10), direct: true);
      const b = PingResult(latency: Duration(milliseconds: 10), direct: true);
      const relayed = PingResult(
        latency: Duration(milliseconds: 10),
        direct: false,
        derpRegion: 'nyc',
      );

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(relayed)));
    });
  });

  group('DERPNode', () {
    test('==', () {
      const a = DERPNode(name: 'nyc-1', hostName: 'derp1.example');
      const b = DERPNode(name: 'nyc-1', hostName: 'derp1.example');
      const different = DERPNode(name: 'nyc-2', hostName: 'derp2.example');

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(different)));
    });
  });

  group('DERPRegion', () {
    test('==', () {
      const node = DERPNode(name: 'nyc-1', hostName: 'derp1.example');
      const a = DERPRegion(
        regionId: 1,
        regionCode: 'nyc',
        regionName: 'New York',
        nodes: [node],
      );
      const b = DERPRegion(
        regionId: 1,
        regionCode: 'nyc',
        regionName: 'New York',
        nodes: [node],
      );
      const different = DERPRegion(
        regionId: 2,
        regionCode: 'sfo',
        regionName: 'San Francisco',
        nodes: [],
      );

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(different)));
    });
  });

  group('DERPMap', () {
    test('==', () {
      const region = DERPRegion(
        regionId: 1,
        regionCode: 'nyc',
        regionName: 'New York',
        nodes: [],
      );
      const a = DERPMap(regions: {1: region}, omitDefaultRegions: false);
      const b = DERPMap(regions: {1: region}, omitDefaultRegions: false);
      const omit = DERPMap(regions: {1: region}, omitDefaultRegions: true);

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(omit)));
    });
  });

  group('ClientVersion', () {
    test('==', () {
      const a = ClientVersion(shortVersion: '1.92.3', longVersion: '1.92.3-abc');
      const b = ClientVersion(shortVersion: '1.92.3', longVersion: '1.92.3-abc');
      const different = ClientVersion(
        shortVersion: '1.92.4',
        longVersion: '1.92.4-def',
      );

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(different)));
    });
  });
}
