import 'package:tailscale/tailscale.dart';

void main() async {
  // 1. Configure once at app startup (before any other Tailscale calls).
  Tailscale.init(
    stateDir: '/path/to/persistent/state',
    logLevel: TailscaleLogLevel.info,
  );

  final tsnet = Tailscale.instance;
  tsnet.statusChanges.listen((status) {
    print('Node state: ${status.nodeStatus}');
  });
  tsnet.runtimeErrors.listen((error) {
    print('Tailscale runtime error [${error.code.name}]: ${error.message}');
  });

  // 2. Bring the Tailscale node up.
  final status = await tsnet.up(
    hostname: 'my-app',
    authKey: 'tskey-auth-...',
    controlUrl: Uri.parse('https://controlplane.tailscale.com'),
  );

  // Your app is now a node on the tailnet
  print('Local IP: ${status.ipv4}');
  final peers = await tsnet.peers();
  print('Known peers: ${peers.length}');

  // 3. Make requests to peers using the built-in HTTP client.
  //    It transparently routes through the Tailscale tunnel.
  final peer = peers.firstWhere((peer) => peer.online);
  final response = await tsnet.httpClient.get(
    Uri.parse('http://${peer.ipv4}/api/data'),
  );
  print('Response: ${response.body}');

  // Expose a local HTTP server to the tailnet
  await tsnet.listen(localPort: 8080);

  // Check status
  print('Running: ${status.isRunning}, healthy: ${status.isHealthy}');

  // Clean shutdown
  await tsnet.down();
}
