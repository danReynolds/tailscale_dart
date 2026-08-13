# tailscale 0.9.0 performance

These reports were captured immediately before the metadata-only `0.9.0`
version bump. Their raw source version remains `0.8.1` so the recorded commit
provenance stays exact; `releaseVersion: 0.9.0` associates the runtime-identical
candidate with this release.

Canonical report: [`macos-arm64-vs-0.8.0.json`](macos-arm64-vs-0.8.0.json)

Physical-device reports:

- [`2026-08-13 Android arm64`](devices/2026-08-13-android-arm64.md) — Pixel 6a,
  Android 16 (API 36), clean checkout, correctness and profile complete.
- [`2026-08-13 iOS arm64`](devices/2026-08-13-ios-arm64.md) — iPhone 16,
  iOS 18.7.3, clean checkout, correctness and profile complete.

These profile runs used ephemeral nodes. They prove the physical-device data
plane and profiling lanes, not persistent custody or process-death reconnect.
Those lifecycle qualifications are recorded separately under
[`test/device_receipts/`](../../../test/device_receipts/), including the
[Android 16 persistent-custody matrix](../../../test/device_receipts/2026-08-13-android-16.md)
and [iOS 18.7.3 receipt](../../../test/device_receipts/2026-08-12-ios-18.7.3.md).

## Host release comparison

- Measured source: `1bc8f511cd5e9a7cdbb090c61f1d05483543515f`
- Published baseline: `tailscale 0.8.0`
- Host: macOS arm64, Dart 3.12.2
- Profile: five alternating paired trials, 50 steady-state iterations
- Checkout: clean

## Material results

| Scenario | 0.8.0 p50 | 0.9.0 candidate p50 | Delta | Verdict |
| --- | ---: | ---: | ---: | --- |
| Sustained download | 31.695 MiB/s | 31.934 MiB/s | +0.8% | parity |
| Sustained upload | 33.434 MiB/s | 33.504 MiB/s | +0.2% | parity |
| Steady HTTP GET | 1.277 ms | 1.272 ms | -0.4% | parity |
| Ephemeral down | 9.089 ms | 11.475 ms | +26.3% | regression |
| First UDP round trip | 3.096 ms | 2.306 ms | -25.5% | improvement |

The `0.9.0` public data plane is at parity with 0.8.0, including the new five-second
directional workload. The HTTP admission regression found during development
remains removed. Persistent custody lifecycle timings are retained as advisory
context because the hosted baseline and current checkout intentionally use
different storage implementations. Targeted teardown instrumentation had
already localized the remaining ephemeral-down difference to upstream
`tsnet.Server.Close()` after the required first-`Server.Up`
ServeConfig/Services reset; package-owned cleanup was negligible. It remains a
small, repeatable upstream-conformance tradeoff rather than a data-plane issue.

Process RSS was 6–7% higher at the recorded checkpoints, but remains advisory
because the release baseline varied materially between runs. The raw report
retains every RSS sample for future trend analysis.

## Android physical-device profile

All required join, discovery, WhoIs, HTTP, TCP, UDP, and restart checks passed.
The initial diagnostic LocalAPI ping timed out while every required data path
succeeded; the subsequent 20 sampled pings completed, so this remains a
non-gating convergence observation.

Median public-Dart throughput was 2.72 MiB/s upload and 2.57 MiB/s download.
The one-run ordinary-LAN ceiling was only 3.52 MiB/s upload and 4.66 MiB/s
download, while paired direct-tsnet results varied widely. That makes this a
useful historical device/network baseline, not evidence that either bridge is
intrinsically faster. The raw report retains the paired and interval samples.

## iOS physical-device profile

All required join, discovery, WhoIs, HTTP, TCP, UDP, and restart checks passed.
The initial diagnostic LocalAPI ping timed out and one of 20 sampled pings did
not complete; all required probes passed in every sample, so this is retained
as a non-gating convergence observation.

Median public-Dart throughput was 0.49 MiB/s upload and 1.14 MiB/s download.
The ordinary-LAN control was similarly constrained at 0.83 MiB/s upload and
1.20 MiB/s download. The public-Dart and direct-tsnet download medians were
close, while upload pairs remained noisy. As with Android, these are useful
historical ballpark numbers under the recorded device/network conditions, not
an architecture verdict.
