import 'dart:async';
import 'dart:io';

import 'package:demo_core/demo_core.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _voidBlack = Color(0xff020706);
const _terminal = Color(0xff061815);
const _panel = Color(0xe6091815);
const _matrix = Color(0xff28ffb2);
const _cyan = Color(0xff2de2ff);
const _amber = Color(0xffffc857);
const _danger = Color(0xffff4d6d);
const _muted = Color(0xff7aa99b);

const _defaultDemoHostname = String.fromEnvironment('DUNE_DEMO_HOSTNAME');
const _defaultDemoAuthKey = String.fromEnvironment('DUNE_DEMO_AUTH_KEY');
const _defaultDemoControlUrl = String.fromEnvironment('DUNE_DEMO_CONTROL_URL');
const _defaultDemoNodeIp = String.fromEnvironment('DUNE_DEMO_NODE_IP');

void main() {
  runApp(const DemoApp());
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(4),
      borderSide: BorderSide(color: _matrix.withValues(alpha: 0.24)),
    );
    return MaterialApp(
      title: 'Tailscale Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: _matrix,
          secondary: _cyan,
          tertiary: _amber,
          surface: _terminal,
          error: _danger,
        ),
        useMaterial3: true,
        fontFamily: 'monospace',
        textTheme: const TextTheme(
          headlineMedium: TextStyle(
            color: _matrix,
            fontSize: 28,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.8,
          ),
          titleLarge: TextStyle(
            color: _matrix,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
          ),
          titleMedium: TextStyle(
            color: _cyan,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7,
          ),
          bodyMedium: TextStyle(color: Color(0xffd8fff2), height: 1.35),
          bodySmall: TextStyle(color: _muted, height: 1.35),
        ),
        scaffoldBackgroundColor: _voidBlack,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _voidBlack.withValues(alpha: 0.56),
          labelStyle: const TextStyle(color: _cyan),
          hintStyle: TextStyle(color: _muted.withValues(alpha: 0.72)),
          enabledBorder: border,
          focusedBorder: border.copyWith(
            borderSide: const BorderSide(color: _matrix, width: 1.4),
          ),
          disabledBorder: border.copyWith(
            borderSide: BorderSide(color: _muted.withValues(alpha: 0.14)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: _matrix,
            foregroundColor: _voidBlack,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: _cyan,
            side: BorderSide(color: _cyan.withValues(alpha: 0.54)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? _matrix.withValues(alpha: 0.18)
                  : _voidBlack.withValues(alpha: 0.45),
            ),
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) =>
                  states.contains(WidgetState.selected) ? _matrix : _muted,
            ),
            side: WidgetStatePropertyAll(
              BorderSide(color: _matrix.withValues(alpha: 0.36)),
            ),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            ),
          ),
        ),
      ),
      home: const DemoHomePage(),
    );
  }
}

class DemoHomePage extends StatefulWidget {
  const DemoHomePage({super.key});

  @override
  State<DemoHomePage> createState() => _DemoHomePageState();
}

enum _DemoRole { client, admin }

class _DemoHomePageState extends State<DemoHomePage> {
  final _demo = DemoCore();
  final _hostname = TextEditingController(
    text: _defaultDemoHostname.isEmpty
        ? 'demo-${Platform.operatingSystem}'
        : _defaultDemoHostname,
  );
  final _authKey = TextEditingController(text: _defaultDemoAuthKey);
  final _adminApiKey = TextEditingController();
  final _tailnetId = TextEditingController(text: '-');
  final _controlUrl = TextEditingController(text: _defaultDemoControlUrl);
  final _nodeIp = TextEditingController(text: _defaultDemoNodeIp);
  final _logs = <String>[];

  final _subscriptions = <StreamSubscription<Object?>>[];

