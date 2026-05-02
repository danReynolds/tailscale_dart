package tailscale

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"strings"
	"testing"

	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/types/opt"
)

func TestPeerStatusAddrMatchesHostAndDNSName(t *testing.T) {
	peer := &ipnstate.PeerStatus{
		HostName:     "peer-1",
		DNSName:      "peer-1.tailnet.ts.net.",
		TailscaleIPs: []netip.Addr{netip.MustParseAddr("fd7a:115c:a1e0::1"), netip.MustParseAddr("100.64.0.2")},
	}

	for _, target := range []string{"peer-1", "peer-1.tailnet.ts.net"} {
		addr, ok := peerStatusAddr(peer, target)
		if !ok {
			t.Fatalf("peerStatusAddr(%q) did not match", target)
		}
		if got, want := addr.String(), "100.64.0.2"; got != want {
			t.Fatalf("peerStatusAddr(%q) = %s, want %s", target, got, want)
		}
	}
}

func TestPingPathUnknownWhenRouteMetadataMissing(t *testing.T) {
	pr := &ipnstate.PingResult{}
	if got := pingPath(pr); got != "unknown" {
		t.Fatalf("pingPath(empty) = %q, want unknown", got)
	}
}

func TestPingPathDerp(t *testing.T) {
	pr := &ipnstate.PingResult{
		DERPRegionID:   1,
		DERPRegionCode: "nyc",
	}
	if got := pingPath(pr); got != "derp" {
		t.Fatalf("pingPath(derp) = %q, want derp", got)
	}
}

func TestPingPathDirect(t *testing.T) {
	pr := &ipnstate.PingResult{Endpoint: "100.64.0.2:41641"}
	if got := pingPath(pr); got != "direct" {
		t.Fatalf("pingPath(direct) = %q, want direct", got)
	}
}

// fakeHTTPErr stands in for apitype.HTTPErr so we can exercise the
// errors.As path in classifyLocalAPIError without pulling the real
// upstream type (which moves between releases).
type fakeHTTPErr struct {
	status int
	msg    string
}

func (e fakeHTTPErr) Error() string { return e.msg }
func (e fakeHTTPErr) Status() int   { return e.status }

func TestClassifyLocalAPIError_HTTPStatusCodes(t *testing.T) {
	cases := []struct {
		name   string
		status int
		want   string
	}{
		{"404 → notFound", http.StatusNotFound, "notFound"},
		{"403 → forbidden", http.StatusForbidden, "forbidden"},
		{"409 → conflict", http.StatusConflict, "conflict"},
		{"412 → preconditionFailed", http.StatusPreconditionFailed, "preconditionFailed"},
		{"500 → unclassified", http.StatusInternalServerError, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := fakeHTTPErr{status: tc.status, msg: fmt.Sprintf("%d", tc.status)}
			code, status := classifyLocalAPIError(err)
			if code != tc.want {
				t.Errorf("code = %q, want %q", code, tc.want)
			}
			if status != tc.status {
				t.Errorf("status = %d, want %d", status, tc.status)
			}
		})
	}
}

func TestClassifyLocalAPIError_FeatureDisabledFromMessage(t *testing.T) {
	cases := []string{
		"Taildrop is disabled",
		"funnel not enabled for this node",
		"MagicDNS is disabled by operator",
		"tsnet: you must enable HTTPS in the admin panel to proceed",
		"Funnel not available; HTTPS must be enabled",
		"node has no funnel attribute",
	}
	for _, msg := range cases {
		t.Run(msg, func(t *testing.T) {
			code, _ := classifyLocalAPIError(errors.New(msg))
			if code != "featureDisabled" {
				t.Errorf("code = %q, want %q", code, "featureDisabled")
			}
		})
	}
}

func TestClassifyLocalAPIError_UnknownError(t *testing.T) {
	code, status := classifyLocalAPIError(errors.New("some other failure"))
	if code != "" {
		t.Errorf("code = %q, want empty for unknown", code)
	}
	if status != 0 {
		t.Errorf("status = %d, want 0 for non-HTTP error", status)
	}
}

