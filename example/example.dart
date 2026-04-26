import 'package:tailscale/tailscale.dart';

void main() async {
  // 1. Configure once at app startup (before any other Tailscale calls).
  Tailscale.init(
    stateDir: '/path/to/persistent/state',
    logLevel: TailscaleLogLevel.info,
  );

  final tsnet = Tailscale.instance;
  tsnet.onStateChange.listen((state) {
    print('Node state: $state');
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
  final nodes = await tsnet.nodes();
  print('Known nodes: ${nodes.length}');

  // 3. Make requests to nodes using the built-in HTTP client.
  //    It transparently routes through the Tailscale tunnel.
  final node = nodes.firstWhere((node) => node.online);
  final response = await tsnet.http.client.get(
    Uri.parse('http://${node.ipv4}/api/data'),
  );
  print('Response: ${response.body}');

  // Accept incoming tailnet HTTP requests directly.
  final server = await tsnet.http.bind(port: 80);
  server.requests.listen((request) async {
    await request.respond(body: 'hello from ${status.ipv4}');
  });
  print('HTTP bound on ${server.tailnet.address}:${server.tailnet.port}');

  // Clean shutdown
  await server.close();
  await tsnet.down();
}
