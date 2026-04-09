import 'package:tailscale/tailscale.dart';

void main() async {
  final tsnet = DuneTsnet.instance;

  // Optional: enable verbose logging for debugging
  DuneTsnet.setLogLevel(2);

  // Connect to a Tailscale (or Headscale) network
  await tsnet.init(
    clientId: 'my-app',
    authKey: 'tskey-auth-...',
    controlUrl: 'https://controlplane.tailscale.com',
    stateDir: '/path/to/persistent/state',
  );

  // Your app is now a node on the tailnet
  print('Local IP: ${await tsnet.getLocalIP()}');
  print('Online peers: ${await tsnet.getPeerAddresses()}');

  // Reach a peer via the built-in HTTP proxy
  final uri = tsnet.getProxyUri('100.64.0.5', '/api/data');
  print('Proxy URI: $uri');

  // Accept incoming traffic from the tailnet
  await tsnet.startReverseProxy(8080);

  // React to status changes
  tsnet.statusStream.listen((status) {
    print('State: ${status.backendState}, peers: ${status.onlinePeers.length}');
  });

  // Get typed status
  final status = await tsnet.getTypedStatus();
  print('Running: ${status.isRunning}, healthy: ${status.isHealthy}');

  // Clean shutdown
  await tsnet.stop();
}
