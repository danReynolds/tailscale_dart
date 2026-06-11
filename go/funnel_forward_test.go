package tailscale

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

func TestFunnelForwarderMatchUsesLongestServePath(t *testing.T) {
	rootURL := mustParseURL(t, "http://127.0.0.1:3000")
	apiURL := mustParseURL(t, "http://127.0.0.1:3001")
	ff := &funnelForwarder{
		targets: map[string]funnelTarget{
			"/":    {localPort: 3000, proxy: newFunnelReverseProxy(rootURL)},
			"/api": {localPort: 3001, proxy: newFunnelReverseProxy(apiURL)},
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

func TestFunnelForwarderStripsSpoofedIdentityAndProxyHeaders(t *testing.T) {
	var (
		gotForwarded            string
		gotForwardedFor         string
		gotForwardedHost        string
		gotForwardedPort        string
		gotForwardedProto       string
		gotForwardedSSL         string
		gotHost                 string
		gotKept                 string
		gotLogin                string
		gotOriginalForwardedFor string
		gotRealIP               string
		gotReservedTS           string
	)
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotForwarded = r.Header.Get("Forwarded")
		gotForwardedFor = r.Header.Get("X-Forwarded-For")
		gotForwardedHost = r.Header.Get("X-Forwarded-Host")
		gotForwardedPort = r.Header.Get("X-Forwarded-Port")
		gotForwardedProto = r.Header.Get("X-Forwarded-Proto")
		gotForwardedSSL = r.Header.Get("X-Forwarded-Ssl")
		gotHost = r.Host
		gotKept = r.Header.Get("X-App-Header")
		gotLogin = r.Header.Get("Tailscale-User-Login")
		gotOriginalForwardedFor = r.Header.Get("X-Original-Forwarded-For")
		gotRealIP = r.Header.Get("X-Real-IP")
		gotReservedTS = r.Header.Get("Tailscale-Anything")
		w.WriteHeader(http.StatusOK)
	}))
	defer backend.Close()

	ff := &funnelForwarder{
		targets: map[string]funnelTarget{
			"/": {proxy: newFunnelReverseProxy(mustParseURL(t, backend.URL))},
		},
	}

	// Simulate a public Funnel client trying to spoof Tailscale-injected
	// identity/proxy headers, plus a benign app header that must pass through.
	req := httptest.NewRequest(http.MethodGet, "http://demo.tailnet.ts.net/", nil)
	req.RemoteAddr = "203.0.113.9:54321"
	req.Host = "demo.tailnet.ts.net"
	req.Header.Set("Forwarded", "for=10.0.0.1;proto=http;host=evil.example")
	req.Header.Set("Tailscale-User-Login", "admin@evil.example")
	req.Header.Set("Tailscale-Anything", "spoofed")
	req.Header.Set("X-App-Header", "ok")
	req.Header.Set("X-Forwarded-For", "10.0.0.1")
	req.Header.Set("X-Forwarded-Host", "evil.example")
	req.Header.Set("X-Forwarded-Port", "12345")
	req.Header.Set("X-Forwarded-Proto", "http")
	req.Header.Set("X-Forwarded-Ssl", "off")
	req.Header.Set("X-Original-Forwarded-For", "10.0.0.2")
	req.Header.Set("X-Real-IP", "10.0.0.3")
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
	if gotForwarded != "" {
		t.Errorf("Forwarded = %q, want stripped", gotForwarded)
	}
	if gotForwardedFor != "203.0.113.9" {
		t.Errorf("X-Forwarded-For = %q, want client IP only", gotForwardedFor)
	}
	if gotForwardedHost != "demo.tailnet.ts.net" {
		t.Errorf("X-Forwarded-Host = %q, want original host", gotForwardedHost)
	}
	if gotForwardedPort != "" {
		t.Errorf("X-Forwarded-Port = %q, want stripped", gotForwardedPort)
	}
	if gotForwardedProto != "https" {
		t.Errorf("X-Forwarded-Proto = %q, want \"https\"", gotForwardedProto)
	}
	if gotForwardedSSL != "" {
		t.Errorf("X-Forwarded-Ssl = %q, want stripped", gotForwardedSSL)
	}
	if gotOriginalForwardedFor != "" {
		t.Errorf("X-Original-Forwarded-For = %q, want stripped", gotOriginalForwardedFor)
	}
	if gotRealIP != "" {
		t.Errorf("X-Real-IP = %q, want stripped", gotRealIP)
	}
	if gotHost != "demo.tailnet.ts.net" {
		t.Errorf("Host = %q, want original host", gotHost)
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
