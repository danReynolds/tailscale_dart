package tailscale

import (
	"net/http"
	"net/http/httptest"
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

func TestFunnelForwarderStripsSpoofedIdentityHeaders(t *testing.T) {
	var gotLogin, gotProto, gotReservedTS, gotKept string
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotLogin = r.Header.Get("Tailscale-User-Login")
		gotReservedTS = r.Header.Get("Tailscale-Anything")
		gotProto = r.Header.Get("X-Forwarded-Proto")
		gotKept = r.Header.Get("X-App-Header")
		w.WriteHeader(http.StatusOK)
	}))
	defer backend.Close()

	ff := &funnelForwarder{
		targets: map[string]funnelTarget{
			"/": {proxy: httputil.NewSingleHostReverseProxy(mustParseURL(t, backend.URL))},
		},
	}

	// Simulate a public Funnel client trying to spoof Tailscale-injected
	// identity headers, plus a benign app header that must pass through.
	req := httptest.NewRequest(http.MethodGet, "http://demo.tailnet.ts.net/", nil)
	req.Header.Set("Tailscale-User-Login", "admin@evil.example")
	req.Header.Set("Tailscale-Anything", "spoofed")
	req.Header.Set("X-App-Header", "ok")
	rec := httptest.NewRecorder()

	ff.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if gotLogin != "" {
		t.Errorf("backend saw spoofed Tailscale-User-Login = %q, want it stripped", gotLogin)
	}
	if gotReservedTS != "" {
		t.Errorf("backend saw spoofed Tailscale-Anything = %q, want it stripped", gotReservedTS)
	}
	if gotProto != "https" {
		t.Errorf("X-Forwarded-Proto = %q, want \"https\"", gotProto)
	}
	if gotKept != "ok" {
		t.Errorf("benign X-App-Header = %q, want \"ok\" (must not be stripped)", gotKept)
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
