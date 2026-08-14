# iOS physical-device report — tailscale 0.9.0

This is the canonical iOS report for the `0.9.0` release candidate. It combines
the separately executed profile, production-custody, and hosted-boundary runs
without changing what any individual run proves. The raw artifacts remain the
source of truth.

## Qualification

| Device | Ephemeral data plane | Persistent custody | Process-death reconnect | Local reset | Profiling | Hosted Serve/Funnel |
| --- | --- | --- | --- | --- | --- | --- |
| iPhone 16, iOS 18.7.3 (22H217), arm64 | PASS | PASS | PASS | PASS | PASS | PARTIAL |

`PARTIAL` is not a platform pass. The hosted receipt proves the specific
boundaries listed below, but not a complete mobile Serve/Funnel lifecycle.

## Evidence

| Run | Exact source | Evidence |
| --- | --- | --- |
| Ephemeral correctness and network profile | `6f301bdf8c8d74a867f1d0f0fc3cf838feaf73b3`; clean | [raw JSON](2026-08-13-ios-arm64.json), [generated run summary](2026-08-13-ios-arm64.md) |
| Persistent custody, process death, reconnect, reset, and hosted boundaries | `88cd50d4e75b16ce4fb5b09eba98e9ec5d5c318e` | [content-free narrative receipt](../../../../test/device_receipts/2026-08-12-ios-18.7.3.md) |

Both runs used Flutter 3.44.4 and Dart 3.12.2. Their source commits preserve
the exact provenance of each receipt; `releaseVersion: 0.9.0` associates the
runtime-identical pre-version-bump profile with this release.

## Correctness

| Overall | Join | Nodes | Ping* | WhoIs | HTTP GET | HTTP POST | TCP | UDP | Restart |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| PASS | PASS | PASS | WARN | PASS | PASS | PASS | PASS | PASS | PASS |

The initial diagnostic LocalAPI ping timed out and one of 20 profiled pings did
not complete, while every required probe passed. Ping is therefore a recorded
convergence warning, not a correctness failure.

## Persistent custody and recovery

The production iOS Keychain/Keybay path passed the complete lifecycle:

- fresh non-ephemeral enrollment created persistent secure custody and the
  package state root was marked and verified as excluded from backup;
- a host-issued SIGKILL and fresh app process reopened without an auth key;
- the same node ID and Tailscale IPv4 address were preserved, and WhoIs, HTTP
  GET/POST, TCP, and UDP passed after reconnect;
- a content-free inventory classified all nine package-owned filesystem
  entries and rejected unknown artifacts or unsafe modes; and
- explicit local reset removed both the Keybay identity and package state
  subtree.

The receipt intentionally omits credentials, state contents, identifiers, and
addresses.

## Network profile

The complete 20-sample profile used a direct Tailscale path for 19 samples and
detached Flutter tooling. Headline medians were:

| API metric | Samples | p50 | p95 | Mean |
| --- | ---: | ---: | ---: | ---: |
| HTTP GET | 20 | 13.044 ms | 17.785 ms | 13.426 ms |
| HTTP POST | 20 | 11.222 ms | 98.289 ms | 20.776 ms |
| Ping network RTT | 19 | 8.220 ms | 18.904 ms | 9.144 ms |
| Ping API round trip | 19 | 10.032 ms | 19.915 ms | 10.645 ms |
| TCP echo | 20 | 18.830 ms | 32.649 ms | 21.645 ms |
| UDP echo | 20 | 9.989 ms | 21.013 ms | 12.295 ms |
| WhoIs | 20 | 0.952 ms | 2.541 ms | 1.267 ms |

| Measurement | Upload median (range) | Download median (range) |
| --- | ---: | ---: |
| Dart public API over Tailscale | 0.49 MiB/s (0.41–0.84) | 1.14 MiB/s (0.70–1.15) |
| Device-side direct `tsnet` diagnostic | 0.32 MiB/s (0.28–0.45) | 1.08 MiB/s (0.88–1.17) |
| Ordinary LAN control | 0.83 MiB/s | 1.20 MiB/s |

The Dart/direct paired medians were 174.5% upload and 96.7% download, with wide
ranges. Those ratios are advisory diagnostics, not evidence that Dart is
faster than `tsnet`; device scheduling and Wi-Fi variance can dominate a
five-second pair. The raw JSON retains all small-operation, throughput,
write-completion, interval, path, and paired samples for like-for-like trend
comparison.

## Hosted Tailscale boundaries

The physical receipt proved that:

- `tls.bind` returned the expected upstream-conformant mobile error;
- Funnel replaced Serve on the same `443/path` coordinate;
- closing the stale Serve handle did not clear the replacement Funnel mapping;
  and
- an independent host fetched the public Funnel URL with HTTP 200 and the exact
  expected body.

Fresh HTTPS Serve could not complete because Tailscale certificate issuance
returned external `SetDNS` failures and then rate limiting. Consequently the
complete Serve -> Funnel -> replacement Serve HTTPS lifecycle remains
unqualified on iOS. All hosted test nodes and interrupted local namespaces were
cleaned up.
