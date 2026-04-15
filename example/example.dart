import 'package:tailscale/tailscale.dart';

void main() async {
  // 1. Configure once at app startup (before any other Tailscale calls).
  Tailscale.init(
    stateDir: '/path/to/persistent/state',
    logLevel: TailscaleLogLevel.info,
  );

  final tsnet = Tailscale.instance;
  tsnet.onStatusChange.listen((status) {
    print('Node state: ${status.nodeStatus}');
  });
  tsnet.onError.listen((error) {
    print('Tailscale runtime error [${error.code.name}]: ${error.message}');
  });

  // 2. Bring the Tailscale node up.
  await tsnet.up(
    hostname: 'my-app',
    authKey: 'tskey-auth-...',
    controlUrl: Uri.parse('https://controlplane.tailscale.com'),
  );

  // Your app is now a node on the tailnet
  final status = await tsnet.status();
  print('Local IP: ${status.ipv4}');
  final peers = await tsnet.peers();
  print('Known peers: ${peers.length}');

  // 3. Make requests to peers using the built-in HTTP client.
  //    It transparently routes through the Tailscale tunnel.
  final peer = peers.firstWhere((peer) => peer.online);
  final response = await tsnet.http.get(
    Uri.parse('http://${peer.ipv4}/api/data'),
  );
  print('Response: ${response.body}');

  // Expose a local HTTP server to the tailnet
  await tsnet.listen(8080);

  // Clean shutdown
  await tsnet.down();
}