func TestClassifyLocalAPIError_FunnelPortPolicy(t *testing.T) {
	code, _ := classifyLocalAPIError(errors.New("port 80 is not allowed for funnel"))
	if code != "forbidden" {
		t.Errorf("code = %q, want forbidden", code)
	}
}

func TestClassifyLocalAPIError_HTTPStatusBeatsMessageMatch(t *testing.T) {
	// An HTTP 404 with a message that would otherwise match
	// "featureDisabled" should classify as notFound — HTTP status is
	// the stronger signal.
	err := fakeHTTPErr{status: http.StatusNotFound, msg: "feature is disabled"}
	code, _ := classifyLocalAPIError(err)
	if code != "notFound" {
		t.Errorf("code = %q, want notFound (status trumps message)", code)
	}
}

func TestLocalAPIError_JSONShape(t *testing.T) {
	err := fakeHTTPErr{status: http.StatusForbidden, msg: "acl denied"}
	out := localAPIError(err)
	var parsed map[string]any
	if jerr := json.Unmarshal([]byte(out), &parsed); jerr != nil {
		t.Fatalf("invalid JSON: %v; payload=%q", jerr, out)
	}
	if parsed["error"] != "acl denied" {
		t.Errorf("error field = %v, want acl denied", parsed["error"])
	}
	if parsed["code"] != "forbidden" {
		t.Errorf("code field = %v, want forbidden", parsed["code"])
	}
	// Numbers come back as float64 from JSON unmarshal.
	if got, ok := parsed["statusCode"].(float64); !ok || int(got) != 403 {
		t.Errorf("statusCode field = %v (%T), want 403", parsed["statusCode"], parsed["statusCode"])
	}
}

func TestLocalAPIError_OmitsCodeWhenUnclassified(t *testing.T) {
	out := localAPIError(errors.New("mystery"))
	var parsed map[string]any
	if jerr := json.Unmarshal([]byte(out), &parsed); jerr != nil {
		t.Fatalf("invalid JSON: %v", jerr)
	}
	if _, ok := parsed["code"]; ok {
		t.Errorf("unexpected code field in %q", out)
	}
	if _, ok := parsed["statusCode"]; ok {
		t.Errorf("unexpected statusCode field in %q", out)
	}
	// error is still present.
	if parsed["error"] != "mystery" {
		t.Errorf("error field = %v, want mystery", parsed["error"])
	}
}

func TestIsNotFound_StringFallback(t *testing.T) {
	// Errors from older upstream versions that don't implement
	// Status() still flag via the "404" substring fallback.
	if !isNotFound(errors.New("whois returned 404")) {
		t.Error("expected fallback string match for '404'")
	}
	if !isNotFound(errors.New("peer not found")) {
		t.Error("expected fallback string match for 'not found'")
	}
	if isNotFound(errors.New("unrelated error")) {
		t.Error("non-404 error should not match")
	}
}

func TestPrefsToJSONShape(t *testing.T) {
	prefs := &ipn.Prefs{
		RouteAll:      true,
		ShieldsUp:     true,
		AdvertiseTags: []string{"tag:server"},
		WantRunning:   true,
		Hostname:      "router",
		ExitNodeID:    "n123",
		AutoExitNode:  ipn.AnyExitNode,
		AdvertiseRoutes: []netip.Prefix{
			netip.MustParsePrefix("10.0.0.0/24"),
		},
		AutoUpdate: ipn.AutoUpdatePrefs{
			Check: true,
			Apply: opt.NewBool(true),
		},
	}

	var parsed map[string]any
	if err := json.Unmarshal([]byte(prefsToJSON(prefs)), &parsed); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got := parsed["acceptRoutes"]; got != true {
		t.Errorf("acceptRoutes = %v, want true", got)
	}
	if got := parsed["autoUpdate"]; got != true {
		t.Errorf("autoUpdate = %v, want true", got)
	}
	if got := parsed["autoExitNode"]; got != true {
		t.Errorf("autoExitNode = %v, want true", got)
	}
	if got := parsed["exitNodeId"]; got != "n123" {
		t.Errorf("exitNodeId = %v, want n123", got)
	}
}

