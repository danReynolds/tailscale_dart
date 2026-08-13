# Shared profile workload

This private package contains the dependency-free sustained TCP workload shared
by the host release comparison and Flutter device profiles. It owns framing,
warm-up, directional transfer, receiver-side byte/time accounting, interval
samples, and JSON serialization. Callers own Tailscale connections, path checks,
orchestration, and reporting.

The canonical `tcp-sustained-v2` workload is one stream, a 1 MiB warm-up, and
a five-second measurement using 64 KiB chunks with a bounded 512 KiB write
window. A whole directional run is one sample; one-second intervals are
diagnostics, not independent samples. Sender write-completion p50/p95/p99 is
recorded separately so local scheduling stalls remain visible without making
the throughput workload latency-bound.

The ordinary-LAN control reuses the same protocol, chunk size, and write
window, but records only one one-second sample per direction. It is a coarse
runtime/network ceiling check, not a second benchmark series. Keeping it short
prevents a fast host loopback from copying tens of gigabytes and contaminating
the Tailscale result with allocator, scheduler, or thermal pressure.

Run its focused protocol tests with:

```sh
dart test
```
