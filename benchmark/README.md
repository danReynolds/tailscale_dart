# Benchmarks

This directory contains local benchmarks for changes that need before/after
numbers.

## Published-release comparison

`release_compare.dart` measures the public performance paths against both the
pinned pub.dev release in `profile/baseline.json` and the current checkout. It
reuses the Headscale Docker environment and fixed E2E echo peer, but it does
not run or duplicate the functional test suite.

```sh
dart run benchmark/release_compare.dart
```

The full profile alternates five trials per version, takes 50 steady-state
samples and one five-second upload plus download per trial, and covers
lifecycle, control calls, HTTP, TCP, UDP, persistent enrollment/restart,
event-loop lag, sustained throughput, and RSS. Raw samples and the aggregate
comparison are written to a temporary JSON report. A one-trial development pass
is available while editing the harness:

```sh
dart run \
  benchmark/release_compare.dart --quick
```

Useful overrides are `--trials=N`, `--iterations=N`, `--baseline=VERSION`, and
`--output=PATH`.

Canonical full-profile evidence is checked into [`results/`](results/), grouped
by the package version being measured. Keep only clean, default full runs there;
quick and diagnostic reports remain temporary.

The runner deliberately uses the same public-API probe for both versions. A
small generated adapter is the only version-specific part: the published
`0.8.0` baseline uses its native persistence, while current uses the existing
deterministic E2E custody backend so the comparison never touches a developer's
production Keychain or Secret Service. Production custody latency remains a
separate platform/device receipt.

The 15% verdict is an initial materiality label, not a CI gate. Establish the
runner's variance across repeated jobs before making it blocking. Verdicts also
require an absolute change of at least 0.1 ms (1 ms for event-loop p95) so tiny
percentage changes are not mislabeled, plus the same direction in at least 80%
of three or more paired trials. One-trial quick runs cannot emit regression or
improvement verdicts, and material results without a consistent direction are
reported as inconclusive rather than parity. Initial enrollment, first-path
setup, host event-loop lag, and process RSS remain explicitly advisory because
control-plane behavior, path selection, host scheduling, and VM allocation
state dominate them. RSS still records every checkpoint and paired direction;
it needs repeat evidence rather than a single threshold crossing. If a
repeatable scenario regresses, use a profiler or targeted instrumentation to
find the cause; do not add tracing to this comparison harness.

## Physical-device network profiles

The Flutter smoke matrix can optionally collect a thin, repeatable network
profile on a real device. It still runs the normal join, discovery,
WhoIs/HTTP/TCP/UDP, and restart assertions; profiling only adds repeated samples
after the first successful data-plane cycle.

```sh
DUNE_SMOKE_CONTROL_URL_IOS=http://<host-lan-ip>:18080 \
DUNE_SMOKE_RUNNER_URL_IOS=http://<host-lan-ip>:18099 \
  tool/smoke/run_matrix.sh \
  --targets ios \
  --ios-device <device-id> \
  --runner-bind-address 0.0.0.0 \
  --strict \
  --timeout-seconds 900 \
  --profile-samples 20 \
  --output benchmark/results/<version>/devices/<date>-ios-arm64.json
```

Android physical-device runs use the corresponding Android variables and
device selector:

```sh
DUNE_SMOKE_CONTROL_URL_ANDROID=http://<host-lan-ip>:18080 \
DUNE_SMOKE_RUNNER_URL_ANDROID=http://<host-lan-ip>:18099 \
  tool/smoke/run_matrix.sh \
  --targets android \
  --android-device <device-id> \
  --runner-bind-address 0.0.0.0 \
  --strict \
  --timeout-seconds 900 \
  --profile-samples 20 \
  --output benchmark/results/<version>/devices/<date>-android-arm64.json
```