  String? _stateDir;
  String? _activeOperation;
  bool _busy = false;
  bool _showOnlyOnlineNodes = true;
  bool _startingServices = false;
  Future<bool>? _servicesStart;
  _DemoRole _role = _DemoRole.client;
  TailscaleStatus? _status;
  DemoServices? _services;
  List<TailscaleNode> _nodes = const [];
  DemoProbeReport? _lastReport;
  DemoGeneratedAuthKey? _issuedAuthKey;

  @override
  void initState() {
    super.initState();
    _subscriptions
      ..add(
        _demo.onStateChange.listen((state) {
          _log('state: ${state.name}');
          unawaited(_refreshStatus());
          if (state == NodeState.running) {
            unawaited(_autoStartServices());
          }
        }),
      )
      ..add(
        _demo.onError.listen((error) {
          _log('runtime error: ${error.message}');
        }),
      )
      ..add(
        _demo.onNodeChanges.listen((nodes) {
          setState(() => _nodes = nodes);
        }),
      );
    unawaited(_loadStateDir());
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _hostname.dispose();
    _authKey.dispose();
    _adminApiKey.dispose();
    _tailnetId.dispose();
    _controlUrl.dispose();
    _nodeIp.dispose();
    super.dispose();
  }

  Future<void> _loadStateDir() async {
    String path;
    try {
      final docs = await getApplicationDocumentsDirectory();
      path = p.join(docs.path, 'tailscale_demo');
    } catch (_) {
      path = p.join(Directory.systemTemp.path, 'tailscale_demo');
    }
    if (!mounted) return;
    setState(() {
      _stateDir = path;
    });
  }

  Future<void> _connectWithAuthKey({
    required String label,
    required String authKey,
    Uri? controlUrl,
  }) => _run(label, () async {
    final stateDir = _stateDir;
    if (stateDir == null) throw StateError('state directory not ready');
    if (mounted) {
      setState(() => _services = null);
    }
    final status = await _demo.up(
      stateDir: stateDir,
      hostname: _hostname.text.trim(),
      authKey: authKey,
      controlUrl: controlUrl,
    );
    if (mounted) {
      setState(() => _status = status);
    }
    if (status.isRunning) {
      await _startServicesGuarded(requireRunning: false);
    }
    final nodes = await _demo.nodes();
    if (!mounted) return;
    setState(() => _nodes = nodes);
  });

  Future<void> _connectClient() {
    final authKey = _authKey.text.trim();
    if (authKey.isEmpty) {
      return _run('join as client', () {
        throw StateError('auth key is required for Client mode');
      });
    }
    final control = _controlUrl.text.trim();
    return _connectWithAuthKey(
      label: 'join as client',
      authKey: authKey,
      controlUrl: control.isEmpty ? null : Uri.parse(control),
    );
  }

  Future<void> _connectAdmin() => _run('join as admin', () async {
    final stateDir = _stateDir;
    if (stateDir == null) throw StateError('state directory not ready');
    setState(() => _services = null);
    final status = await _demo.upAsAdmin(
      stateDir: stateDir,
      hostname: _hostname.text.trim(),
      apiKey: _adminApiKey.text.trim(),
      tailnetId: _tailnetId.text.trim(),
    );
    if (mounted) {
      setState(() => _status = status);
    }
    if (status.isRunning) {
      await _startServicesGuarded(requireRunning: false);
    }
    final nodes = await _demo.nodes();
    if (!mounted) return;
    setState(() => _nodes = nodes);
  });

  Future<void> _refreshStatus() async {
    try {
      final status = await _demo.status();
      if (!mounted) return;
      setState(() => _status = status);
    } catch (_) {
      // Before init/up, status is not meaningful for the demo UI.
    }
  }

  Future<void> _refreshNodes() => _run('refresh nodes', () async {
    final nodes = await _demo.nodes();
    setState(() => _nodes = nodes);
  });

  Future<void> _startServices() => _run('start services', () async {
    await _startServicesGuarded(requireRunning: true);
  });

