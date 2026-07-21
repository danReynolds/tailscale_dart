package tailscale

import (
	"net"
	"net/http"
	"testing"
	"time"
)

// TestReapFunnelForwarder_RemovesStaleEntry is the core of the teardown-race
// fix: a forwarder whose listener died must be dropped from the registry, so a
// later same-port forward can't attach a mount to a dead listener.
func TestReapFunnelForwarder_RemovesStaleEntry(t *testing.T) {
	const port uint16 = 18443
	ff := &funnelForwarder{
		port:    port,
		domain:  "node.ts.net",
		targets: map[string]funnelTarget{"/": {}},
		server:  &http.Server{},
	}
	funnelMu.Lock()
	funnelForwarders[port] = ff
	funnelMu.Unlock()
	t.Cleanup(func() {
		funnelMu.Lock()
		delete(funnelForwarders, port)
		funnelMu.Unlock()
	})

	reapFunnelForwarder(port, ff)

	funnelMu.Lock()
	_, present := funnelForwarders[port]
	funnelMu.Unlock()
	if present {
		t.Fatal("stale forwarder was not removed from the registry")
	}
}

// TestReapFunnelForwarder_LeavesReclaimedPort guards that a late self-heal from
// an old forwarder never evicts a newer forwarder that has taken the same port.
func TestReapFunnelForwarder_LeavesReclaimedPort(t *testing.T) {
	const port uint16 = 18444
	stale := &funnelForwarder{port: port, server: &http.Server{}}
	current := &funnelForwarder{port: port, domain: "node.ts.net", server: &http.Server{}}
	funnelMu.Lock()
	funnelForwarders[port] = current
	funnelMu.Unlock()
	t.Cleanup(func() {
		funnelMu.Lock()
		delete(funnelForwarders, port)
		funnelMu.Unlock()
	})

	reapFunnelForwarder(port, stale) // reaping the OLD one

	funnelMu.Lock()
	got := funnelForwarders[port]
	funnelMu.Unlock()
	if got != current {
		t.Fatal("reaping a stale forwarder evicted the current one that reclaimed the port")
	}
}

// TestFunnelForwarder_SelfHealsWhenListenerCloses exercises the production
// Serve-goroutine wiring against a REAL listener (no tailnet): when the
// listener closes, Serve returns and the forwarder reaps itself from the
// registry.
func TestFunnelForwarder_SelfHealsWhenListenerCloses(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	const port uint16 = 18445
	ff := &funnelForwarder{
		port:     port,
		domain:   "node.ts.net",
		targets:  map[string]funnelTarget{},
		server:   &http.Server{},
		listener: ln,
	}
	funnelMu.Lock()
	funnelForwarders[port] = ff
	funnelMu.Unlock()
	t.Cleanup(func() {
		funnelMu.Lock()
		delete(funnelForwarders, port)
		funnelMu.Unlock()
	})

	// Same wiring as startFunnelForward's install goroutine.
	go func() {
		_ = ff.server.Serve(ln)
		reapFunnelForwarder(port, ff)
	}()

	_ = ln.Close() // Serve returns → self-heal

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		funnelMu.Lock()
		_, present := funnelForwarders[port]
		funnelMu.Unlock()
		if !present {
			return // self-healed
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("forwarder did not self-heal after its listener closed")
}
