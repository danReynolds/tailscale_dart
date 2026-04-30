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
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
	"tailscale.com/types/opt"
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

// WhoIs resolves a tailnet IP to node identity. Returns a JSON object
// matching the Dart TailscaleNodeIdentity shape on success. Returns `{"found":
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
		return localAPIError(err)
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
	lower := strings.ToLower(err.Error())
	return strings.Contains(lower, "404") ||
		strings.Contains(lower, "not found")
}

// classifyLocalAPIError maps a LocalAPI error to the
// TailscaleErrorCode the Dart side will throw. Returns the empty
// string when the error doesn't fit any known category — the Dart
// side falls back to `TailscaleErrorCode.unknown` in that case.
//
// `status` is the HTTP status extracted from apitype.HTTPErr when
// available, zero otherwise. Used as a secondary signal for the
// Dart side.
func classifyLocalAPIError(err error) (code string, status int) {
	var herr interface{ Status() int }
	if errors.As(err, &herr) {
		status = herr.Status()
	}
	switch status {
	case http.StatusNotFound:
		code = "notFound"
	case http.StatusForbidden:
		code = "forbidden"
	case http.StatusConflict:
		code = "conflict"
	case http.StatusPreconditionFailed:
		code = "preconditionFailed"
	}
	// String match as a backstop for 4xx errors that LocalAPI
	// returns without HTTP status propagation (e.g. taildrop
	// disabled). These messages are stable enough in practice to
	// hinge a feature-disabled signal on — wrapped in a helper so
	// the fragility stays local.
	if code == "" {
		lower := strings.ToLower(err.Error())
		switch {
		case strings.Contains(lower, "not enabled"),
			strings.Contains(lower, "is disabled"),
			strings.Contains(lower, "disabled by"):
			code = "featureDisabled"
		}
	}
	return
}

// localAPIError serializes err as `{"error": "...", "code": "...",
// "statusCode": N}` where the code/statusCode fields are populated
// when classifyLocalAPIError can extract them. Replaces jsonError
// for Phase 4+ LocalAPI call sites so the Dart side throws typed
// exceptions with the right TailscaleErrorCode.
func localAPIError(err error) string {
	code, status := classifyLocalAPIError(err)
	m := map[string]any{"error": err.Error()}
	if code != "" {
		m["code"] = code
	}
	if status != 0 {
		m["statusCode"] = status
	}
	b, _ := json.Marshal(m)
	return string(b)
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
		return localAPIError(err)
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

type prefsUpdatePayload struct {
	AdvertisedRoutes *[]string `json:"advertisedRoutes"`
	AcceptRoutes     *bool     `json:"acceptRoutes"`
	ShieldsUp        *bool     `json:"shieldsUp"`
	AdvertisedTags   *[]string `json:"advertisedTags"`
	WantRunning      *bool     `json:"wantRunning"`
	AutoUpdate       *bool     `json:"autoUpdate"`
	Hostname         *string   `json:"hostname"`
	ExitNodeID       *string   `json:"exitNodeId"`
}

// PrefsGet returns the subset of ipn.Prefs exposed by Dart's TailscalePrefs.
func PrefsGet() string {
	lc, err := lcOr("PrefsGet")
	if err != nil {
		return jsonError(err)
	}
	prefs, err := lc.GetPrefs(context.Background())
	if err != nil {
		return localAPIError(err)
	}
	return prefsToJSON(prefs)
}

// PrefsUpdate applies a Dart PrefsUpdate JSON object using LocalAPI EditPrefs.
func PrefsUpdate(updateJSON string) string {
	var payload prefsUpdatePayload
	dec := json.NewDecoder(strings.NewReader(updateJSON))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&payload); err != nil {
		return jsonError(fmt.Errorf("invalid prefs update JSON: %w", err))
	}

	masked, err := maskedPrefsFromPayload(payload)
	if err != nil {
		return jsonError(err)
	}

	lc, err := lcOr("PrefsUpdate")
	if err != nil {
		return jsonError(err)
	}
	prefs, err := lc.EditPrefs(context.Background(), masked)
	if err != nil {
		return localAPIError(err)
	}
	return prefsToJSON(prefs)
}

// ExitNodeSuggest returns the stable node ID recommended by LocalAPI's
// suggest-exit-node endpoint. Dart maps the ID back to its TailscaleNode.
func ExitNodeSuggest() string {
	lc, err := lcOr("ExitNodeSuggest")
	if err != nil {
		return jsonError(err)
	}
	suggestion, err := lc.SuggestExitNode(context.Background())
	if err != nil {
		return localAPIError(err)
	}
	out := map[string]any{
		"nodeId": string(suggestion.ID),
		"name":   suggestion.Name,
	}
	b, err := json.Marshal(out)
	if err != nil {
		return jsonError(err)
	}
	return string(b)
}