  Future<void> _autoStartServices() async {
    if (_servicesStart != null || _services != null) return;
    _log('> auto start services');
    final previousOperation = _activeOperation;
    if (previousOperation == null && mounted) {
      setState(() => _activeOperation = 'auto start services');
    }
    try {
      final started = await _startServicesGuarded(requireRunning: false);
      if (started) {
        _log('ok: auto start services');
      } else {
        _log('skip: auto start services; node is not running');
      }
    } catch (error) {
      _log('! auto start services :: $error');
    } finally {
      if (previousOperation == null && mounted) {
        setState(() => _activeOperation = null);
      }
    }
  }

  Future<bool> _startServicesGuarded({required bool requireRunning}) {
    final existing = _servicesStart;
    if (existing != null) return existing;

    _startingServices = true;
    if (mounted) setState(() {});

    final future = _startServicesInternal(requireRunning: requireRunning);
    _servicesStart = future;
    return future.whenComplete(() {
      _servicesStart = null;
      _startingServices = false;
      if (mounted) setState(() {});
    });
  }

  Future<bool> _startServicesInternal({required bool requireRunning}) async {
    final status = await _demo.status();
    if (!status.isRunning) {
      if (mounted) setState(() => _status = status);
      if (requireRunning) {
        throw StateError('node is not running yet');
      }
      return false;
    }
    final services = await _demo.startServices();
    final nodes = await _demo.nodes();
    if (!mounted) return true;
    setState(() {
      _status = status;
      _services = services;
      _nodes = nodes;
    });
    return true;
  }

  Future<void> _stopServices() => _run('stop services', () async {
    await _demo.stopServices();
    setState(() => _services = null);
  });

  Future<void> _down() => _run('down', () async {
    await _demo.down();
    setState(() {
      _status = null;
      _services = null;
      _nodes = const [];
      _lastReport = null;
    });
  });

  Future<void> _probe(String nodeIp) => _run('probe $nodeIp', () async {
    final report = await _demo.probeNode(nodeIp);
    setState(() => _lastReport = report);
  });

  Future<void> _issueClientAuthKey() => _run('issue client auth key', () async {
    final generated = await _demo.generateAuthKey(
      apiKey: _adminApiKey.text.trim(),
      tailnetId: _tailnetId.text.trim(),
    );
    setState(() {
      _issuedAuthKey = generated;
    });
    _log('issued client auth key ${generated.id ?? '(no id)'}');
  });

