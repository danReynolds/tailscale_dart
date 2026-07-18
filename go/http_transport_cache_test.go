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

// TestHttpTransportCache_ReusesWithinSameOwner is the win: successive requests
// under the same identity share one connection (one dial).
func TestHttpTransportCache_ReusesWithinSameOwner(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()

	var dials atomic.Int64
	var cache httpTransportCache
	owner := new(int) // stands in for a *tsnet.Server identity

	for i := 0; i < 3; i++ {
		getOK(t, cache.get(owner, func() *http.Transport { return countingTransport(&dials) }), server.URL)
	}
	if got := dials.Load(); got != 1 {
		t.Fatalf("same-identity requests should reuse one connection: got %d dials, want 1", got)
	}
}

// TestHttpTransportCache_NoReuseAcrossIdentityChange is the load-bearing
// security boundary: after the owner (identity) changes, a request must NOT be
// served by the previous identity's pooled connection — it must dial fresh.
func TestHttpTransportCache_NoReuseAcrossIdentityChange(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()

	var dials atomic.Int64
	var cache httpTransportCache
	identityA := new(int)
	identityB := new(int)

	// Warm identity A's pool.
	getOK(t, cache.get(identityA, func() *http.Transport { return countingTransport(&dials) }), server.URL)
	getOK(t, cache.get(identityA, func() *http.Transport { return countingTransport(&dials) }), server.URL)
	if got := dials.Load(); got != 1 {
		t.Fatalf("identity A should have reused: got %d dials, want 1", got)
	}

	// Switch identity. The prior connection must not be reused.
	getOK(t, cache.get(identityB, func() *http.Transport { return countingTransport(&dials) }), server.URL)
	if got := dials.Load(); got != 2 {
		t.Fatalf("identity change must force a fresh connection (not reuse A's): got %d dials, want 2", got)
	}

	// And identity B keeps its own reusable pool.
	getOK(t, cache.get(identityB, func() *http.Transport { return countingTransport(&dials) }), server.URL)
	if got := dials.Load(); got != 2 {
		t.Fatalf("identity B should reuse its own connection: got %d dials, want 2", got)
	}
}

// TestHttpTransportCache_ResetForcesFreshConnection covers node teardown: after
// reset() (called from stopLocked), the next request must dial anew.
func TestHttpTransportCache_ResetForcesFreshConnection(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()

	var dials atomic.Int64
	var cache httpTransportCache
	owner := new(int)

	getOK(t, cache.get(owner, func() *http.Transport { return countingTransport(&dials) }), server.URL)
	getOK(t, cache.get(owner, func() *http.Transport { return countingTransport(&dials) }), server.URL)
	if got := dials.Load(); got != 1 {
		t.Fatalf("pre-reset reuse: got %d dials, want 1", got)
	}

	cache.reset() // node stopped

	// Even with the same owner value, a fresh transport must be built.
	getOK(t, cache.get(owner, func() *http.Transport { return countingTransport(&dials) }), server.URL)
	if got := dials.Load(); got != 2 {
		t.Fatalf("post-reset request must dial fresh: got %d dials, want 2", got)
	}
}

// TestHttpTransportCache_CrossHostIsolation confirms a pooled connection to one
// host is never handed to a request for a different host.
func TestHttpTransportCache_CrossHostIsolation(t *testing.T) {
	hostA := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("a"))
	}))
	defer hostA.Close()
	hostB := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("b"))
	}))
	defer hostB.Close()

	var dials atomic.Int64
	var cache httpTransportCache
	owner := new(int)
	build := func() *http.Transport { return countingTransport(&dials) }

	// Same identity, two different hosts: two separate connections.
	getOK(t, cache.get(owner, build), hostA.URL)
	getOK(t, cache.get(owner, build), hostB.URL)
	if got := dials.Load(); got != 2 {
		t.Fatalf("distinct hosts must use distinct connections: got %d dials, want 2", got)
	}
	// Re-hitting each host reuses its own connection (no extra dials).
	getOK(t, cache.get(owner, build), hostA.URL)
	getOK(t, cache.get(owner, build), hostB.URL)
	if got := dials.Load(); got != 2 {
		t.Fatalf("per-host reuse: got %d dials, want 2", got)
	}
}
