# Benchmarks

This directory contains local benchmarks for changes that need before/after
numbers.

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

For a quick smoke run while iterating:

```sh
/Users/dan/Coding/flutter_arm64/bin/dart run \
  --enable-experiment=native-assets \
  benchmark/fd_transport.dart \
  --pairs=1,10 \
  --payload-mib=1 \
  --latency-writes=20
```

Interpretation guidance:

- Compare the same machine, same power mode, same SDK, and same command.
- Run each branch more than once; first runs include native asset build and VM
  warmup noise.
- The benchmark is intentionally local. Tailnet E2E smoke tests still validate
  that public TCP, UDP, and HTTP behavior works through tsnet.