  Future<void> _run(String label, Future<void> Function() action) async {
    if (_busy || _startingServices) return;
    setState(() {
      _busy = true;
      _activeOperation = label;
    });
    _log('> $label');
    try {
      await action();
      _log('ok: $label');
    } catch (error) {
      _log('! $label :: $error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _activeOperation = null;
        });
      }
    }
  }

  void _log(String message) {
    final stamped = '${DateTime.now().toIso8601String()}  $message';
    if (!mounted) {
      _logs.add(stamped);
      return;
    }
    setState(() {
      _logs.insert(0, stamped);
      if (_logs.length > 200) _logs.removeLast();
    });
  }

  @override
  Widget build(BuildContext context) {
    final busy = _busy || _startingServices;
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: _CyberBackground()),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
              children: [
                _HeroHeader(
                  status: _status,
                  busy: busy,
                  operation: _activeOperation,
                  onRefresh: _refreshNodes,
                ),
                const SizedBox(height: 18),
                _section(
                  index: '01',
                  title: 'Node Access',
                  child: Column(
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SegmentedButton<_DemoRole>(
                          segments: const [
                            ButtonSegment(
                              value: _DemoRole.client,
                              label: Text('Client'),
                              icon: Icon(Icons.phone_iphone),
                            ),
                            ButtonSegment(
                              value: _DemoRole.admin,
                              label: Text('Admin'),
                              icon: Icon(Icons.admin_panel_settings),
                            ),
                          ],
                          selected: {_role},
                          onSelectionChanged: busy
                              ? null
                              : (selection) {
                                  setState(() => _role = selection.single);
                                },
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _hostname,
                        decoration: const InputDecoration(
                          labelText: 'Hostname',
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (_role == _DemoRole.client)
                        _ClientJoinView(
                          authKey: _authKey,
                          controlUrl: _controlUrl,
                          busy: busy,
                          onConnect: _connectClient,
                          onStartServices: _startServices,
                          onStopServices: _stopServices,
                          onDown: _down,
                        )
                      else
                        _AdminJoinView(
                          apiKey: _adminApiKey,
                          tailnetId: _tailnetId,
                          busy: busy,
                          onConnect: _connectAdmin,
                          onStartServices: _startServices,
                          onStopServices: _stopServices,
                          onDown: _down,
                        ),
                    ],
                  ),
                ),
                if (_role == _DemoRole.admin) ...[
                  const SizedBox(height: 16),
                  _section(
                    index: '02',
                    title: 'Client Invite',
                    child: _ClientInviteView(
                      generated: _issuedAuthKey,
                      busy: busy,
                      connected: _status?.isRunning ?? false,
                      onIssue: _issueClientAuthKey,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                _section(
                  index: _role == _DemoRole.admin ? '03' : '02',
                  title: 'Runtime Telemetry',
                  child: _StatusView(
                    status: _status,
                    services: _services,
                    stateDir: _stateDir,
                  ),
                ),
                const SizedBox(height: 16),
                _section(
                  index: _role == _DemoRole.admin ? '04' : '03',
                  title: 'Node Matrix',
                  child: _NodesView(
                    nodes: _nodes,
                    showOnlyOnline: _showOnlyOnlineNodes,
                    nodeIp: _nodeIp,
                    busy: busy,
                    onToggleOnlineOnly: (value) {
                      setState(() => _showOnlyOnlineNodes = value);
                    },
                    onProbe: _probe,
                  ),
                ),
                const SizedBox(height: 16),
                _section(
                  index: _role == _DemoRole.admin ? '05' : '04',
                  title: 'Probe Trace',
                  child: _ProbeView(report: _lastReport),
                ),
                const SizedBox(height: 16),
                _section(
                  index: _role == _DemoRole.admin ? '06' : '05',
                  title: 'Terminal Log',
                  child: _LogView(logs: _logs),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section({
    required String index,
    required String title,
    required Widget child,
  }) {
    return _CyberPanel(index: index, title: title, child: child);
  }
}

class _HeroHeader extends StatelessWidget {
  const _HeroHeader({
    required this.status,
    required this.busy,
    required this.operation,
    required this.onRefresh,
  });

  final TailscaleStatus? status;
  final bool busy;
  final String? operation;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final state = status?.state.name.toUpperCase() ?? 'OFFLINE';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _matrix.withValues(alpha: 0.16),
            _cyan.withValues(alpha: 0.07),
            _panel,
          ],
        ),
        border: Border.all(color: _matrix.withValues(alpha: 0.46)),
        boxShadow: [
          BoxShadow(
            color: _matrix.withValues(alpha: 0.13),
            blurRadius: 28,
            spreadRadius: 3,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tailscale validation demo',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'secure tailnet probe console // macOS + iOS + Android',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _cyan,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
              ),
              _StatusChip(label: state, active: status?.isRunning ?? false),
            ],
          ),
          if (busy) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'ACTIVE: ${operation ?? 'working'}',
                    style: const TextStyle(
                      color: _amber,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _MetricPill(label: 'IPv4', value: status?.ipv4 ?? 'pending'),
              _MetricPill(
                label: 'Health',
                value: status?.health.isEmpty ?? true
                    ? 'clean'
                    : '${status!.health.length} warnings',
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : onRefresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh nodes'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CyberPanel extends StatelessWidget {
  const _CyberPanel({
    required this.index,
    required this.title,
    required this.child,
  });

  final String index;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _panel,
        border: Border.all(color: _matrix.withValues(alpha: 0.28)),
        boxShadow: [
          BoxShadow(
            color: _voidBlack.withValues(alpha: 0.6),
            blurRadius: 22,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            top: 0,
            right: 0,
            child: Container(
              width: 90,
              height: 2,
              color: _cyan.withValues(alpha: 0.8),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '[$index]',
                      style: const TextStyle(
                        color: _amber,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.3,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                  ],
                ),
                const SizedBox(height: 14),
                child,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ClientJoinView extends StatelessWidget {
  const _ClientJoinView({
    required this.authKey,
    required this.controlUrl,
    required this.busy,
    required this.onConnect,
    required this.onStartServices,
    required this.onStopServices,
    required this.onDown,
  });

  final TextEditingController authKey;
  final TextEditingController controlUrl;
  final bool busy;
  final Future<void> Function() onConnect;
  final Future<void> Function() onStartServices;
  final Future<void> Function() onStopServices;
  final Future<void> Function() onDown;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          controller: authKey,
          decoration: const InputDecoration(
            labelText: 'Auth key',
            hintText: 'paste a key issued by the admin',
          ),
          obscureText: true,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: controlUrl,
          decoration: const InputDecoration(
            labelText: 'Control URL',
            hintText: 'empty = Tailscale SaaS',
          ),
        ),
        const SizedBox(height: 14),
        _ActionStrip(
          busy: busy,
          primaryLabel: 'Join as client',
          primaryIcon: Icons.login,
          onPrimary: onConnect,
          onStartServices: onStartServices,
          onStopServices: onStopServices,
          onDown: onDown,
        ),
      ],
    );
  }
}

class _AdminJoinView extends StatelessWidget {
  const _AdminJoinView({
    required this.apiKey,
    required this.tailnetId,
    required this.busy,
    required this.onConnect,
    required this.onStartServices,
    required this.onStopServices,
    required this.onDown,
  });

  final TextEditingController apiKey;
  final TextEditingController tailnetId;
  final bool busy;
  final Future<void> Function() onConnect;
  final Future<void> Function() onStartServices;
  final Future<void> Function() onStopServices;
  final Future<void> Function() onDown;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Admin joins with a Tailscale API key and tailnet ID. The app '
          'generates the admin node auth key internally and does not display it.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: apiKey,
          decoration: const InputDecoration(
            labelText: 'Tailscale API key',
            hintText: 'tskey-api-...',
          ),
          obscureText: true,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: tailnetId,
          decoration: const InputDecoration(
            labelText: 'Tailnet ID',
            hintText: 'example.com or -',
          ),
        ),
        const SizedBox(height: 14),
        _ActionStrip(
          busy: busy,
          primaryLabel: 'Join as admin',
          primaryIcon: Icons.admin_panel_settings,
          onPrimary: onConnect,
          onStartServices: onStartServices,
          onStopServices: onStopServices,
          onDown: onDown,
        ),
      ],
    );
  }
}

