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
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"sync"
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
		case strings.Contains(lower, "not allowed for funnel"):
			code = "forbidden"
		case strings.Contains(lower, "not enabled"),
			strings.Contains(lower, "must enable"),
			strings.Contains(lower, "not available"),
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

// ErrorJSON serializes runtime errors with the same stable shape used by
// LocalAPI wrappers. FFI exports outside this file use it when an operation can
// still fail for user-actionable tailnet policy reasons, such as HTTPS being
// disabled for ListenTLS.
func ErrorJSON(err error) string {
	return localAPIError(err)
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
	var extra struct{}
	if err := dec.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			err = errors.New("multiple JSON values")
		}
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

type serveForwardPayload struct {
	TailnetPort  int    `json:"tailnetPort"`
	LocalAddress string `json:"localAddress"`
	LocalPort    int    `json:"localPort"`
	Path         string `json:"path"`
	HTTPS        bool   `json:"https"`
	Funnel       bool   `json:"funnel"`
}

type serveClearPayload struct {
	TailnetPort int    `json:"tailnetPort"`
	Path        string `json:"path"`
	Funnel      bool   `json:"funnel"`
}

type servePublication struct {
	URL          string `json:"url"`
	Port         int    `json:"port"`
	LocalAddress string `json:"localAddress"`
	LocalPort    int    `json:"localPort"`
	Path         string `json:"path"`
	HTTPS        bool   `json:"https"`
	Funnel       bool   `json:"funnel"`
}

var (
	servePublicationMu sync.Mutex
	servePublications  = map[servePublicationKey]struct{}{}
)

type servePublicationKey struct {
	host string
	port uint16
	path string
}

// ServeForward publishes a local loopback HTTP service. Serve uses LocalAPI
// ServeConfig; Funnel uses tsnet.ListenFunnel plus a package-owned reverse
// proxy because public ingress activation follows the listener path upstream.
func ServeForward(payloadJSON string) string {
	var payload serveForwardPayload
	dec := json.NewDecoder(strings.NewReader(payloadJSON))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&payload); err != nil {
		return jsonError(fmt.Errorf("invalid serve forward JSON: %w", err))
	}
	var extra struct{}
	if err := dec.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			err = errors.New("multiple JSON values")
		}
		return jsonError(fmt.Errorf("invalid serve forward JSON: %w", err))
	}

	lc, err := lcOr("ServeForward")
	if err != nil {
		return jsonError(err)
	}
	if payload.Funnel {
		publication, err := startFunnelForward(payload)
		if err != nil {
			return localAPIError(err)
		}
		b, err := json.Marshal(publication)
		if err != nil {
			return jsonError(err)
		}
		return string(b)
	}
	ctx := context.Background()
	st, err := lc.StatusWithoutPeers(ctx)
	if err != nil {
		return localAPIError(err)
	}
	sc, err := lc.GetServeConfig(ctx)
	if err != nil {
		return localAPIError(err)
	}
	if sc == nil {
		sc = new(ipn.ServeConfig)
	}

	publication, err := applyServeForward(sc, st, payload)
	if err != nil {
		return localAPIError(err)
	}
	if err := lc.SetServeConfig(ctx, sc); err != nil {
		return localAPIError(err)
	}
	trackServePublication(publication.hostKey())

	b, err := json.Marshal(publication)
	if err != nil {
		return jsonError(err)
	}
	return string(b)
}

// ServeClear removes one Serve/Funnel web path from this node. It is
// intentionally idempotent: clearing an absent mapping still succeeds.
func ServeClear(payloadJSON string) string {
	var payload serveClearPayload
	dec := json.NewDecoder(strings.NewReader(payloadJSON))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&payload); err != nil {
		return jsonError(fmt.Errorf("invalid serve clear JSON: %w", err))
	}
	var extra struct{}
	if err := dec.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			err = errors.New("multiple JSON values")
		}
		return jsonError(fmt.Errorf("invalid serve clear JSON: %w", err))
	}

	lc, err := lcOr("ServeClear")
	if err != nil {
		return jsonError(err)
	}
	if payload.Funnel {
		if err := clearFunnelForward(lc, payload); err != nil {
			return localAPIError(err)
		}
		return `{"ok":true}`
	}
	ctx := context.Background()
	sc, err := lc.GetServeConfig(ctx)
	if err != nil {
		return localAPIError(err)
	}
	st, err := lc.StatusWithoutPeers(ctx)
	if err != nil {
		return localAPIError(err)
	}

	if err := applyServeClear(sc, st, payload); err != nil {
		return localAPIError(err)
	}
	if err := lc.SetServeConfig(ctx, sc); err != nil {
		return localAPIError(err)
	}
	untrackServePublicationFromStatus(st, payload)
	return `{"ok":true}`
}