// ExitNodeUseAuto enables AutoExitNode=any, allowing tailscaled to pick and
// re-pick the best eligible exit node.
func ExitNodeUseAuto() string {
	masked := ipn.MaskedPrefs{}
	masked.ClearExitNode()
	masked.AutoExitNode = ipn.AnyExitNode
	masked.ExitNodeIDSet = true
	masked.ExitNodeIPSet = true
	masked.AutoExitNodeSet = true

	lc, err := lcOr("ExitNodeUseAuto")
	if err != nil {
		return jsonError(err)
	}
	prefs, err := lc.EditPrefs(context.Background(), &masked)
	if err != nil {
		return localAPIError(err)
	}
	return prefsToJSON(prefs)
}

func prefsToJSON(prefs *ipn.Prefs) string {
	if prefs == nil {
		return jsonError(errors.New("LocalAPI returned nil prefs"))
	}

	advertisedRoutes := make([]string, 0, len(prefs.AdvertiseRoutes))
	for _, prefix := range prefs.AdvertiseRoutes {
		advertisedRoutes = append(advertisedRoutes, prefix.String())
	}
	advertisedTags := prefs.AdvertiseTags
	if advertisedTags == nil {
		advertisedTags = []string{}
	}

	autoUpdate := false
	if apply, ok := prefs.AutoUpdate.Apply.Get(); ok {
		autoUpdate = apply
	}

	var exitNodeID *string
	if !prefs.ExitNodeID.IsZero() {
		id := string(prefs.ExitNodeID)
		exitNodeID = &id
	}

	out := map[string]any{
		"advertisedRoutes": advertisedRoutes,
		"acceptRoutes":     prefs.RouteAll,
		"shieldsUp":        prefs.ShieldsUp,
		"advertisedTags":   advertisedTags,
		"wantRunning":      prefs.WantRunning,
		"autoUpdate":       autoUpdate,
		"hostname":         prefs.Hostname,
		"exitNodeId":       exitNodeID,
		"autoExitNode":     prefs.AutoExitNode.IsSet(),
	}
	b, err := json.Marshal(out)
	if err != nil {
		return jsonError(err)
	}
	return string(b)
}

func maskedPrefsFromPayload(payload prefsUpdatePayload) (*ipn.MaskedPrefs, error) {
	masked := &ipn.MaskedPrefs{}
	if payload.AdvertisedRoutes != nil {
		prefixes, err := parsePrefixes(*payload.AdvertisedRoutes)
		if err != nil {
			return nil, err
		}
		masked.AdvertiseRoutes = prefixes
		masked.AdvertiseRoutesSet = true
	}
	if payload.AcceptRoutes != nil {
		masked.RouteAll = *payload.AcceptRoutes
		masked.RouteAllSet = true
	}
	if payload.ShieldsUp != nil {
		masked.ShieldsUp = *payload.ShieldsUp
		masked.ShieldsUpSet = true
	}
	if payload.AdvertisedTags != nil {
		masked.AdvertiseTags = append([]string(nil), (*payload.AdvertisedTags)...)
		masked.AdvertiseTagsSet = true
	}
	if payload.WantRunning != nil {
		masked.WantRunning = *payload.WantRunning
		masked.WantRunningSet = true
	}
	if payload.AutoUpdate != nil {
		masked.AutoUpdate = ipn.AutoUpdatePrefs{
			Check: *payload.AutoUpdate,
			Apply: opt.NewBool(*payload.AutoUpdate),
		}
		masked.AutoUpdateSet = ipn.AutoUpdatePrefsMask{
			CheckSet: true,
			ApplySet: true,
		}
	}
	if payload.Hostname != nil {
		masked.Hostname = strings.TrimSpace(*payload.Hostname)
		masked.HostnameSet = true
	}
	if payload.ExitNodeID != nil {
		masked.ClearExitNode()
		masked.ExitNodeIDSet = true
		masked.ExitNodeIPSet = true
		masked.AutoExitNodeSet = true
		if id := strings.TrimSpace(*payload.ExitNodeID); id != "" {
			masked.ExitNodeID = tailcfg.StableNodeID(id)
		}
	}
	return masked, nil
}

