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
	"time"

	"tailscale.com/client/local"
	"tailscale.com/client/tailscale/apitype"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
	"tailscale.com/types/opt"
)

type runtimeLocalClient struct {
	*local.Client
	runtime *nodeRuntime
}

func (a *runtimeLocalClient) callContext(timeout time.Duration) (context.Context, context.CancelFunc) {
	return boundedCallCtxFrom(a.runtime.ctx, timeout)
}

func (a *runtimeLocalClient) validateCurrent() error {
	return a.runtime.validateCurrent()
}

func (a *runtimeLocalClient) resultError(err error) error {
	return a.runtime.resultError(err)
}

func (a *runtimeLocalClient) awaitDataPlaneReady(ctx context.Context) error {
	gate := nodeGate{
		runtime: a.runtime,
		s:       a.runtime.server,
		epoch:   a.runtime.generation,
	}
	return gate.awaitDataPlaneReady(ctx)
}

// lcOr returns the LocalClient and runtime generation captured together, or an
// error if the embedded engine has not been started. Callers derive their
// contexts from this runtime and validate it before committing a result.
func lcOr(op string) (*runtimeLocalClient, error) {
	runtime := currentRuntime()
	if runtime == nil {
		return nil, fmt.Errorf("%w: %s called before Start", ErrRuntimeStale, op)
	}
	return &runtimeLocalClient{Client: runtime.localClient, runtime: runtime}, nil
}

// lcForRuntimeToken captures LocalAPI authority only when the caller presents
// the exact current runtime capability. Capped helper-isolate work can wait in
// Dart while a lifecycle replacement occurs; it must fail stale rather than
// discover the replacement's LocalClient at native entry.
func lcForRuntimeToken(op string, runtimeToken uint64) (*runtimeLocalClient, error) {
	gate, ok := acquireNodeGateForRuntimeToken(runtimeToken)
	if !ok {
		return nil, fmt.Errorf(
			"%w: %s captured runtime %d is no longer current",
			ErrRuntimeStale,
			op,
			runtimeToken,
		)
	}
	return &runtimeLocalClient{Client: gate.runtime.localClient, runtime: gate.runtime}, nil
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
		return localAPIError(err)
	}

	ctx, cancel := lc.callContext(0)
	defer cancel()
	if err := lc.awaitDataPlaneReady(ctx); err != nil {
		return localAPIError(err)
	}
	resp, err := lc.WhoIs(ctx, addr.String())
	err = lc.resultError(err)
	if err != nil {
		// 404 on an unknown IP is expected; translate to not-found.
		if isNotFound(err) {
			b, _ := json.Marshal(map[string]any{"found": false})
			return string(b)
		}
		return localAPIError(err)
	}
	// A successful response without a Node would be a LocalAPI
	// contract violation; nodeIdentityFromWhoIs returns nil in that case
	// so we report not-found rather than panic.
	identity := nodeIdentityFromWhoIs(resp)
	if identity == nil {
		b, _ := json.Marshal(map[string]any{"found": false})
		return string(b)
	}

	out := map[string]any{
		"found":         true,
		"nodeId":        identity.NodeID,
		"hostName":      identity.HostName,
		"userLoginName": identity.UserLoginName,
		"tags":          identity.Tags,
		"tailscaleIPs":  identity.TailscaleIPs,
	}
	b, err := json.Marshal(out)
	if err != nil {
		return jsonError(err)
	}
	return string(b)
}

// nodeIdentity is the typed identity of a tailnet node, shared by the
// LocalAPI WhoIs JSON wrapper and the accept-time identity attached to
// inbound connections. JSON tags match the Dart TailscaleNodeIdentity
// shape so the struct can be embedded directly into accept results.
//
// Treat instances as immutable once built: the identity cache aliases one
// *nodeIdentity under every address of a node and hands it to concurrent
// accept goroutines while the watcher builds the next index, so a caller that
// mutated a returned value or its slices would introduce a data race.
type nodeIdentity struct {
	NodeID        string   `json:"nodeId"`
	HostName      string   `json:"hostName"`
	UserLoginName string   `json:"userLoginName"`
	Tags          []string `json:"tags"`
	TailscaleIPs  []string `json:"tailscaleIPs"`
}

