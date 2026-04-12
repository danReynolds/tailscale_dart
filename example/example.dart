import 'package:tailscale/tailscale.dart';

void main() async {
  // 1. Configure once at app startup (before any other Tailscale calls).
  Tailscale.init(
    stateDir: '/path/to/persistent/state',
    logLevel: 2, // 0 = silent, 1 = errors, 2 = verbose
  );

  final tsnet = Tailscale.instance;

  // 2. Start the Tailscale node.
  await tsnet.start(
    nodeName: 'my-app',
    authKey: 'tskey-auth-...',
    controlUrl: 'https://controlplane.tailscale.com',
  );

  // Your app is now a node on the tailnet
  final status = await tsnet.status();
  print('Local IP: ${status.ipv4}');
  print('Online peers: ${status.onlinePeers.length}');

  // 3. Make requests to peers using the built-in HTTP client.
  //    It transparently routes through the Tailscale tunnel.
  final response = await tsnet.http.get(
    Uri.parse('http://100.64.0.5/api/data'),
  );
  print('Response: ${response.body}');

  // The raw proxy port is also available for advanced use cases:
  print('Proxy port: ${tsnet.proxyPort}');

  // Accept incoming traffic from the tailnet
  await tsnet.listen(port: 8080);

  // Check if we can reconnect on next launch
  final provisioned = await tsnet.isProvisioned();
  print('Has stored credentials: $provisioned');

  // Check status
  print('Running: ${status.isRunning}, healthy: ${status.isHealthy}');

  // Clean shutdown
  await tsnet.close();
}