func parsePrefixes(cidrs []string) ([]netip.Prefix, error) {
	prefixes := make([]netip.Prefix, 0, len(cidrs))
	for _, cidr := range cidrs {
		trimmed := strings.TrimSpace(cidr)
		if trimmed == "" {
			return nil, errors.New("advertised route CIDR must not be empty")
		}
		prefix, err := netip.ParsePrefix(trimmed)
		if err != nil {
			return nil, fmt.Errorf("invalid advertised route %q: %w", cidr, err)
		}
		prefixes = append(prefixes, prefix.Masked())
	}
	return prefixes, nil
}

// DiagPing runs a Tailscale-level ping against the given tailnet IP
// or MagicDNS name and returns JSON matching the Dart PingResult shape.
// `timeoutMillis <= 0` means no timeout. `pingType` is one of
// "disco" (default), "tsmp", or "icmp".
func DiagPing(ip string, timeoutMillis int, pingType string) string {
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

	addr, err := resolvePingAddr(ctx, lc, ip)
	if err != nil {
		return jsonError(err)
	}

	pr, err := lc.Ping(ctx, addr, pt)
	if err != nil {
		return localAPIError(err)
	}
	if pr.Err != "" {
		return localAPIError(errors.New(pr.Err))
	}

	path := pingPath(pr)
	out := map[string]any{
		"latencyMicros": int64(pr.LatencySeconds * 1_000_000),
		"path":          path,
	}
	if path == "derp" && pr.DERPRegionCode != "" {
		out["derpRegion"] = pr.DERPRegionCode
	}
	b, _ := json.Marshal(out)
	return string(b)
}

func resolvePingAddr(ctx context.Context, lc *local.Client, target string) (netip.Addr, error) {
	target = strings.TrimSpace(target)
	if addr, err := netip.ParseAddr(target); err == nil {
		return addr, nil
	}

	status, err := lc.Status(ctx)
	if err != nil {
		return netip.Addr{}, err
	}

	trimmedTarget := strings.TrimSuffix(target, ".")
	if addr, ok := peerStatusAddr(status.Self, trimmedTarget); ok {
		return addr, nil
	}
	for _, peer := range status.Peer {
		if addr, ok := peerStatusAddr(peer, trimmedTarget); ok {
			return addr, nil
		}
	}
	return netip.Addr{}, fmt.Errorf("unknown tailnet IP or MagicDNS name %q", target)
}

func peerStatusAddr(peer *ipnstate.PeerStatus, target string) (netip.Addr, bool) {
	if peer == nil {
		return netip.Addr{}, false
	}
	hostName := strings.TrimSpace(peer.HostName)
	dnsName := strings.TrimSuffix(strings.TrimSpace(peer.DNSName), ".")
	if !strings.EqualFold(target, hostName) && !strings.EqualFold(target, dnsName) {
		return netip.Addr{}, false
	}
	return firstPeerAddr(peer.TailscaleIPs)
}

func firstPeerAddr(addrs []netip.Addr) (netip.Addr, bool) {
	for _, addr := range addrs {
		if addr.Is4() {
			return addr, true
		}
	}
	for _, addr := range addrs {
		if addr.IsValid() {
			return addr, true
		}
	}
	return netip.Addr{}, false
}

func pingPath(pr *ipnstate.PingResult) string {
	if pr.DERPRegionID != 0 || pr.PeerRelay != "" {
		return "derp"
	}
	if pr.Endpoint != "" {
		return "direct"
	}
	return "unknown"
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
		return localAPIError(err)
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
		return localAPIError(err)
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
			node := map[string]any{
				"name":     n.Name,
				"hostName": n.HostName,
			}
			if n.IPv4 != "" {
				node["ipv4"] = n.IPv4
			}
			if n.IPv6 != "" {
				node["ipv6"] = n.IPv6
			}
			if n.DERPPort != 0 {
				node["derpPort"] = n.DERPPort
			}
			if n.STUNPort != 0 {
				node["stunPort"] = n.STUNPort
			}
			if n.CanPort80 {
				node["canPort80"] = true
			}
			nodes = append(nodes, node)
		}
		regions[strconv.Itoa(id)] = map[string]any{
			"regionId":        r.RegionID,
			"regionCode":      r.RegionCode,
			"regionName":      r.RegionName,
			"latitude":        r.Latitude,
			"longitude":       r.Longitude,
			"avoid":           r.Avoid,
			"noMeasureNoHome": r.NoMeasureNoHome,
			"nodes":           nodes,
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
		return localAPIError(err)
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