// nodeIdentityFromWhoIs maps a LocalAPI WhoIs response into the typed
// identity shape. Returns nil when the response carries no node (an
// unknown IP or a contract-violating empty response), so callers can
// treat nil uniformly as "no identity".
func nodeIdentityFromWhoIs(resp *apitype.WhoIsResponse) *nodeIdentity {
	if resp == nil || resp.Node == nil {
		return nil
	}
	var loginName string
	if resp.UserProfile != nil {
		loginName = resp.UserProfile.LoginName
	}
	return nodeIdentityFromView(resp.Node.View(), loginName)
}

// nodeIdentityFromView builds the typed identity from a node view plus a
// resolved login name. Shared by the LocalAPI WhoIs path and the netmap
// identity cache so both map a node's fields the same way. The loginName is
// resolved by each caller (WhoIs reads resp.UserProfile; the cache reads the
// netmap's UserProfiles) — same underlying data, but it can differ for a
// tagged node if one source lacks its synthetic profile. Tags and IPs are
// always non-nil slices so they serialize as [] rather than null.
func nodeIdentityFromView(n tailcfg.NodeView, loginName string) *nodeIdentity {
	if !n.Valid() {
		return nil
	}
	addrs := n.Addresses()
	ips := make([]string, 0, addrs.Len())
	for i := range addrs.Len() {
		ips = append(ips, addrs.At(i).Addr().String())
	}
	tagsView := n.Tags()
	tags := make([]string, 0, tagsView.Len())
	for i := range tagsView.Len() {
		tags = append(tags, tagsView.At(i))
	}
	return &nodeIdentity{
		NodeID:        string(n.StableID()),
		HostName:      n.ComputedName(),
		UserLoginName: loginName,
		Tags:          tags,
		TailscaleIPs:  ips,
	}
}

// identityLookupTimeout bounds the accept-time WhoIs call so a slow or
// stuck LocalAPI never stalls an accept. Identity resolution is
// best-effort: on timeout or any error the connection is delivered
// without it.
const identityLookupTimeout = 2 * time.Second

// lookupNodeIdentity resolves the identity of a remote tailnet IP at accept
// time. It reads the in-memory identity cache (mirrored from the netmap by the
// state watcher) for a near-constant-time lookup off the accept hot path. When
// the cache is cold — before the watcher has delivered the first netmap, or
// after it was torn down — it falls back to an authoritative LocalAPI WhoIs so
// early accepts still resolve. Best-effort and non-fatal: any failure returns
// nil and the connection is delivered with IP-only metadata. Callers that
// require a hard identity guarantee should still gate on the returned value.
func lookupNodeIdentity(ip string) *nodeIdentity {
	addr, err := netip.ParseAddr(strings.TrimSpace(ip))
	if err != nil {
		return nil
	}
	if id, ok := identityCache.lookup(addr); ok {
		return id
	}
	return lookupNodeIdentityViaLocalAPI(addr)
}