Profile runs use Flutter profile mode, but detach Flutter tooling before the
workload and disable Dart sampling, DDS, DevTools, and iOS VM-service discovery.
Keeping `flutter run` attached measurably distorts physical-device throughput;
the artifact records the detached launch mode. Profile runs record p50/p95 for
repeated small API operations and three five-second sustained TCP uploads plus
downloads. The shared `tcp-sustained-v2` workload is the same one used by the
host release comparison: 64 KiB chunks flow through a bounded 512 KiB window,
while sender write-completion latency is reported separately. Each public-Dart
transfer is
paired with the same workload directly on the active upstream `tsnet.Conn`,
bypassing the fd/socketpair/reactor bridge. Pair order alternates by run. The
native symbol is enabled only by the unpublished smoke app's native-asset build
tag; it is absent from ordinary package builds and the public Dart API.
This bypass is device-side only: both lanes use the same remote Dart-library
speed-test peer. That holds the peer constant and isolates the local bridge,
but it is not a native-`tsnet`-to-native-`tsnet` ceiling measurement.
Receiver-side byte count, elapsed time, one-second intervals, and write
p50/p95/p99 remain in the raw JSON. The Markdown summary shows median and range
for each lane and the paired Dart/native ratio. Device IDs, auth keys, tailnet
addresses, payloads, and raw error messages are excluded.

The runner also serves a short control with the same protocol, chunk size, and
write window over an ordinary host LAN socket and records it beside the
Tailscale result. Its single one-second sample per direction is a coarse
ceiling check, not another benchmark series. Read the three lanes together:
public Dart versus direct `tsnet` is the binding/bridge diagnostic, while
direct `tsnet` versus LAN includes Tailscale userspace/encryption and the
tailnet path. If both Tailscale lanes track each other, the Dart bridge is not
the limiting factor. If all three fall together, suspect the device, Wi-Fi, or
host. Keeping the control short also avoids a host loopback copying tens of
gigabytes and distorting later samples. Use `DUNE_SMOKE_LAN_HOST_IOS` or
`DUNE_SMOKE_LAN_HOST_ANDROID` only when the runner URL's host is not reachable
for the plain socket.

iOS Simulator cannot run Flutter profile mode. A diagnostic simulator control
can opt into `--profile-run-mode debug`; it is also detached, and its artifact
records both settings. It must not be compared numerically with physical
profile-mode history.

Correctness and profiling have separate outcomes. A device can pass join,
discovery, HTTP/TCP/UDP, and restart while its profile is invalid because a path
changed or collection failed. The command still exits unsuccessfully when a
requested profile is incomplete, but the report does not mislabel that as a
functional failure.

These numbers are historical evidence, not CI thresholds. Compare runs only
when the physical device, OS, network conditions, control plane, workload, and
sample count are meaningfully alike. A path change from direct to DERP can
dominate every data-plane metric, so each sustained run checks its path before
and after and becomes comparison-ineligible if it is unknown or changes.
Even direct-path Wi-Fi can stall within a pair; use paired medians and ranges,
and repeat a surprising result before attributing it to the bridge. A ratio
above 100% can occur from ordinary variance and does not mean Dart outperforms
the underlying `tsnet` transport.
Keep dirty and exploratory profiles in the temporary directory; commit only
clean, representative runs under [`results/`](results/).

## POSIX fd transport

`fd_transport.dart` measures the fd data-plane primitive used underneath the
package TCP, UDP, and HTTP APIs. It intentionally avoids reactor-specific debug
hooks so the same benchmark can run against the pre-reactor implementation and
the shared-reactor implementation.

Run the same command on both branches:

```sh
dart run \
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
dart run \
  benchmark/fd_transport.dart \
  --pairs=1,10 \
  --extra-pairs=1 \
  --payload-mib=1 \
  --latency-writes=20 \
  --churn-count=20 \
  --http-requests=20
```

## Bounded and pipelined bulk transfer

The primitive benchmark's default scenarios await each chunk write, which is
intentionally latency-bound and cannot exercise pipelining-dependent effects
(socketpair buffer sizing, inbound read batching). The historical
`tcp-sustained-v1` profile made the same choice and therefore mixed per-write
scheduling latency into its apparent throughput. `tcp-sustained-v2` instead
uses a bounded 512 KiB window; the experiment below remains the deliberately
unbounded upper-bound control.

```sh
dart run benchmark/fd_transport.dart --pipelined
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
