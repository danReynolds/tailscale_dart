# Benchmarks

This directory contains local benchmarks for changes that need before/after
numbers.

## Published-release comparison

`release_compare.dart` measures the public performance paths against both the
pinned pub.dev release in `profile/baseline.json` and the current checkout. It
reuses the Headscale Docker environment and fixed E2E echo peer, but it does
not run or duplicate the functional test suite.

```sh
dart run --enable-experiment=native-assets benchmark/release_compare.dart
```

The full profile alternates five trials per version and covers lifecycle,
control calls, HTTP, TCP, UDP, persistent enrollment/restart, event-loop lag,
throughput, and RSS. Raw samples and the aggregate comparison are written to a
temporary JSON report. A one-trial development pass is available while editing
the harness:

```sh
dart run --enable-experiment=native-assets \
  benchmark/release_compare.dart --quick
```

Useful overrides are `--trials=N`, `--iterations=N`,
`--bulk-iterations=N`, `--baseline=VERSION`, and `--output=PATH`.

The runner deliberately uses the same public-API probe for both versions. A
small generated adapter is the only version-specific part: the published
`0.8.0` baseline uses its native persistence, while current uses the existing
deterministic E2E custody backend so the comparison never touches a developer's
production Keychain or Secret Service. Production custody latency remains a
separate platform/device receipt.

The 15% verdict is an initial materiality label, not a CI gate. Establish the
runner's variance across repeated jobs before making it blocking. Verdicts also
require an absolute change of at least 0.1 ms (1 ms for event-loop p95) so tiny
percentage changes are not mislabeled. Initial enrollment, first-path setup,
and host event-loop lag remain explicitly advisory because control-plane/path
selection and host scheduling dominate them. If a repeatable scenario
regresses, use a profiler or targeted instrumentation to find the cause; do not
add tracing to this comparison harness.

## POSIX fd transport

`fd_transport.dart` measures the fd data-plane primitive used underneath the
package TCP, UDP, and HTTP APIs. It intentionally avoids reactor-specific debug
hooks so the same benchmark can run against the pre-reactor implementation and
the shared-reactor implementation.

Run the same command on both branches:

```sh
/Users/dan/Coding/flutter_arm64/bin/dart run \
  --enable-experiment=native-assets \
  benchmark/fd_transport.dart \
  --pairs=1,10,50,100 \
  --extra-pairs=1 \
  --payload-mib=4 \
  --latency-writes=200 \
  --json
```

Useful metrics:

- `throughput_one_way.mib_per_second`: aggregate one-way byte throughput across
  all active fd pairs.
- `write_latency.p50_us`, `p95_us`, `p99_us`: completion latency for small
  writes, which is the best proxy for control responsiveness under concurrency.
- `writes_per_second`: aggregate small-write completion rate.
- `adoption_churn`: repeated create/use/close latency, useful for short TCP and
  HTTP connection churn.
- `throughput_full_duplex`: simultaneous bidirectional throughput, closer to
  real TCP stream behavior than one-way transfer.
- `fairness_under_load`: small-write latency while background streams are
  moving larger payloads.
- `http_shaped_requests`: two fd pairs per request, modeling request-body and
  response-body transports.
- `rss_*_mib`: process RSS deltas for coarse memory-growth comparison.

The main optimization triggers are:

- Wake coalescing: each public `write()` posts a reactor command and wakes the
  poller. If `writes_per_second` or `write_latency.p99_us` regresses under many
  small writes, coalescing multiple Dart-event-loop writes behind one native
  wake is the likely next optimization.
- More reactor shards: one shard means one isolate owns all fd readiness,
  syscalls, copies, and SendPort delivery. If high pair counts show p99 latency
  rising while CPU remains available on other cores, increasing the internal
  shard count is the likely next optimization.

The default run keeps the heavy scenarios bounded so the old isolate-per-fd
backend can still finish. Use these knobs to scale targeted scenarios:

- `--extra-pairs=1`: pair counts for full-duplex and fairness benchmarks.
  Larger values are useful for targeted reactor stress runs, but the old
  isolate-per-fd backend may be slow or time out under high full-duplex load.
- `--churn-count=100`: number of create/use/close loops.
- `--http-requests=100`: number of HTTP-shaped request/response loops.

For a quick smoke run while iterating:

```sh
/Users/dan/Coding/flutter_arm64/bin/dart run \
  --enable-experiment=native-assets \
  benchmark/fd_transport.dart \
  --pairs=1,10 \
  --extra-pairs=1 \
  --payload-mib=1 \
  --latency-writes=20 \
  --churn-count=20 \
  --http-requests=20
```

## Pipelined bulk transfer

The default scenarios await each chunk write, which is latency-bound and cannot
exercise pipelining-dependent effects (socketpair buffer sizing, inbound read
batching) — only one chunk is ever in flight, so the socketpair never
accumulates. Real bulk transfer (e.g. Go's `io.Copy` filling the socketpair)
pipelines, and that is where socketpair buffers dominate.

```sh
dart run --enable-experiment=native-assets benchmark/fd_transport.dart --pipelined
```

This runs a small matrix over socketpair buffer size and receiver read-chunk
size with a pipelined writer. Findings on the reference machine: enlarging the
socketpair buffer from the OS default to 256 KiB is a ~4× single-pair win under
pipelining (which is why the real `newSocketPairConn` sets it); a larger
receiver read chunk adds little once the buffer is sized. Note this measures the
socketpair hop in isolation — in production the tsnet/WireGuard/tailnet link is
usually the bottleneck, so socketpair throughput well above a few Gbps does not
translate to real-world gains except on fast LAN-direct peers.

## Interpretation guidance

- Compare the same machine, same power mode, same SDK, and same command.
- Run each branch more than once; first runs include native asset build and VM
  warmup noise.
- The benchmark is intentionally local. Tailnet E2E smoke tests still validate
  that public TCP, UDP, and HTTP behavior works through tsnet.