func TestMaskedPrefsFromPayload(t *testing.T) {
	acceptRoutes := true
	shieldsUp := false
	autoUpdate := true
	hostname := " router "
	exitNodeID := " n123 "
	routes := []string{"10.0.0.7/24"}
	tags := []string{"tag:server"}

	masked, err := maskedPrefsFromPayload(prefsUpdatePayload{
		AdvertisedRoutes: &routes,
		AcceptRoutes:     &acceptRoutes,
		ShieldsUp:        &shieldsUp,
		AdvertisedTags:   &tags,
		AutoUpdate:       &autoUpdate,
		Hostname:         &hostname,
		ExitNodeID:       &exitNodeID,
	})
	if err != nil {
		t.Fatalf("maskedPrefsFromPayload: %v", err)
	}

	if !masked.AdvertiseRoutesSet || masked.AdvertiseRoutes[0].String() != "10.0.0.0/24" {
		t.Fatalf("AdvertiseRoutes = %v, set=%v", masked.AdvertiseRoutes, masked.AdvertiseRoutesSet)
	}
	if !masked.RouteAllSet || !masked.RouteAll {
		t.Fatalf("RouteAll = %v, set=%v", masked.RouteAll, masked.RouteAllSet)
	}
	if !masked.ShieldsUpSet || masked.ShieldsUp {
		t.Fatalf("ShieldsUp = %v, set=%v", masked.ShieldsUp, masked.ShieldsUpSet)
	}
	if !masked.AdvertiseTagsSet || len(masked.AdvertiseTags) != 1 || masked.AdvertiseTags[0] != "tag:server" {
		t.Fatalf("AdvertiseTags = %v, set=%v", masked.AdvertiseTags, masked.AdvertiseTagsSet)
	}
	if !masked.AutoUpdateSet.CheckSet || !masked.AutoUpdateSet.ApplySet || !masked.AutoUpdate.Check {
		t.Fatalf("AutoUpdate = %+v, set=%+v", masked.AutoUpdate, masked.AutoUpdateSet)
	}
	if apply, ok := masked.AutoUpdate.Apply.Get(); !ok || !apply {
		t.Fatalf("AutoUpdate.Apply = %v/%v, want true/true", apply, ok)
	}
	if !masked.HostnameSet || masked.Hostname != "router" {
		t.Fatalf("Hostname = %q, set=%v", masked.Hostname, masked.HostnameSet)
	}
	if !masked.ExitNodeIDSet || !masked.ExitNodeIPSet || !masked.AutoExitNodeSet || string(masked.ExitNodeID) != "n123" {
		t.Fatalf("Exit node fields: id=%q idSet=%v ipSet=%v autoSet=%v", masked.ExitNodeID, masked.ExitNodeIDSet, masked.ExitNodeIPSet, masked.AutoExitNodeSet)
	}
}

func TestMaskedPrefsFromPayloadRejectsBadCIDR(t *testing.T) {
	routes := []string{"not-a-cidr"}
	if _, err := maskedPrefsFromPayload(prefsUpdatePayload{
		AdvertisedRoutes: &routes,
	}); err == nil {
		t.Fatal("expected invalid CIDR error")
	}
}

func TestPrefsUpdateRejectsTrailingJSON(t *testing.T) {
	result := PrefsUpdate(`{"shieldsUp":true} {"acceptRoutes":true}`)
	var decoded map[string]string
	if err := json.Unmarshal([]byte(result), &decoded); err != nil {
		t.Fatalf("PrefsUpdate returned invalid JSON: %v", err)
	}
	if !strings.Contains(decoded["error"], "invalid prefs update JSON") {
		t.Fatalf("PrefsUpdate error = %q, want invalid prefs JSON error", decoded["error"])
	}
}