func (p servePublication) hostKey() servePublicationKey {
	u, err := url.Parse(p.URL)
	if err != nil {
		return servePublicationKey{}
	}
	host := u.Hostname()
	return servePublicationKey{
		host: host,
		port: uint16(p.Port),
		path: p.Path,
	}
}

func trackServePublication(key servePublicationKey) {
	if key.host == "" || key.port == 0 || key.path == "" {
		return
	}
	servePublicationMu.Lock()
	servePublications[key] = struct{}{}
	servePublicationMu.Unlock()
}

func untrackServePublicationFromStatus(st *ipnstate.Status, payload serveClearPayload) {
	dnsName, _, err := serveHostFromStatus(st)
	if err != nil {
		return
	}
	port, err := validateServePort("tailnetPort", payload.TailnetPort)
	if err != nil {
		return
	}
	mount, err := normalizeServePath(payload.Path)
	if err != nil {
		return
	}
	untrackServePublication(servePublicationKey{host: dnsName, port: port, path: mount})
}

func untrackServePublication(key servePublicationKey) {
	servePublicationMu.Lock()
	delete(servePublications, key)
	servePublicationMu.Unlock()
}

func closeAllServePublications(lc *local.Client) {
	keys := takeServePublications()
	if lc == nil || len(keys) == 0 {
		return
	}
	ctx := context.Background()
	sc, err := lc.GetServeConfig(ctx)
	if err != nil || sc == nil {
		return
	}
	for _, key := range keys {
		removeServeWebHandler(sc, key.host, key.port, key.path)
	}
	_ = lc.SetServeConfig(ctx, sc)
}

func takeServePublications() []servePublicationKey {
	servePublicationMu.Lock()
	defer servePublicationMu.Unlock()
	keys := make([]servePublicationKey, 0, len(servePublications))
	for key := range servePublications {
		keys = append(keys, key)
	}
	servePublications = map[servePublicationKey]struct{}{}
	return keys
}

func applyServeForward(sc *ipn.ServeConfig, st *ipnstate.Status, payload serveForwardPayload) (servePublication, error) {
	port, err := validateServePort("tailnetPort", payload.TailnetPort)
	if err != nil {
		return servePublication{}, err
	}
	localPort, err := validateServePort("localPort", payload.LocalPort)
	if err != nil {
		return servePublication{}, err
	}
	localAddress := strings.TrimSpace(payload.LocalAddress)
	if localAddress == "" {
		localAddress = "127.0.0.1"
	}
	mount, err := normalizeServePath(payload.Path)
	if err != nil {
		return servePublication{}, err
	}
	dnsName, magicDNSSuffix, err := serveHostFromStatus(st)
	if err != nil {
		return servePublication{}, err
	}
	if st.Self == nil {
		return servePublication{}, errors.New("serve unavailable: local node status missing")
	}
	if payload.Funnel {
		if err := ipn.CheckFunnelAccess(port, st.Self); err != nil {
			return servePublication{}, err
		}
	} else if payload.HTTPS && !st.Self.HasCap(tailcfg.CapabilityHTTPS) {
		return servePublication{}, errors.New("Serve not available; HTTPS must be enabled. See https://tailscale.com/s/https.")
	}
	if sc.IsTCPForwardingOnPort(port, "") {
		return servePublication{}, fmt.Errorf("cannot serve web; already serving TCP on port %d", port)
	}

	target := "http://" + net.JoinHostPort(localAddress, strconv.Itoa(int(localPort)))
	proxy, err := ipn.ExpandProxyTargetValue(target, []string{"http"}, "http")
	if err != nil {
		return servePublication{}, err
	}
	sc.SetWebHandler(
		&ipn.HTTPHandler{Proxy: proxy},
		dnsName,
		port,
		mount,
		payload.HTTPS || payload.Funnel,
		magicDNSSuffix,
	)
	if payload.Funnel {
		sc.SetFunnel(dnsName, port, true)
	}

	return servePublication{
		URL:          serveURL(payload.HTTPS || payload.Funnel, dnsName, port, mount),
		Port:         int(port),
		LocalAddress: localAddress,
		LocalPort:    int(localPort),
		Path:         mount,
		HTTPS:        payload.HTTPS || payload.Funnel,
		Funnel:       payload.Funnel,
	}, nil
}

