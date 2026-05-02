package tailscale

import (
	"net/http/httputil"
	"net/url"
	"testing"
)

func TestFunnelForwarderMatchUsesLongestServePath(t *testing.T) {
	rootURL := mustParseURL(t, "http://127.0.0.1:3000")
	apiURL := mustParseURL(t, "http://127.0.0.1:3001")
	ff := &funnelForwarder{
		targets: map[string]funnelTarget{
			"/":    {localPort: 3000, proxy: httputil.NewSingleHostReverseProxy(rootURL)},
			"/api": {localPort: 3001, proxy: httputil.NewSingleHostReverseProxy(apiURL)},
		},
	}

	target, ok := ff.match("/api/users")
	if !ok {
		t.Fatal("match returned no target")
	}
	if target.localPort != 3001 {
		t.Fatalf("localPort = %d, want 3001", target.localPort)
	}

	target, ok = ff.match("/other")
	if !ok {
		t.Fatal("root match returned no target")
	}
	if target.localPort != 3000 {
		t.Fatalf("localPort = %d, want 3000", target.localPort)
	}
}

func TestFunnelPublicationRegistryTracksProcessOwnedMappings(t *testing.T) {
	resetFunnelPublicationRegistryForTest(t)

	key := servePublicationKey{
		host: "demo.tailnet.ts.net",
		port: 443,
		path: "/",
	}
	trackFunnelPublication(key)
	keys := takeFunnelPublications()
	if len(keys) != 1 || keys[0] != key {
		t.Fatalf("keys = %+v, want [%+v]", keys, key)
	}
	if keys := takeFunnelPublications(); len(keys) != 0 {
		t.Fatalf("registry was not drained: %+v", keys)
	}
}

func mustParseURL(t *testing.T, raw string) *url.URL {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return u
}

func resetFunnelPublicationRegistryForTest(t *testing.T) {
	t.Helper()
	funnelPublicationMu.Lock()
	funnelPublications = map[servePublicationKey]struct{}{}
	funnelPublicationMu.Unlock()
	t.Cleanup(func() {
		funnelPublicationMu.Lock()
		funnelPublications = map[servePublicationKey]struct{}{}
		funnelPublicationMu.Unlock()
	})
}