func TestApplyServeForwardHTTP(t *testing.T) {
	sc := new(ipn.ServeConfig)
	pub, err := applyServeForward(sc, serveTestStatus(), serveForwardPayload{
		TailnetPort:  80,
		LocalAddress: "127.0.0.1",
		LocalPort:    3000,
		Path:         "/api",
		HTTPS:        false,
		Funnel:       false,
	})
	if err != nil {
		t.Fatalf("applyServeForward: %v", err)
	}

	if pub.URL != "http://demo.tailnet.ts.net/api" {
		t.Fatalf("URL = %q, want http://demo.tailnet.ts.net/api", pub.URL)
	}
	if pub.Port != 80 || pub.LocalPort != 3000 || pub.Path != "/api" || pub.HTTPS || pub.Funnel {
		t.Fatalf("unexpected publication: %+v", pub)
	}
	if sc.TCP[80] == nil || !sc.TCP[80].HTTP || sc.TCP[80].HTTPS {
		t.Fatalf("TCP[80] = %+v, want HTTP web handler", sc.TCP[80])
	}
	hp := ipn.HostPort("demo.tailnet.ts.net:80")
	handler := sc.Web[hp].Handlers["/api"]
	if handler == nil || handler.Proxy != "http://127.0.0.1:3000" {
		t.Fatalf("handler = %+v, want local proxy", handler)
	}
}

func TestApplyServeForwardRejectsTCPConflict(t *testing.T) {
	sc := &ipn.ServeConfig{
		TCP: map[uint16]*ipn.TCPPortHandler{
			443: &ipn.TCPPortHandler{TCPForward: "127.0.0.1:22"},
		},
	}
	_, err := applyServeForward(sc, serveTestStatus(), serveForwardPayload{
		TailnetPort:  443,
		LocalAddress: "127.0.0.1",
		LocalPort:    3000,
		Path:         "/",
		HTTPS:        false,
	})
	if err == nil || !strings.Contains(err.Error(), "already serving TCP") {
		t.Fatalf("err = %v, want TCP conflict", err)
	}
}

func TestApplyServeClearRemovesLastHandlerAndFunnel(t *testing.T) {
	sc := new(ipn.ServeConfig)
	st := serveTestStatus()
	if _, err := applyServeForward(sc, st, serveForwardPayload{
		TailnetPort:  80,
		LocalAddress: "127.0.0.1",
		LocalPort:    3000,
		Path:         "/",
		HTTPS:        false,
	}); err != nil {
		t.Fatalf("applyServeForward: %v", err)
	}
	sc.SetFunnel("demo.tailnet.ts.net", 80, true)

	if err := applyServeClear(sc, st, serveClearPayload{
		TailnetPort: 80,
		Path:        "/",
	}); err != nil {
		t.Fatalf("applyServeClear: %v", err)
	}
	if sc.Web != nil || sc.TCP != nil || sc.AllowFunnel != nil {
		t.Fatalf("serve config not fully cleared: %+v", sc)
	}
}

func TestServePublicationRegistryTracksProcessOwnedMappings(t *testing.T) {
	resetServePublicationRegistryForTest(t)

	key := servePublicationKey{host: "demo.tailnet.ts.net", port: 443, path: "/"}
	trackServePublication(key)
	keys := takeServePublications()
	if len(keys) != 1 || keys[0] != key {
		t.Fatalf("keys = %+v, want [%+v]", keys, key)
	}
	if keys := takeServePublications(); len(keys) != 0 {
		t.Fatalf("registry was not drained: %+v", keys)
	}
}