func applyServeClear(sc *ipn.ServeConfig, st *ipnstate.Status, payload serveClearPayload) error {
	if sc == nil {
		return nil
	}
	port, err := validateServePort("tailnetPort", payload.TailnetPort)
	if err != nil {
		return err
	}
	mount, err := normalizeServePath(payload.Path)
	if err != nil {
		return err
	}
	dnsName, _, err := serveHostFromStatus(st)
	if err != nil {
		return err
	}
	if sc.IsTCPForwardingOnPort(port, "") {
		return fmt.Errorf("cannot clear web serve; currently serving TCP on port %d", port)
	}

	hp := ipn.HostPort(net.JoinHostPort(dnsName, strconv.Itoa(int(port))))
	web := sc.Web[hp]
	if web == nil {
		return nil
	}
	delete(web.Handlers, mount)
	if len(web.Handlers) == 0 {
		delete(sc.Web, hp)
		delete(sc.TCP, port)
		delete(sc.AllowFunnel, hp)
	}
	if len(sc.Web) == 0 {
		sc.Web = nil
	}
	if len(sc.TCP) == 0 {
		sc.TCP = nil
	}
	if len(sc.AllowFunnel) == 0 {
		sc.AllowFunnel = nil
	}
	return nil
}

func removeServeWebHandler(sc *ipn.ServeConfig, host string, port uint16, mount string) {
	if sc == nil || host == "" || port == 0 || mount == "" {
		return
	}
	hp := ipn.HostPort(net.JoinHostPort(host, strconv.Itoa(int(port))))
	web := sc.Web[hp]
	if web == nil {
		return
	}
	delete(web.Handlers, mount)
	if len(web.Handlers) == 0 {
		delete(sc.Web, hp)
		delete(sc.TCP, port)
		delete(sc.AllowFunnel, hp)
	}
	if len(sc.Web) == 0 {
		sc.Web = nil
	}
	if len(sc.TCP) == 0 {
		sc.TCP = nil
	}
	if len(sc.AllowFunnel) == 0 {
		sc.AllowFunnel = nil
	}
}

func validateServePort(name string, port int) (uint16, error) {
	if port <= 0 || port > 65535 {
		return 0, fmt.Errorf("invalid %s %d: must be 1..65535", name, port)
	}
	return uint16(port), nil
}

func normalizeServePath(raw string) (string, error) {
	path := strings.TrimSpace(raw)
	if path == "" {
		return "/", nil
	}
	if !strings.HasPrefix(path, "/") {
		return "", fmt.Errorf("serve path %q must start with /", raw)
	}
	if strings.ContainsAny(path, "?#") {
		return "", fmt.Errorf("serve path %q must not include query or fragment", raw)
	}
	return path, nil
}

func serveHostFromStatus(st *ipnstate.Status) (dnsName string, magicDNSSuffix string, err error) {
	if st == nil || st.Self == nil {
		return "", "", errors.New("serve unavailable: local node status missing")
	}
	dnsName = strings.TrimSuffix(st.Self.DNSName, ".")
	if dnsName == "" {
		return "", "", errors.New("serve unavailable: local node DNS name missing")
	}
	if st.CurrentTailnet != nil {
		magicDNSSuffix = st.CurrentTailnet.MagicDNSSuffix
	}
	return dnsName, magicDNSSuffix, nil
}

func serveURL(https bool, host string, port uint16, path string) string {
	scheme := "http"
	if https {
		scheme = "https"
	}
	u := url.URL{Scheme: scheme, Host: host, Path: path}
	if !(scheme == "http" && port == 80) && !(scheme == "https" && port == 443) {
		u.Host = net.JoinHostPort(host, strconv.Itoa(int(port)))
	}
	return u.String()
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
		// Dart intentionally exposes auto-update as one bool even though
		// upstream tracks Check and Apply separately. The package-level
		// control is "auto-update on/off", matching the CLI-level behavior.
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