// lookupNodeIdentityViaLocalAPI is the cold-cache fallback: a live WhoIs over
// the LocalAPI loopback. Takes an already-parsed addr (the caller validated it)
// and is bounded by identityLookupTimeout so a stuck LocalAPI never stalls an
// accept.
func lookupNodeIdentityViaLocalAPI(addr netip.Addr) *nodeIdentity {
	lc, err := lcOr("lookupNodeIdentity")
	if err != nil {
		return nil
	}
	ctx, cancel := lc.callContext(identityLookupTimeout)
	defer cancel()
	resp, err := lc.WhoIs(ctx, addr.String())
	err = lc.resultError(err)
	if err != nil {
		return nil
	}
	return nodeIdentityFromWhoIs(resp)
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

// isTransientNoSuggestion reports whether err is one of upstream's transient
// "node not ready yet" exit-node-suggestion errors (ErrNoPreferredDERP /
// ErrNoNetMap), which surface before the first netcheck completes. These cross
// the LocalAPI boundary as a reconstructed error, so — like isNotFound — we
// match the message text rather than errors.Is against the server-side
// sentinel (which the client never holds).
func isTransientNoSuggestion(err error) bool {
	lower := strings.ToLower(err.Error())
	return strings.Contains(lower, "no preferred derp") ||
		strings.Contains(lower, "no network map")
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
	if errors.Is(err, ErrDataPlaneNotReady) {
		return "dataPlaneNotReady", 0
	}
	if errors.Is(err, ErrPublicationBootstrapFailure) {
		return "publicationBootstrapFailure", 0
	}
	if errors.Is(err, ErrServeConfigConflict) {
		return "serveConfigConflict", 0
	}
	if errors.Is(err, ErrPublicationCommitIndeterminate) {
		return "publicationCommitIndeterminate", 0
	}
	if errors.Is(err, ErrRuntimeStale) {
		return "staleRuntime", 0
	}
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
	// String match as a backstop for feature 4xx errors the LocalAPI returns
	// without HTTP status propagation. The live signal is the funnel-permission
	// error, whose text always begins "Funnel not available; ..." (upstream
	// ipn/serve.go NodeCanFunnel, both the HTTPS-off and node-attribute-not-set
	// variants) — caught by "not available". The remaining phrasings are
	// speculative backstops for similarly-shaped feature errors. Fragile by
	// nature (upstream text can change); kept local and covered by a test that
	// uses the real upstream strings so drift on the live path is caught.
	if code == "" {
		lower := strings.ToLower(err.Error())
		switch {
		case strings.Contains(lower, "not allowed for funnel"):
			code = "forbidden"
		case strings.Contains(lower, "not available"),
			strings.Contains(lower, "not enabled"),
			strings.Contains(lower, "must enable"),
			strings.Contains(lower, "is disabled"),
			strings.Contains(lower, "disabled by"):
			code = "featureDisabled"
		}
	}
	if code == "" && errors.Is(err, ErrPublicationNotApplied) {
		code = "publicationNotApplied"
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
		return localAPIError(err)
	}
	ctx, cancel := lc.callContext(0)
	defer cancel()
	if err := lc.awaitDataPlaneReady(ctx); err != nil {
		return localAPIError(err)
	}
	domains := lc.runtime.server.CertDomains()
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
		return localAPIError(err)
	}
	ctx, cancel := lc.callContext(0)
	defer cancel()
	prefs, err := lc.GetPrefs(ctx)
	err = lc.resultError(err)
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
		return localAPIError(err)
	}
	ctx, cancel := lc.callContext(0)
	defer cancel()
	prefs, err := lc.EditPrefs(ctx, masked)
	err = lc.resultError(err)
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
		return localAPIError(err)
	}
	ctx, cancel := lc.callContext(0)
	defer cancel()
	suggestion, err := lc.SuggestExitNode(ctx)
	err = lc.resultError(err)
	return exitNodeSuggestResult(suggestion, err)
}

// exitNodeSuggestResult maps a SuggestExitNode result to the JSON the Dart side
// parses. Before the first netcheck completes (common right after up()),
// upstream returns a transient "try again later" error rather than an empty
// suggestion; that is mapped to the documented "no suggestion" result (empty
// nodeId -> null on the Dart side) so a polling caller sees null, not a thrown
// exception. Other errors still propagate.
func exitNodeSuggestResult(suggestion apitype.ExitNodeSuggestionResponse, err error) string {
	if err != nil {
		if isTransientNoSuggestion(err) {
			b, _ := json.Marshal(map[string]any{"nodeId": ""})
			return string(b)
		}
		return localAPIError(err)
	}
	b, _ := json.Marshal(map[string]any{"nodeId": string(suggestion.ID)})
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
		return localAPIError(err)
	}
	ctx, cancel := lc.callContext(0)
	defer cancel()
	prefs, err := lc.EditPrefs(ctx, &masked)
	err = lc.resultError(err)
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
	TailnetPort  int     `json:"tailnetPort"`
	Path         string  `json:"path"`
	Funnel       bool    `json:"funnel"`
	Generation   *uint64 `json:"generation,omitempty"`
	MappingToken *uint64 `json:"mappingToken,omitempty"`
}

