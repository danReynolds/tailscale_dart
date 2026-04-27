# demo_core

Shared validation logic for the Tailscale Dart demo surfaces.

This package owns the reusable behavior that should work from a Flutter app,
future CLI, or future daemon-style runner:

- bring a `Tailscale` node up with a supplied state directory
- generate short-lived auth keys from a Tailscale admin API key
- join as an admin by generating a local node auth key internally
- expose HTTP, TCP echo, and UDP echo services on the tailnet
- list nodes and run node probes for ping, whois, HTTP, TCP, and UDP

It intentionally contains no Flutter UI.

## Headless demo node

`bin/demo_node.dart` is a thin CLI around `DemoCore` for fast local validation
without rebuilding Flutter apps.

Run one serving node:

```sh
dart run --enable-experiment=native-assets bin/demo_node.dart serve \
  --state-dir /tmp/dune-a \
  --hostname demo-a \
  --auth-key "$AUTH_KEY" \
  --control-url "$CONTROL_URL"
```

Run a probe node:

```sh
dart run --enable-experiment=native-assets bin/demo_node.dart probe \
  --state-dir /tmp/dune-b \
  --hostname demo-b \
  --auth-key "$AUTH_KEY" \
  --control-url "$CONTROL_URL" \
  --node 100.x.y.z
```

Run a two-process local loop:

```sh
dart run --enable-experiment=native-assets bin/demo_node.dart pair \
  --auth-key "$AUTH_KEY" \
  --control-url "$CONTROL_URL"
```

`pair` requires a reusable auth key because it joins two independent local
processes. It is the fastest loop for debugging demo service/probe behavior
before retesting Flutter on devices.