class _ActionStrip extends StatelessWidget {
  const _ActionStrip({
    required this.busy,
    required this.primaryLabel,
    required this.primaryIcon,
    required this.onPrimary,
    required this.onStartServices,
    required this.onStopServices,
    required this.onDown,
  });

  final bool busy;
  final String primaryLabel;
  final IconData primaryIcon;
  final Future<void> Function() onPrimary;
  final Future<void> Function() onStartServices;
  final Future<void> Function() onStopServices;
  final Future<void> Function() onDown;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        FilledButton.icon(
          onPressed: busy ? null : onPrimary,
          icon: Icon(primaryIcon),
          label: Text(primaryLabel),
        ),
        OutlinedButton.icon(
          onPressed: busy ? null : onStartServices,
          icon: const Icon(Icons.play_circle_outline),
          label: const Text('Start services'),
        ),
        OutlinedButton.icon(
          onPressed: busy ? null : onStopServices,
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('Stop services'),
        ),
        OutlinedButton.icon(
          onPressed: busy ? null : onDown,
          icon: const Icon(Icons.logout),
          label: const Text('Down'),
        ),
      ],
    );
  }
}

class _ClientInviteView extends StatelessWidget {
  const _ClientInviteView({
    required this.generated,
    required this.busy,
    required this.connected,
    required this.onIssue,
  });

