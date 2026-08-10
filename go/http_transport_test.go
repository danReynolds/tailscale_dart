//go:build !windows

package tailscale

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"tailscale.com/tsnet"
)

// countingTransport builds an *http.Transport whose dials are counted, so tests
// can assert exactly when a new tailnet connection would be established.
func countingTransport(dials *atomic.Int64) *http.Transport {
	return &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			dials.Add(1)
			return (&net.Dialer{}).DialContext(ctx, network, addr)
		},
	}
}

func getOK(t *testing.T, tr *http.Transport, url string) {
	t.Helper()
	resp, err := (&http.Client{Transport: tr}).Get(url)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
}

func transportRuntime() *nodeRuntime {
	return newNodeRuntime(nodeEpoch.Load(), nextDirectRuntimeToken(), runtimeConfig{})
}

// TestRuntimeTransport_ReusesWithinSameRuntime is the win: successive requests
// under the same identity share one connection (one dial).
func TestRuntimeTransport_ReusesWithinSameRuntime(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()

	var dials atomic.Int64
	runtime := transportRuntime()
	t.Cleanup(runtime.cancel)

	for i := 0; i < 3; i++ {
		tr, oneOff := runtime.tailnetTransport(func() *http.Transport { return countingTransport(&dials) })
		if oneOff {
			t.Fatal("a live runtime's transport must not be reported one-off")
		}
		getOK(t, tr, server.URL)
	}
	if got := dials.Load(); got != 1 {
		t.Fatalf("same-identity requests should reuse one connection: got %d dials, want 1", got)
	}
}

// TestRuntimeTransport_NoReuseAcrossIdentityChange is the load-bearing security
// boundary: an identity change is a new runtime with its own empty slot, so a
// request after the change must NOT be served by the previous identity's
// pooled connection — it must dial fresh.
func TestRuntimeTransport_NoReuseAcrossIdentityChange(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()

	var dials atomic.Int64
	build := func() *http.Transport { return countingTransport(&dials) }
	runtimeA := transportRuntime()
	t.Cleanup(runtimeA.cancel)
	runtimeB := transportRuntime()
	t.Cleanup(runtimeB.cancel)

	// Warm identity A's pool.
	for i := 0; i < 2; i++ {
		tr, _ := runtimeA.tailnetTransport(build)
		getOK(t, tr, server.URL)
	}
	if got := dials.Load(); got != 1 {
		t.Fatalf("identity A should have reused: got %d dials, want 1", got)
	}

	// Identity A ends; its pool drains with it.
	runtimeA.closeTailnetTransport()

	// The replacement identity has its own slot and must dial fresh.
	trB, oneOff := runtimeB.tailnetTransport(build)
	if oneOff {
		t.Fatal("the replacement runtime's transport must not be one-off")
	}
	getOK(t, trB, server.URL)
	if got := dials.Load(); got != 2 {
		t.Fatalf("identity change must force a fresh connection (not reuse A's): got %d dials, want 2", got)
	}

	// And identity B keeps its own reusable pool.
	trB2, _ := runtimeB.tailnetTransport(build)
	getOK(t, trB2, server.URL)
	if got := dials.Load(); got != 2 {
		t.Fatalf("identity B should reuse its own connection: got %d dials, want 2", got)
	}
}

// TestRuntimeTransport_CloseForcesOneOff covers node teardown: after
// closeTailnetTransport (called from nodeRuntime.close), a straggling request
// gets a one-off transport and must not repopulate the closed slot — an entry
// there would retain the dead server's netstack graph behind the sweep.
func TestRuntimeTransport_CloseForcesOneOff(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()

	var dials atomic.Int64
	build := func() *http.Transport { return countingTransport(&dials) }
	runtime := transportRuntime()
	t.Cleanup(runtime.cancel)

	tr, _ := runtime.tailnetTransport(build)
	getOK(t, tr, server.URL)
	getOK(t, tr, server.URL)
	if got := dials.Load(); got != 1 {
		t.Fatalf("pre-close reuse: got %d dials, want 1", got)
	}

	runtime.closeTailnetTransport() // node stopped

	late, oneOff := runtime.tailnetTransport(build)
	if !oneOff {
		t.Fatal("a closed runtime's transport must be reported one-off so the caller closes its idle conns")
	}
	getOK(t, late, server.URL)
	late.CloseIdleConnections()
	if got := dials.Load(); got != 2 {
		t.Fatalf("post-close request must dial fresh: got %d dials, want 2", got)
	}

	runtime.httpMu.Lock()
	repopulated := runtime.httpTransport != nil
	runtime.httpMu.Unlock()
	if repopulated {
		t.Fatal("a straggler must not repopulate a closed transport slot")
	}
}

// TestRuntimeTransport_CrossHostIsolation confirms a pooled connection to one
// host is never handed to a request for a different host.
func TestRuntimeTransport_CrossHostIsolation(t *testing.T) {
	hostA := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("a"))
	}))
	defer hostA.Close()
	hostB := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("b"))
	}))
	defer hostB.Close()

	var dials atomic.Int64
	runtime := transportRuntime()
	t.Cleanup(runtime.cancel)
	transport := func() *http.Transport {
		tr, _ := runtime.tailnetTransport(func() *http.Transport { return countingTransport(&dials) })
		return tr
	}

	// Same identity, two different hosts: two separate connections.
	getOK(t, transport(), hostA.URL)
	getOK(t, transport(), hostB.URL)
	if got := dials.Load(); got != 2 {
		t.Fatalf("distinct hosts must use distinct connections: got %d dials, want 2", got)
	}
	// Re-hitting each host reuses its own connection (no extra dials).
	getOK(t, transport(), hostA.URL)
	getOK(t, transport(), hostB.URL)
	if got := dials.Load(); got != 2 {
		t.Fatalf("per-host reuse: got %d dials, want 2", got)
	}
}

// TestSharedTailnetTransport_CachesForLiveGate: a request under the live
// lifecycle populates the runtime's slot, and a second request reuses it (no
// rebuild).
func TestSharedTailnetTransport_CachesForLiveGate(t *testing.T) {
	withLiveServer(t, &tsnet.Server{})
	gate := liveGate(t)
	builds := 0
	build := func() *http.Transport { builds++; return &http.Transport{} }

	first, oneOff1 := gate.runtime.tailnetTransport(build)
	second, oneOff2 := gate.runtime.tailnetTransport(build)
	if first == nil || first != second {
		t.Fatalf("a live runtime must cache and reuse one transport (builds=%d)", builds)
	}
	if oneOff1 || oneOff2 {
		t.Fatal("live transports must not be reported one-off")
	}
	if builds != 1 {
		t.Fatalf("expected exactly one build for repeated live requests, got %d", builds)
	}
}
