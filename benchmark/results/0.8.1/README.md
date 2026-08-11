# tailscale 0.8.1 performance

Canonical report: [`macos-arm64-vs-0.8.0.json`](macos-arm64-vs-0.8.0.json)

- Measured source: `4b80282bd3f7aa16f97999c9bc35a6795591c615`
- Published baseline: `tailscale 0.8.0`
- Host: macOS arm64, Dart 3.12.2
- Profile: five alternating paired trials, 50 steady-state iterations
- Checkout: clean

## Material results

| Scenario | 0.8.0 p50 | 0.8.1 p50 | Delta | Verdict |
| --- | ---: | ---: | ---: | --- |
| Steady HTTP GET | 1.383 ms | 1.510 ms | +9.2% | parity |
| Persistent restart | 49.476 ms | 110.088 ms | +122.5% | regression |
| Ephemeral down | 10.998 ms | 160.787 ms | +1362.0% | regression |
| First UDP round trip | 2.034 ms | 1.702 ms | -16.3% | inconclusive |

The HTTP admission regression found during development was removed before this
canonical run. Persistent restart remains slower because the new architecture
performs encrypted, atomic, crash-durable state updates and re-proves the
runtime configuration. Targeted teardown instrumentation localized the
ephemeral-down difference to upstream `tsnet.Server.Close()` after the required
first-`Server.Up` ServeConfig/Services reset; package-owned cleanup was
negligible. Both lifecycle costs are retained as correctness and upstream
conformance tradeoffs rather than optimized away.

Process RSS was 6–12% higher at the recorded checkpoints, but remains advisory
because the release baseline varied materially between runs. The raw report
retains every RSS sample for future trend analysis.