  final DemoGeneratedAuthKey? generated;
  final bool busy;
  final bool connected;
  final Future<void> Function() onIssue;

  @override
  Widget build(BuildContext context) {
    final generated = this.generated;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          connected
              ? 'Issue a one-day pre-approved client key for another device.'
              : 'Join as admin first, then issue client keys from here.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: busy || !connected ? null : onIssue,
          icon: const Icon(Icons.key),
          label: const Text('Issue client auth key'),
        ),
        if (generated != null) ...[
          const SizedBox(height: 14),
          _kv('Key ID', generated.id ?? '-'),
          _kv('Expires', generated.expires?.toLocal().toString() ?? '-'),
          const SizedBox(height: 8),
          const Text(
            'CLIENT AUTH KEY',
            style: TextStyle(
              color: _amber,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _voidBlack.withValues(alpha: 0.68),
              border: Border.all(color: _amber.withValues(alpha: 0.5)),
            ),
            child: SelectableText(
              generated.key,
              style: const TextStyle(color: _amber, fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }
}

class _StatusView extends StatelessWidget {
  const _StatusView({
    required this.status,
    required this.services,
    required this.stateDir,
  });

  final TailscaleStatus? status;
  final DemoServices? services;
  final String? stateDir;

  @override
  Widget build(BuildContext context) {
    final status = this.status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _kv('State dir', stateDir ?? 'loading...'),
        _kv('State', status?.state.name ?? 'not started'),
        _kv('Stable ID', status?.stableNodeId ?? '-'),
        _kv('IPv4', status?.ipv4 ?? '-'),
        _kv('Health', status?.health.join(', ') ?? '-'),
        _kv('Services', services?.toString() ?? 'not running'),
      ],
    );
  }
}

class _NodesView extends StatelessWidget {
  const _NodesView({
    required this.nodes,
    required this.showOnlyOnline,
    required this.nodeIp,
    required this.busy,
    required this.onToggleOnlineOnly,
    required this.onProbe,
  });

  final List<TailscaleNode> nodes;
  final bool showOnlyOnline;
  final TextEditingController nodeIp;
  final bool busy;
  final ValueChanged<bool> onToggleOnlineOnly;
  final Future<void> Function(String nodeIp) onProbe;