func TestRemoveServeWebHandlerPreservesOtherPaths(t *testing.T) {
	sc := new(ipn.ServeConfig)
	st := serveTestStatus()
	for _, path := range []string{"/", "/api"} {
		if _, err := applyServeForward(sc, st, serveForwardPayload{
			TailnetPort:  443,
			LocalAddress: "127.0.0.1",
			LocalPort:    3000,
			Path:         path,
			HTTPS:        false,
		}); err != nil {
			t.Fatalf("applyServeForward(%q): %v", path, err)
		}
	}

	removeServeWebHandler(sc, "demo.tailnet.ts.net", 443, "/api")
	hp := ipn.HostPort("demo.tailnet.ts.net:443")
	if sc.Web == nil || sc.Web[hp] == nil || sc.Web[hp].Handlers["/"] == nil {
		t.Fatalf("root handler was removed: %+v", sc)
	}
	if _, ok := sc.Web[hp].Handlers["/api"]; ok {
		t.Fatalf("/api handler still present: %+v", sc.Web[hp].Handlers)
	}

	removeServeWebHandler(sc, "demo.tailnet.ts.net", 443, "/")
	if sc.Web != nil || sc.TCP != nil {
		t.Fatalf("serve config not fully cleared: %+v", sc)
	}
}

func TestNormalizeServePathRejectsTraversalSegments(t *testing.T) {
	for _, path := range []string{"/.", "/..", "/foo/../bar", "/foo/./bar"} {
		t.Run(path, func(t *testing.T) {
			if _, err := normalizeServePath(path); err == nil {
				t.Fatalf("normalizeServePath(%q) succeeded, want error", path)
			}
		})
	}
}

func TestValidateServeLocalAddressRequiresLoopback(t *testing.T) {
	for _, address := range []string{"127.0.0.1", "127.12.34.56", "::1", "localhost", "LOCALHOST"} {
		t.Run("allow "+address, func(t *testing.T) {
			if err := validateServeLocalAddress(address); err != nil {
				t.Fatalf("validateServeLocalAddress(%q): %v", address, err)
			}
		})
	}
	for _, address := range []string{"169.254.169.254", "192.168.1.1", "example.com", ""} {
		t.Run("reject "+address, func(t *testing.T) {
			if err := validateServeLocalAddress(address); err == nil {
				t.Fatalf("validateServeLocalAddress(%q) succeeded, want error", address)
			}
		})
	}
}

func serveTestStatus() *ipnstate.Status {
	return &ipnstate.Status{
		Self: &ipnstate.PeerStatus{
			DNSName: "demo.tailnet.ts.net.",
		},
		CurrentTailnet: &ipnstate.TailnetStatus{
			MagicDNSSuffix: "tailnet.ts.net",
		},
	}
}

func resetServePublicationRegistryForTest(t *testing.T) {
	t.Helper()
	servePublicationMu.Lock()
	servePublications = map[servePublicationKey]struct{}{}
	servePublicationMu.Unlock()
	t.Cleanup(func() {
		servePublicationMu.Lock()
		servePublications = map[servePublicationKey]struct{}{}
		servePublicationMu.Unlock()
	})
}

// Compile-time sanity check that the error class string constants we
// emit match the Dart-side parser in lib/src/worker/entrypoint.dart.
// If someone renames one, this test fails loudly.
func TestClassifyLocalAPIError_KnownCodesAreStable(t *testing.T) {
	wantedCodes := []string{
		"notFound", "forbidden", "conflict",
		"preconditionFailed", "featureDisabled",
	}
	for _, want := range wantedCodes {
		// Synthesize an error that should classify as `want`.
		var err error
		switch want {
		case "notFound":
			err = fakeHTTPErr{status: http.StatusNotFound, msg: "x"}
		case "forbidden":
			err = fakeHTTPErr{status: http.StatusForbidden, msg: "x"}
		case "conflict":
			err = fakeHTTPErr{status: http.StatusConflict, msg: "x"}
		case "preconditionFailed":
			err = fakeHTTPErr{status: http.StatusPreconditionFailed, msg: "x"}
		case "featureDisabled":
			err = errors.New("feature is disabled")
		}
		code, _ := classifyLocalAPIError(err)
		if code != want {
			t.Errorf("round-trip for %q produced %q", want, code)
		}
	}
	// Also make sure we didn't drop a code.
	for _, code := range wantedCodes {
		if !strings.Contains("notFound,forbidden,conflict,preconditionFailed,featureDisabled", code) {
			t.Errorf("untracked code %q", code)
		}
	}
}
