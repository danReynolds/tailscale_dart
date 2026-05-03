const examples = {
  quickstart: {
    title: "quick_start.dart",
    code: `import 'package:tailscale/tailscale.dart';

Tailscale.init(stateDir: '/app/tailscale');
final ts = Tailscale.instance;

await ts.up(authKey: 'tskey-auth-...');

final status = await ts.status();
print(status.stableNodeId);

final onlineNodes = await ts.nodes();
for (final node in onlineNodes.where((node) => node.online)) {
  print('\${node.hostName}: \${node.ipv4}');
}`,
  },
  httpBind: {
    title: "http_bind.dart",
    code: `final server = await ts.http.bind(port: 8080);

server.requests.listen((request) async {
  final identity = await ts.whois(request.remote.address);

  if (identity?.tags.contains('tag:internal') != true) {
    await request.respond(
      statusCode: 403,
      headers: {'content-type': 'text/plain'},
      body: 'forbidden',
    );
    return;
  }

  await request.respond(
    headers: {'content-type': 'application/json'},
    body: '{"ok":true}',
  );
});`,
  },
  tcp: {
    title: "tcp_echo.dart",
    code: `final listener = await ts.tcp.bind(port: 7000);

listener.connections.listen((conn) async {
  final identity = await ts.whois(conn.remote.address);
  if (identity?.tags.contains('tag:trusted') != true) {
    await conn.abort();
    return;
  }

  await conn.output.writeAll(conn.input, close: true);
});`,
  },
  udp: {
    title: "udp_echo.dart",
    code: `final socket = await ts.udp.bind(port: 5353);

socket.datagrams.listen((datagram) async {
  print('from \${datagram.remote}: '
      '\${datagram.payload.length} bytes');

  await socket.send(
    datagram.payload,
    to: datagram.remote,
  );
});`,
  },
  tls: {
    title: "tls_listener.dart",
    code: `final listener = await ts.tls.bind(port: 443);
final domains = await ts.tls.domains();

print('serving \${domains.first}');

listener.connections.listen((conn) async {
  await conn.output.writeAll([
    72, 84, 84, 80, 47, 49, 46, 49, 32, 50, 48, 48, 32,
    79, 75, 13, 10, 13, 10,
  ], close: false);
  await conn.close();
});`,
  },
  funnel: {
    title: "serve_funnel.dart",
    code: `// Reuse an existing loopback Shelf or dart:io server.
final serve = await ts.serve.forward(
  tailnetPort: 443,
  localPort: 8080,
  path: '/admin',
);

final funnel = await ts.funnel.forward(
  publicPort: 443,
  localPort: 8080,
  path: '/demo',
);

print(serve.url);
print(funnel.url);

await funnel.close();
await serve.close();`,
  },
  prefs: {
    title: "routing_controls.dart",
    code: `await ts.prefs.updateMasked(
  PrefsUpdate(
    acceptRoutes: true,
    shieldsUp: false,
    advertisedRoutes: ['10.10.0.0/24'],
  ),
);

final suggestion = await ts.exitNode.suggest();
if (suggestion != null) {
  await ts.exitNode.use(suggestion);
}

print(await ts.exitNode.current());`,
  },
};

const codeEl = document.querySelector("#example-code");
const titleEl = document.querySelector("#example-title");
const copyButton = document.querySelector(".copy-button");
const panel = document.querySelector("#example-panel");
const tabs = [...document.querySelectorAll(".tab")];

function setExample(name) {
  const example = examples[name];
  codeEl.textContent = example.code;
  titleEl.textContent = example.title;
  tabs.forEach((tab) => {
    const active = tab.dataset.example === name;
    tab.classList.toggle("active", active);
    tab.setAttribute("aria-selected", String(active));
    tab.tabIndex = active ? 0 : -1;
    if (active) {
      panel.setAttribute("aria-labelledby", tab.id);
    }
  });
}

tabs.forEach((tab) => {
  tab.addEventListener("click", () => setExample(tab.dataset.example));
  tab.addEventListener("keydown", (event) => {
    const current = tabs.indexOf(tab);
    const next = {
      ArrowDown: (current + 1) % tabs.length,
      ArrowRight: (current + 1) % tabs.length,
      ArrowUp: (current - 1 + tabs.length) % tabs.length,
      ArrowLeft: (current - 1 + tabs.length) % tabs.length,
      Home: 0,
      End: tabs.length - 1,
    }[event.key];

    if (next === undefined) return;
    event.preventDefault();
    tabs[next].focus();
    setExample(tabs[next].dataset.example);
  });
});

copyButton.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(codeEl.textContent);
    copyButton.textContent = "copied";
    setTimeout(() => {
      copyButton.textContent = "copy";
    }, 1200);
  } catch (_) {
    copyButton.textContent = "select";
  }
});

setExample("quickstart");