  @override
  Widget build(BuildContext context) {
    final visibleNodes = showOnlyOnline
        ? nodes.where((node) => node.online).toList(growable: false)
        : nodes;
    final hiddenCount = nodes.length - visibleNodes.length;
    return Column(
      children: [
        TextField(
          controller: nodeIp,
          decoration: InputDecoration(
            labelText: 'Node IP',
            suffixIcon: IconButton(
              onPressed: busy || nodeIp.text.trim().isEmpty
                  ? null
                  : () => onProbe(nodeIp.text.trim()),
              icon: const Icon(Icons.play_arrow),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                showOnlyOnline
                    ? 'Showing ${visibleNodes.length} online of ${nodes.length} nodes'
                    : 'Showing all ${nodes.length} nodes',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            FilterChip(
              selected: showOnlyOnline,
              showCheckmark: false,
              avatar: Icon(
                showOnlyOnline ? Icons.online_prediction : Icons.blur_on,
                size: 18,
                color: showOnlyOnline ? _matrix : _muted,
              ),
              label: const Text('Online only'),
              onSelected: busy ? null : onToggleOnlineOnly,
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (nodes.isEmpty)
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('No nodes yet.'),
          )
        else if (visibleNodes.isEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              hiddenCount == 0
                  ? 'No nodes match this filter.'
                  : '$hiddenCount offline node${hiddenCount == 1 ? '' : 's'} hidden.',
              style: const TextStyle(color: _muted),
            ),
          )
        else
          ...visibleNodes.map((node) {
            final ip = node.ipv4;
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: _voidBlack.withValues(alpha: 0.35),
                border: Border.all(color: _cyan.withValues(alpha: 0.18)),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                title: Text(
                  node.hostName,
                  style: const TextStyle(
                    color: _matrix,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Text(
                  '${ip ?? 'no ipv4'}  online=${node.online}',
                  style: const TextStyle(color: _muted),
                ),
                trailing: FilledButton.tonal(
                  onPressed: busy || ip == null ? null : () => onProbe(ip),
                  child: const Text('Probe'),
                ),
                onTap: ip == null ? null : () => nodeIp.text = ip,
              ),
            );
          }),
      ],
    );
  }
}

class _ProbeView extends StatelessWidget {
  const _ProbeView({required this.report});

  final DemoProbeReport? report;

  @override
  Widget build(BuildContext context) {
    final report = this.report;
    if (report == null) return const Text('No probe run yet.');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusChip(
          label: 'Node ${report.nodeIp}: ${report.ok ? 'PASS' : 'FAIL'}',
          active: report.ok,
        ),
        const SizedBox(height: 10),
        ...report.results.map((result) {
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _voidBlack.withValues(alpha: 0.44),
              border: Border.all(
                color: (result.ok ? _matrix : _danger).withValues(alpha: 0.34),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  result.ok ? Icons.check_circle : Icons.error,
                  color: result.ok ? _matrix : _danger,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        result.kind.label,
                        style: const TextStyle(
                          color: _cyan,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${result.duration.inMilliseconds}ms  ${result.message}',
                        style: const TextStyle(color: _muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class _LogView extends StatelessWidget {
  const _LogView({required this.logs});

  final List<String> logs;

  @override
  Widget build(BuildContext context) {
    if (logs.isEmpty) return const Text('No logs yet.');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _voidBlack.withValues(alpha: 0.72),
        border: Border.all(color: _matrix.withValues(alpha: 0.16)),
      ),
      child: SelectableText(
        logs.join('\n'),
        style: const TextStyle(
          color: _matrix,
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.35,
        ),
      ),
    );
  }
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: _voidBlack.withValues(alpha: 0.52),
        border: Border.all(color: _cyan.withValues(alpha: 0.28)),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label ',
              style: const TextStyle(
                color: _muted,
                fontSize: 12,
                letterSpacing: 0.9,
              ),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(color: _cyan, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? _matrix : _amber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _CyberBackground extends StatelessWidget {
  const _CyberBackground();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _voidBlack,
      child: CustomPaint(
        painter: _CyberGridPainter(),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _CyberGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = _matrix.withValues(alpha: 0.055)
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 32) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += 32) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final scan = Paint()
      ..color = _cyan.withValues(alpha: 0.035)
      ..strokeWidth = 1;
    for (var y = 8.0; y < size.height; y += 7) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), scan);
    }

    final beam = Paint()
      ..shader = LinearGradient(
        colors: [
          _matrix.withValues(alpha: 0.0),
          _matrix.withValues(alpha: 0.16),
          _cyan.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawCircle(Offset(size.width * 0.15, 80), 220, beam);
    canvas.drawCircle(Offset(size.width * 0.88, size.height * 0.25), 190, beam);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

Widget _kv(String key, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            key.toUpperCase(),
            style: const TextStyle(
              color: _muted,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(color: Color(0xffd8fff2)),
          ),
        ),
      ],
    ),
  );
}
