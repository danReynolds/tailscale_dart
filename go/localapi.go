// Typed wrappers around tailscale.com/client/local.Client one-shot
// LocalAPI calls. Everything in this file shares the same shape:
//
//   1. Acquire the tsnet.Server's LocalClient (or fail if not Started).
//   2. Call a typed method on the LocalClient.
//   3. Marshal the typed response into the shape Dart expects.
//
// Kept separate from lib.go so the LocalAPI surface grows in one
// place as later phases layer more of it on (prefs, exit nodes,
// profiles, serve, taildrop).

package tailscale

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"strings"
)

// WhoIs resolves a tailnet IP to peer identity. Returns a JSON object
// matching the Dart PeerIdentity shape on success. Returns `{"found":
// false}` when the IP isn't known on this tailnet (404 from
// LocalAPI). All other errors surface as `{"error": ...}`.
func WhoIs(ip string) string {
	addr, err := netip.ParseAddr(strings.TrimSpace(ip))
	if err != nil {
		return jsonError(fmt.Errorf("invalid IP %q: %w", ip, err))
	}

	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return jsonError(errors.New("WhoIs called before Start"))
	}

	lc, err := s.LocalClient()
	if err != nil {
		return jsonError(err)
	}

	resp, err := lc.WhoIs(context.Background(), addr.String())
	if err != nil {
		// 404 on an unknown IP is expected; translate to not-found.
		if isNotFound(err) {
			b, _ := json.Marshal(map[string]any{"found": false})
			return string(b)
		}
		return jsonError(err)
	}

	ips := make([]string, 0, len(resp.Node.Addresses))
	for _, p := range resp.Node.Addresses {
		ips = append(ips, p.Addr().String())
	}

	tags := resp.Node.Tags
	if tags == nil {
		tags = []string{}
	}

	out := map[string]any{
		"found":         true,
		"nodeId":        string(resp.Node.StableID),
		"hostName":      resp.Node.ComputedName,
		"userLoginName": resp.UserProfile.LoginName,
		"tags":          tags,
		"tailscaleIPs":  ips,
	}
	b, err := json.Marshal(out)
	if err != nil {
		return jsonError(err)
	}
	return string(b)
}

// isNotFound is true when err wraps a LocalAPI 404. Covers both the
// typed `*apitype.HTTPErr`-shaped case and a string fallback so the
// package works across minor upstream version skew.
func isNotFound(err error) bool {
	var herr interface{ Status() int }
	if errors.As(err, &herr) && herr.Status() == http.StatusNotFound {
		return true
	}
	return strings.Contains(err.Error(), "404")
}