type servePublication struct {
	URL          string `json:"url"`
	Port         int    `json:"port"`
	LocalAddress string `json:"localAddress"`
	LocalPort    int    `json:"localPort"`
	Path         string `json:"path"`
	HTTPS        bool   `json:"https"`
	Funnel       bool   `json:"funnel"`
	Generation   uint64 `json:"generation"`
	MappingToken uint64 `json:"mappingToken"`
	host         string
}

// ServeForward publishes a local loopback HTTP service for one exact runtime
// capability captured before Dart queues the offload. Serve uses LocalAPI
// ServeConfig; Funnel is the same handler with AllowFunnel enabled, matching
// upstream's one-config Serve/Funnel authority.
func ServeForward(runtimeToken uint64, payloadJSON string) string {
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

	runtime := currentRuntime()
	if runtime == nil {
		if runtimeToken != 0 {
			return localAPIError(fmt.Errorf("%w: ServeForward runtime %d is no longer current", ErrRuntimeStale, runtimeToken))
		}
		return jsonError(errors.New("ServeForward called before Start"))
	}
	if runtimeToken == 0 || runtime.token != runtimeToken {
		return localAPIError(fmt.Errorf(
			"%w: ServeForward captured runtime %d, current runtime is %d",
			ErrRuntimeStale,
			runtimeToken,
			runtime.token,
		))
	}
	manager := runtime.publication
	if manager == nil {
		return localAPIError(notAppliedError(errors.New("ServeForward publication manager is unavailable")))
	}
	ctx, cancel := boundedCallCtxFrom(runtime.ctx, 0)
	defer cancel()
	gate := nodeGate{runtime: runtime, s: runtime.server, epoch: runtime.generation}
	if err := gate.awaitDataPlaneReady(ctx); err != nil {
		return localAPIError(err)
	}
	publication, err := manager.forward(ctx, payload)
	if err != nil {
		if errors.Is(err, ErrPublicationCommitIndeterminate) {
			err = quarantinePublicationCommitIndeterminate(runtime, err)
		}
		return localAPIError(err)
	}
	b, err := json.Marshal(publication)
	if err != nil {
		return jsonError(err)
	}
	return string(b)
}

// AcknowledgePublication transfers one exact committed mapping from native
// delivery custody to its Dart handle. A mismatch can never be redirected to
// a replacement runtime; an ambiguous live receipt quarantines this exact
// generation before returning an error.
func AcknowledgePublication(runtimeToken, generation, mappingToken uint64) error {
	runtime := currentRuntime()
	if runtime == nil || runtimeToken == 0 || runtime.token != runtimeToken || runtime.generation != generation {
		return ErrRuntimeStale
	}
	if runtime.publication == nil {
		return quarantinePublicationDeliveryFailure(
			runtime,
			fmt.Errorf("%w: publication manager is unavailable during acknowledgement", ErrPublicationCommitIndeterminate),
		)
	}
	if err := runtime.publication.acknowledgePublication(generation, mappingToken); err != nil {
		if errors.Is(err, ErrRuntimeStale) {
			return err
		}
		return quarantinePublicationDeliveryFailure(runtime, err)
	}
	return nil
}

// FailPublicationDelivery is Dart's active compensation path when a native
// success cannot be validated or delivered across the helper-isolate result
// port. The unacknowledged timer is the fallback if the caller isolate itself
// cannot execute this function.
func FailPublicationDelivery(runtimeToken uint64) error {
	return failPublicationDelivery(runtimeToken, quarantinePublicationFailure)
}

