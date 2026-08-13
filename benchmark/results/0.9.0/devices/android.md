# Android physical-device report — tailscale 0.9.0

This is the canonical Android report for the `0.9.0` release candidate. It
combines the separately executed profile and production-custody runs without
changing what either run proves. The raw artifacts remain the source of truth.

## Qualification

| Device | Ephemeral data plane | Persistent custody | Process-death reconnect | Local reset | Profiling | Hosted Serve/Funnel |
| --- | --- | --- | --- | --- | --- | --- |
| Pixel 6a, Android 16 (API 36), arm64 | PASS | PASS | PASS | PASS | PASS | NOT RUN |

`NOT RUN` is distinct from `PASS`. Hosted Tailscale publication behavior was
not exercised on this Android device.

## Evidence

| Run | Exact source | Evidence |
| --- | --- | --- |
| Ephemeral correctness and network profile | `eacb119f5db4a4a7044994e644f8cf60e65e937d`; clean | [raw JSON](2026-08-13-android-arm64.json), [generated run summary](2026-08-13-android-arm64.md) |
| Persistent custody, process death, reconnect, and reset | `a77fd58ba06e54cc561df446cdbfdfd9a78c6610`; clean | [raw JSON](../../../../test/device_receipts/2026-08-13-android-16.json), [generated run summary](../../../../test/device_receipts/2026-08-13-android-16.md) |

Both runs used Flutter 3.44.4 and Dart 3.12.2. Their source commits preserve
the exact provenance of each receipt; `releaseVersion: 0.9.0` associates the
runtime-identical pre-version-bump profile with this release.

## Correctness

| Overall | Join | Nodes | Ping* | WhoIs | HTTP GET | HTTP POST | TCP | UDP | Restart |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| PASS | PASS | PASS | WARN | PASS | PASS | PASS | PASS | PASS | PASS |

The initial diagnostic LocalAPI ping timed out, but all 20 profiled pings and
every required data-plane check completed. Ping is therefore a recorded
convergence warning, not a correctness failure.

## Persistent custody and recovery

The production Android Keybay/Keystore path passed the complete lifecycle:

- fresh non-ephemeral enrollment created the hardware-backed Keybay DEK and
  encrypted StateStore;
- an OS force-stop and fresh app process reopened without an auth key;
- the same Tailscale identity was preserved and WhoIs, HTTP GET/POST, TCP, and
  UDP passed after reconnect; and
- `forgetLocalIdentity()` removed both the exact Keybay DEK and the package's
  state subtree.

The custody artifact contains classifications and booleans only. It omits
credentials, node keys, state values, device identifiers, addresses, and raw
crash output.

## Network profile

The complete 20-sample profile used a direct Tailscale path and detached
Flutter tooling. Headline medians were:

| API metric | Samples | p50 | p95 | Mean |
| --- | ---: | ---: | ---: | ---: |
| HTTP GET | 20 | 27.230 ms | 88.353 ms | 39.323 ms |
| HTTP POST | 20 | 27.076 ms | 146.297 ms | 42.602 ms |
| Ping network RTT | 20 | 23.050 ms | 55.242 ms | 26.141 ms |
| Ping API round trip | 20 | 32.435 ms | 61.699 ms | 37.405 ms |
| TCP echo | 20 | 58.480 ms | 249.812 ms | 89.459 ms |
| UDP echo | 20 | 37.974 ms | 129.596 ms | 50.630 ms |
| WhoIs | 20 | 4.187 ms | 7.172 ms | 4.748 ms |

| Measurement | Upload median (range) | Download median (range) |
| --- | ---: | ---: |
| Dart public API over Tailscale | 2.72 MiB/s (1.96–3.44) | 2.57 MiB/s (2.56–4.22) |
| Device-side direct `tsnet` diagnostic | 2.54 MiB/s (1.66–2.86) | 1.92 MiB/s (1.85–3.31) |
| Ordinary LAN control | 3.52 MiB/s | 4.66 MiB/s |

The Dart/direct paired medians were 118.2% upload and 138.5% download, with
wide ranges. Those ratios are advisory diagnostics, not evidence that Dart is
faster than `tsnet`; device scheduling and Wi-Fi variance can dominate a
five-second pair. The raw JSON retains all small-operation, throughput,
write-completion, interval, path, and paired samples for like-for-like trend
comparison.
