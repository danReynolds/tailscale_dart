import 'package:demo_core/demo_core.dart';
import 'package:test/test.dart';

void main() {
  test('DemoProbeReport ok reflects all probe results', () {
    final report = DemoProbeReport(
      nodeIp: '100.64.0.2',
      results: [
        DemoProbeResult(
          kind: DemoProbeKind.httpGet,
          ok: true,
          duration: Duration.zero,
          message: 'ok',
        ),
        DemoProbeResult(
          kind: DemoProbeKind.tcpEcho,
          ok: false,
          duration: Duration.zero,
          message: 'boom',
        ),
      ],
    );

    expect(report.ok, isFalse);
  });
}