func failPublicationDelivery(
	runtimeToken uint64,
	quarantine func(*nodeRuntime, error, bool) error,
) error {
	if runtimeToken == 0 {
		return nil
	}
	runtimes.mu.Lock()
	runtime := runtimes.current
	if runtime == nil || runtime.token != runtimeToken {
		draining := runtimes.draining
		if draining == nil || draining.runtime == nil || draining.runtime.token != runtimeToken {
			runtimes.mu.Unlock()
			// A successor can only become current after the prior drain finishes.
			// Never redirect compensation into that successor.
			return nil
		}
		done := draining.done
		runtimes.mu.Unlock()
		<-done
		if draining.err != nil {
			return cleanupFailureError(draining.err)
		}
		return nil
	}
	runtimes.mu.Unlock()
	finalErr := quarantine(
		runtime,
		fmt.Errorf(
			"%w: Dart could not prove publication handle delivery",
			ErrPublicationCommitIndeterminate,
		),
		false,
	)
	if errors.Is(finalErr, ErrRuntimeCleanupFailed) {
		return finalErr
	}
	return nil
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

	mode, generation, _, err := payload.clearMode()
	if err != nil {
		return localAPIError(notAppliedError(err))
	}
	runtime := currentRuntime()
	if mode == publicationClearExact && (runtime == nil || runtime.generation != generation) {
		return `{"ok":true}`
	}
	if runtime == nil {
		return localAPIError(fmt.Errorf("%w: ServeClear called before Start", ErrRuntimeStale))
	}
	manager := runtime.publication
	if manager == nil {
		return localAPIError(notAppliedError(errors.New("ServeClear publication manager is unavailable")))
	}
	ctx, cancel := boundedCallCtxFrom(runtime.ctx, 0)
	defer cancel()
	gate := nodeGate{runtime: runtime, s: runtime.server, epoch: runtime.generation}
	if err := gate.awaitDataPlaneReady(ctx); err != nil {
		return localAPIError(err)
	}
	if err := manager.clear(ctx, payload); err != nil {
		if errors.Is(err, ErrPublicationCommitIndeterminate) {
			err = quarantinePublicationCommitIndeterminate(runtime, err)
		}
		return localAPIError(err)
	}
	return `{"ok":true}`
}

type publicationClearMode uint8

const (
	publicationClearCoordinate publicationClearMode = iota
	publicationClearExact
)

func (p serveClearPayload) clearMode() (publicationClearMode, uint64, uint64, error) {
	if p.Generation == nil && p.MappingToken == nil {
		return publicationClearCoordinate, 0, 0, nil
	}
	if p.Generation == nil || p.MappingToken == nil || *p.Generation == 0 || *p.MappingToken == 0 {
		return 0, 0, 0, errors.New("serve handle close requires positive generation and mappingToken")
	}
	return publicationClearExact, *p.Generation, *p.MappingToken, nil
}

