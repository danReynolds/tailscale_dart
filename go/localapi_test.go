package tailscale

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"strings"
	"testing"

	"tailscale.com/ipn/ipnstate"
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
	if isNotFound(errors.New("unrelated error")) {
		t.Error("non-404 error should not match")
	}
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
