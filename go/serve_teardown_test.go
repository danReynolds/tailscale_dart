//go:build !windows

package tailscale

import (
	"sync"
	"testing"
)

// TestServeStoppingGuard covers the F2 release-blocker: an offloaded
// ServeForward racing Stop could persist a serve mount that survives down() and
// re-activates (re-exposing a service) on the next up(). The guard makes any
// ServeForward that arrives once teardown began refuse instead of persisting.
func TestServeStoppingGuard(t *testing.T) {
	clearServeStopping()

	// Teardown arms the guard even with no live client and no publications, so a
	// ServeForward racing the stop is refused rather than persisting a mount.
	closeAllServePublications(nil)
	serveConfigMu.Lock()
	armed := serveStopping
	serveConfigMu.Unlock()
	if !armed {
		t.Fatal("closeAllServePublications must set serveStopping so a racing ServeForward is refused")
	}

	// A fresh Start re-arms serve publishing.
	clearServeStopping()
	serveConfigMu.Lock()
	cleared := !serveStopping
	serveConfigMu.Unlock()
	if !cleared {
		t.Fatal("clearServeStopping must clear the guard")
	}
}

// TestServeStoppingGuardConcurrent runs the set (teardown) and clear (start)
// paths concurrently; -race verifies serveStopping is always accessed under
// serveConfigMu, the same lock ServeForward's check-and-track holds.
func TestServeStoppingGuardConcurrent(t *testing.T) {
	clearServeStopping()
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(2)
		go func() { defer wg.Done(); closeAllServePublications(nil) }()
		go func() { defer wg.Done(); clearServeStopping() }()
	}
	wg.Wait()
	clearServeStopping()
}
