import 'package:test/test.dart';

import '../live_tailscale/support/tailscale_api.dart';

void main() {
  test('device matching requires the requested hostname and IPv4', () {
    const device = LiveTailscaleDevice(
      id: 'device-id',
      name: 'receipt-node.example.ts.net',
      hostname: 'receipt-node',
      addresses: ['100.64.0.1', 'fd7a:115c:a1e0::1'],
    );

    expect(device.matches(hostname: 'receipt-node'), isTrue);
    expect(
      device.matches(hostname: 'receipt-node', ipv4: '100.64.0.1'),
      isTrue,
    );
    expect(
      device.matches(hostname: 'receipt-node', ipv4: '100.64.0.2'),
      isFalse,
    );
    expect(
      device.matches(hostname: 'different-node', ipv4: '100.64.0.1'),
      isFalse,
    );
  });
}
