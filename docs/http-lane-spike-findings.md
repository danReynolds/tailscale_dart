# Go-Backed HTTP Lane Spike Findings

## Scope

This spike tested the preferred HTTP-lane direction from
[rfc-explicit-runtime-boundary.md](./rfc-explicit-runtime-boundary.md):

- keep the public surface as standard `package:http`
- execute requests in Go
- use `tsnet.Server.HTTPClient()` as the transport authority
- keep the HTTP lane separate from the raw stream/datagram substrate

The spike intentionally used a **buffered** request/response shape rather
than a production streaming implementation. The goal was to validate the
basic direction before designing a full request/response body transport.

## Implementation

The spike path is isolated and not wired into the public API:

- Go round-trip helper: [go/http_spike.go](/Users/dan/Coding/tailscale_dart/go/http_spike.go)
- exported FFI entrypoint: [go/cmd/dylib/main.go](/Users/dan/Coding/tailscale_dart/go/cmd/dylib/main.go)
- Dart binding: [lib/src/ffi_bindings.dart](/Users/dan/Coding/tailscale_dart/lib/src/ffi_bindings.dart)
- test hook: [test/ffi_integration_test.dart](/Users/dan/Coding/tailscale_dart/test/ffi_integration_test.dart)

The request shape is:

- method
- URL
- headers
- buffered request body

The response shape is:

- status code
- headers
- final URL after redirects
- buffered response body

## Findings

### 1. The Go-backed request path is easy to express

The control-plane shape is straightforward:

- Dart can serialize a request shape to JSON
- Go can reconstruct `http.Request`
- Go can execute it through `srv.HTTPClient()`
- Go can return status, headers, final URL, and body in one response

So the **request/response head mapping is not the hard part**.

### 2. `srv.HTTPClient()` is not meaningfully testable against localhost

The local test harness used a loopback `HttpServer` as the target.
Requests executed through `srv.HTTPClient()` timed out against
`http://127.0.0.1:<port>/...`.

That means:

- localhost is **not** a representative validation target for this lane
- a normal unit/integration test without a real tailnet-reachable peer
  does not prove the design

This is a useful finding: the spike should be validated against a real
tailnet target, not a local server pretending to be one.

### 3. Real tailnet validation works for basic request execution

The existing Headscale E2E harness was used to validate the same spike
against a real peer service on the tailnet.

Against a real peer:

- GET succeeded
- POST with a request body succeeded
- a redirecting endpoint returned the redirected response body

That confirms the core architecture:

- Dart can describe the request
- Go can execute it through `srv.HTTPClient()`
- the response can be returned through the spike channel

One nuance surfaced in the buffered spike shape: `finalUrl` reporting is
not yet trustworthy enough to treat as a validated contract. The spike
confirmed redirect **behavior**, but not a final canonical response
metadata shape for redirects.

### 4. Buffered round-trip is viable, but incomplete

The current spike is fully buffered. It does **not** validate:

- streaming request bodies
- streaming response bodies
- end-to-end cancellation
- backpressure between Dart and Go

So this spike is enough to validate the control shape and real-tailnet
execution path, but **not** the full production HTTP lane.

## Conclusion

The preferred architecture still looks right:

- Go-backed HTTP lane
- separate from the raw substrate
- standard `http.Client` surface in Dart

The spike now supports that direction with real-tailnet evidence, and it
also showed that localhost-only testing is not sufficient for
`srv.HTTPClient()`.

## Next step

1. replace the proxy client with a Go-backed `http.BaseClient` behind
   the existing public surface
2. validate response streaming
3. decide whether cancellation is part of the first implementation or a
   follow-up
