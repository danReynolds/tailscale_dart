//go:build !windows

package tailscale

import (
	"testing"
)

// The serve teardown race (an offloaded ServeForward persisting a mount behind
// closeAllServePublications' sweep, re-exposing the service on the next Start)
// is guarded by the node epoch: ServeForward re-checks its nodeGate under
// serveConfigMu — the same lock the sweep holds — at its commit point. The gate
// mechanism itself is covered in node_gate_test.go; these tests cover the
// serve-specific sweep bookkeeping that pairs with it.

// TestServePublicationSweepTakesAllKeys: the teardown sweep must atomically
// drain the publication registry (take-inside-lock), so a forward that
// committed before the sweep is always included in it.
func TestServePublicationSweepTakesAllKeys(t *testing.T) {
	k1 := servePublicationKey{host: "a.ts.net", port: 443, path: "/x"}
	k2 := servePublicationKey{host: "a.ts.net", port: 8443, path: "/y"}
	trackServePublication(k1)
	trackServePublication(k2)

	// nil client: the sweep still drains the registry even when there is no
	// LocalAPI to push the removal to (the node is gone with its config).
	closeAllServePublications(nil)

	servePublicationMu.Lock()
	remaining := len(servePublications)
	servePublicationMu.Unlock()
	if remaining != 0 {
		t.Fatalf("sweep must drain every tracked publication, %d left", remaining)
	}
}

// TestTakeServePublicationsEmptiesRegistry locks in take semantics: the taken
// snapshot owns the keys and the registry restarts empty.
func TestTakeServePublicationsEmptiesRegistry(t *testing.T) {
	key := servePublicationKey{host: "b.ts.net", port: 443, path: "/z"}
	trackServePublication(key)
	keys := takeServePublications()
	found := false
	for _, k := range keys {
		if k == key {
			found = true
		}
	}
	if !found {
		t.Fatal("take must return the tracked key")
	}
	if again := takeServePublications(); len(again) != 0 {
		t.Fatalf("second take must be empty, got %d keys", len(again))
	}
}
