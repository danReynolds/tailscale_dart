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
	"strconv"
	"strings"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/tailcfg"
)

// lcOr returns the current LocalClient or an error if the embedded
// engine hasn't been Started yet. Every wrapper in this file opens
// with this call — factoring keeps each wrapper short.
func lcOr(op string) (*local.Client, error) {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return nil, fmt.Errorf("%s called before Start", op)
	}
	return s.LocalClient()
}

// WhoIs resolves a tailnet IP to peer identity. Returns a JSON object
// matching the Dart PeerIdentity shape on success. Returns `{"found":
// false}` when the IP isn't known on this tailnet (404 from
// LocalAPI). All other errors surface as `{"error": ...}`.
func WhoIs(ip string) string {
	addr, err := netip.ParseAddr(strings.TrimSpace(ip))
	if err != nil {
		return jsonError(fmt.Errorf("invalid IP %q: %w", ip, err))
	}
	lc, err := lcOr("WhoIs")
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
	// A successful response without a Node would be a LocalAPI
	// contract violation, but guard anyway so we don't panic.
	if resp == nil || resp.Node == nil {
		b, _ := json.Marshal(map[string]any{"found": false})
		return string(b)
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

// TlsDomains returns the Subject Alternative Names baked into the
// auto-provisioned TLS cert for this node — typically
// `<node>.<tailnet>.ts.net`. Empty when the tailnet operator has
// MagicDNS or HTTPS disabled.
//
// Returns JSON `{"domains": [...]}` on success, `{"error": ...}` on
// failure.
func TlsDomains() string {
	lc, err := lcOr("TlsDomains")
	if err != nil {
		return jsonError(err)
	}
	status, err := lc.Status(context.Background())
	if err != nil {
		return jsonError(err)
	}

	domains := status.CertDomains
	if domains == nil {
		domains = []string{}
	}
	b, err := json.Marshal(map[string]any{"domains": domains})
	if err != nil {
		return jsonError(err)
	}
	return string(b)
}

// DiagPing runs a Tailscale-level ping against the given tailnet IP
// and returns JSON matching the Dart PingResult shape.
// `timeoutMillis <= 0` means no timeout. `pingType` is one of
// "disco" (default), "tsmp", or "icmp".
func DiagPing(ip string, timeoutMillis int, pingType string) string {
	addr, err := netip.ParseAddr(strings.TrimSpace(ip))
	if err != nil {
		return jsonError(fmt.Errorf("invalid IP %q: %w", ip, err))
	}
	var pt tailcfg.PingType
	switch strings.ToLower(strings.TrimSpace(pingType)) {
	case "", "disco":
		pt = tailcfg.PingDisco
	case "tsmp":
		pt = tailcfg.PingTSMP
	case "icmp":
		pt = tailcfg.PingICMP
	default:
		return jsonError(fmt.Errorf("unknown ping type %q", pingType))
	}

	lc, err := lcOr("DiagPing")
	if err != nil {
		return jsonError(err)
	}

	ctx := context.Background()
	if timeoutMillis > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, time.Duration(timeoutMillis)*time.Millisecond)
		defer cancel()
	}

	pr, err := lc.Ping(ctx, addr, pt)
	if err != nil {
		return jsonError(err)
	}
	if pr.Err != "" {
		return jsonError(errors.New(pr.Err))
	}

	// "direct" is most meaningful for disco pings (the default), which
	// report Endpoint whenever a direct UDP path was used. TSMP / ICMP
	// pings don't always populate Endpoint even when the path is
	// direct, so for those types a false value should be read as
	// "unknown / not reported" rather than "definitely relayed".
	out := map[string]any{
		"latencyMicros": int64(pr.LatencySeconds * 1_000_000),
		"direct":        pr.Endpoint != "" && pr.DERPRegionID == 0,
	}
	if pr.DERPRegionCode != "" {
		out["derpRegion"] = pr.DERPRegionCode
	}
	b, _ := json.Marshal(out)
	return string(b)
}

// DiagMetrics returns the Prometheus-format user metrics scrape from
// the embedded runtime verbatim.
func DiagMetrics() string {
	lc, err := lcOr("DiagMetrics")
	if err != nil {
		return jsonError(err)
	}
	body, err := lc.UserMetrics(context.Background())
	if err != nil {
		return jsonError(err)
	}
	b, _ := json.Marshal(map[string]any{"metrics": string(body)})
	return string(b)
}

// DiagDERPMap returns the node's current DERP relay map.
func DiagDERPMap() string {
	lc, err := lcOr("DiagDERPMap")
	if err != nil {
		return jsonError(err)
	}
	m, err := lc.CurrentDERPMap(context.Background())
	if err != nil {
		return jsonError(err)
	}
	regions := map[string]any{}
	for id, r := range m.Regions {
		if r == nil {
			continue
		}
		nodes := make([]map[string]any, 0, len(r.Nodes))
		for _, n := range r.Nodes {
			if n == nil {
				continue
			}
			nodes = append(nodes, map[string]any{
				"name":     n.Name,
				"hostName": n.HostName,
			})
		}
		regions[strconv.Itoa(id)] = map[string]any{
			"regionId":   r.RegionID,
			"regionCode": r.RegionCode,
			"regionName": r.RegionName,
			"nodes":      nodes,
		}
	}
	b, _ := json.Marshal(map[string]any{
		"regions":            regions,
		"omitDefaultRegions": m.OmitDefaultRegions,
	})
	return string(b)
}

// DiagCheckUpdate asks the control plane if a newer client version is
// available. Returns `{"available": false}` when the node is already
// on the latest. On success with an update, returns
// `{"available": true, "latestVersion": "...", "urgentSecurityUpdate": bool, "notifyText": "..."}`.
func DiagCheckUpdate() string {
	lc, err := lcOr("DiagCheckUpdate")
	if err != nil {
		return jsonError(err)
	}
	cv, err := lc.CheckUpdate(context.Background())
	if err != nil {
		return jsonError(err)
	}
	// Nil, RunningLatest, or empty LatestVersion all mean "no update".
	if cv == nil || cv.RunningLatest || cv.LatestVersion == "" {
		b, _ := json.Marshal(map[string]any{"available": false})
		return string(b)
	}
	out := map[string]any{
		"available":            true,
		"latestVersion":        cv.LatestVersion,
		"urgentSecurityUpdate": cv.UrgentSecurityUpdate,
	}
	if cv.NotifyText != "" {
		out["notifyText"] = cv.NotifyText
	}
	b, _ := json.Marshal(out)
	return string(b)
}