func (p servePublication) key() publicationKey {
	port, _ := validateServePort("tailnetPort", p.Port)
	return publicationKey{port: port, path: p.Path}
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
	localAddress, err = normalizeServeLocalAddress(localAddress)
	if err != nil {
		return servePublication{}, err
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
	if payload.Funnel && !payload.HTTPS {
		return servePublication{}, errors.New("Funnel requires HTTPS")
	}
	if payload.HTTPS && !st.Self.HasCap(tailcfg.CapabilityHTTPS) {
		return servePublication{}, errors.New("Serve not available; HTTPS must be enabled. See https://tailscale.com/s/https.")
	}
	if payload.Funnel {
		if err := ipn.CheckFunnelAccess(port, st.Self); err != nil {
			return servePublication{}, err
		}
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
		payload.HTTPS,
		magicDNSSuffix,
	)
	// Funnel and Serve share one upstream configuration authority. The latest
	// package mutation owns the port-level visibility policy, matching
	// `tailscale serve/funnel`'s setServe path.
	sc.SetFunnel(dnsName, port, payload.Funnel)

	return servePublication{
		URL:          serveURL(payload.HTTPS, dnsName, port, mount),
		Port:         int(port),
		LocalAddress: localAddress,
		LocalPort:    int(localPort),
		Path:         mount,
		HTTPS:        payload.HTTPS,
		Funnel:       payload.Funnel,
		host:         dnsName,
	}, nil
}

func applyServeClear(sc *ipn.ServeConfig, st *ipnstate.Status, payload serveClearPayload) error {
	dnsName, _, err := serveHostFromStatus(st)
	if err != nil {
		return err
	}
	return applyServeClearForHost(sc, dnsName, payload)
}

func applyServeClearForHost(sc *ipn.ServeConfig, dnsName string, payload serveClearPayload) error {
	return applyServeClearForHostWithFunnelCleanup(sc, dnsName, payload, true)
}

func applyServeClearForHostWithFunnelCleanup(
	sc *ipn.ServeConfig,
	dnsName string,
	payload serveClearPayload,
	cleanupFunnelWhenEmpty bool,
) error {
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
	if sc.IsTCPForwardingOnPort(port, "") {
		return fmt.Errorf("cannot clear web serve; currently serving TCP on port %d", port)
	}

	hp := ipn.HostPort(net.JoinHostPort(dnsName, strconv.Itoa(int(port))))
	if payload.Funnel {
		// Funnel visibility is keyed by host:port, not path. Clearing a Funnel
		// publication withdraws public ingress for the whole port while the
		// selected handler cleanup below remains path-specific.
		sc.SetFunnel(dnsName, port, false)
	}
	web := sc.Web[hp]
	if web == nil {
		return nil
	}
	delete(web.Handlers, mount)
	if len(web.Handlers) == 0 {
		delete(sc.Web, hp)
		delete(sc.TCP, port)
		if cleanupFunnelWhenEmpty {
			delete(sc.AllowFunnel, hp)
		}
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
	removeServeWebHandlerWithFunnelCleanup(sc, host, port, mount, true)
}

func removeServeWebHandlerWithFunnelCleanup(
	sc *ipn.ServeConfig,
	host string,
	port uint16,
	mount string,
	cleanupFunnelWhenEmpty bool,
) {
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
		if cleanupFunnelWhenEmpty {
			delete(sc.AllowFunnel, hp)
		}
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

func validateServeLocalAddress(address string) error {
	_, err := normalizeServeLocalAddress(address)
	return err
}

func normalizeServeLocalAddress(address string) (string, error) {
	address = strings.TrimSpace(address)
	if address == "" {
		return "", errors.New("serve localAddress must not be empty")
	}
	if strings.EqualFold(address, "localhost") {
		return "127.0.0.1", nil
	}
	ip := net.ParseIP(address)
	if ip != nil && ip.IsLoopback() {
		return address, nil
	}
	return "", fmt.Errorf("serve localAddress %q must be a loopback address", address)
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
	if containsServePathTraversal(path) {
		return "", fmt.Errorf("serve path %q must not include . or .. segments", raw)
	}
	return path, nil
}

func containsServePathTraversal(path string) bool {
	for _, segment := range strings.Split(path, "/") {
		if segment == "." || segment == ".." {
			return true
		}
	}
	return false
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

// DiagPing runs a Tailscale-level ping for the exact captured runtime token
// against the given tailnet IP or MagicDNS name and returns JSON matching the
// Dart PingResult shape.
// `timeoutMillis <= 0` means no timeout. `pingType` is one of
// "disco" (default), "tsmp", or "icmp".
func DiagPing(runtimeToken uint64, ip string, timeoutMillis int, pingType string) string {
	lc, err := lcForRuntimeToken("DiagPing", runtimeToken)
	if err != nil {
		return localAPIError(err)
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

	// Bounded even with no caller timeout — see defaultNativeCallTimeout.
	ctx, cancel := lc.callContext(time.Duration(timeoutMillis) * time.Millisecond)
	defer cancel()
	if err := lc.awaitDataPlaneReady(ctx); err != nil {
		return localAPIError(err)
	}

	addr, err := resolvePingAddr(ctx, lc.Client, ip)
	err = lc.resultError(err)
	if err != nil {
		return localAPIError(err)
	}

	pr, err := lc.Ping(ctx, addr, pt)
	err = lc.resultError(err)
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
		return localAPIError(err)
	}
	ctx, cancel := lc.callContext(0)
	defer cancel()
	body, err := lc.UserMetrics(ctx)
	err = lc.resultError(err)
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
		return localAPIError(err)
	}
	ctx, cancel := lc.callContext(0)
	defer cancel()
	m, err := lc.CurrentDERPMap(ctx)
	err = lc.resultError(err)
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
		return localAPIError(err)
	}
	ctx, cancel := lc.callContext(0)
	defer cancel()
	cv, err := lc.CheckUpdate(ctx)
	err = lc.resultError(err)
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
