package tailscale

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/netutil"
	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

// funnelMaxConcurrentConns bounds the number of simultaneously-accepted
// connections on a public Funnel listener. Funnel is reachable from the
// anonymous internet, so without a cap a remote attacker could open
// connections (or drip slow request bodies) until the embedded node exhausts
// goroutines/file descriptors. Excess connections wait in the kernel accept
// backlog and are served as slots free up.
const funnelMaxConcurrentConns = 512

// funnelUpTimeout bounds how long startFunnelForward waits for the node to
// reach Running before giving up. tsnet.Up otherwise blocks on the IPN bus with
// no deadline (e.g. NeedsLogin / key expiry), which would hang the Dart FFI
// call forever with no error surface.
const funnelUpTimeout = 30 * time.Second

var (
	funnelMu         sync.Mutex
	funnelForwarders = map[uint16]*funnelForwarder{}
)

type funnelTarget struct {
	localAddress string
	localPort    uint16
	proxy        *httputil.ReverseProxy
}

type funnelForwarder struct {
	port     uint16
	domain   string
	listener net.Listener
	server   *http.Server

	mu      sync.RWMutex
	targets map[string]funnelTarget
}

func startFunnelForward(payload serveForwardPayload) (servePublication, error) {
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

	gate, ok := acquireNodeGate()
	if !ok {
		return servePublication{}, errors.New("FunnelForward called before Start")
	}
	s := gate.s

	upCtx, cancel := context.WithTimeout(context.Background(), funnelUpTimeout)
	st, err := s.Up(upCtx)
	cancel()
	if err != nil {
		return servePublication{}, fmt.Errorf("bring node up for funnel: %w", err)
	}
	if err := ipn.CheckFunnelAccess(port, st.Self); err != nil {
		return servePublication{}, err
	}
	if len(st.CertDomains) == 0 {
		return servePublication{}, errors.New("Funnel not available; HTTPS must be enabled. See https://tailscale.com/s/https")
	}
	domain := st.CertDomains[0]

	targetURL := &url.URL{
		Scheme: "http",
		Host:   net.JoinHostPort(localAddress, strconv.Itoa(int(localPort))),
	}
	target := funnelTarget{
		localAddress: localAddress,
		localPort:    localPort,
		proxy:        newFunnelReverseProxy(targetURL),
	}

	// Fast path: an existing forwarder for this port just gains a mount. No
	// ListenFunnel here, so holding funnelMu is safe. The epoch check keeps a
	// stale op (its node already torn down) from attaching an old-lifecycle
	// mount to a NEW node's forwarder at the same port.
	funnelMu.Lock()
	if !gate.stillCurrent() {
		funnelMu.Unlock()
		return servePublication{}, errors.New("funnel forward raced node teardown")
	}
	if ff := funnelForwarders[port]; ff != nil {
		if ff.domain != domain {
			funnelMu.Unlock()
			return servePublication{}, fmt.Errorf("funnel port %d is already serving domain %s", port, ff.domain)
		}
		pub := attachFunnelTargetLocked(ff, mount, target, domain, port)
		funnelMu.Unlock()
		return pub, nil
	}
	funnelMu.Unlock()

	// No forwarder for this port yet. ListenFunnel blocks on tsnet.Up
	// internally (with an unbounded context we don't control), so it must NOT
	// run under funnelMu: Stop() takes funnelMu while holding the global mu, so
	// a ListenFunnel stalled under funnelMu would wedge every FFI entry point
	// behind that mu. Create the listener first, then install under a fresh
	// lock, resolving any forwarder a concurrent call created meanwhile.
	rawLn, err := s.ListenFunnel("tcp", fmt.Sprintf(":%d", port), tsnet.FunnelOnly())
	if err != nil {
		// A concurrent call for this same port may have already bound the funnel
		// listener, so ours fails with "address in use". If a forwarder now
		// exists, fold into it rather than surfacing a spurious error to the
		// caller (a plain retry would hit the fast path anyway). Same epoch
		// check as the fast path: never fold into a later lifecycle's forwarder.
		funnelMu.Lock()
		if !gate.stillCurrent() {
			funnelMu.Unlock()
			return servePublication{}, errors.New("funnel forward raced node teardown")
		}
		existing := funnelForwarders[port]
		if existing != nil && existing.domain == domain {
			pub := attachFunnelTargetLocked(existing, mount, target, domain, port)
			funnelMu.Unlock()
			return pub, nil
		}
		funnelMu.Unlock()
		if existing != nil {
			return servePublication{}, fmt.Errorf("funnel port %d is already serving domain %s", port, existing.domain)
		}
		return servePublication{}, err
	}

	return installFunnelForwarder(gate, port, domain, rawLn, mount, target)
}

// installFunnelForwarder is startFunnelForward's commit point: it installs a
// forwarder for [rawLn] in the registry (or folds into a concurrently-created
// one) and attaches the first mount. Extracted so the teardown-race harness
// can drive it with a plain net.Listener.
//
// The node may have been torn down (Stop/logout, e.g. from a concurrent
// down() — forward runs on its own isolate and is not ordered against
// lifecycle calls) while ListenFunnel ran; our listener is then already being
// closed by srv.Close. Refuse to install a forwarder that would linger with a
// dead listener. Checked INSIDE funnelMu — the same lock
// closeAllFunnelForwarders sweeps under — so the install either commits
// before the sweep (and is swept) or observes the bumped epoch here; there is
// no check-to-install window. (The Serve-goroutine reap remains as the
// self-heal for mid-lifecycle listener death.)
func installFunnelForwarder(gate nodeGate, port uint16, domain string, rawLn net.Listener, mount string, target funnelTarget) (servePublication, error) {
	funnelMu.Lock()
	defer funnelMu.Unlock()
	if !gate.stillCurrent() {
		_ = rawLn.Close()
		return servePublication{}, errors.New("funnel forward raced node teardown")
	}
	if existing := funnelForwarders[port]; existing != nil {
		// Lost the create race; drop our listener and fold into the winner.
		_ = rawLn.Close()
		if existing.domain != domain {
			return servePublication{}, fmt.Errorf("funnel port %d is already serving domain %s", port, existing.domain)
		}
		return attachFunnelTargetLocked(existing, mount, target, domain, port), nil
	}

	ln := netutil.LimitListener(rawLn, funnelMaxConcurrentConns)
	ff := &funnelForwarder{
		port:    port,
		domain:  domain,
		targets: map[string]funnelTarget{},
	}
	ff.server = &http.Server{
		Handler: ff,
		// Funnel is public-facing. Bound header reads without imposing a
		// response WriteTimeout that would break long streaming responses.
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	ff.listener = ln
	funnelForwarders[port] = ff
	go func() {
		_ = ff.server.Serve(ln)
		// Serve returned: the listener closed — normal teardown, or this
		// forwarder raced a Stop and srv.Close killed its listener out from
		// under it. Self-heal so a dead forwarder can't linger in the registry
		// and have a later same-port forward attach a mount to a closed
		// listener (which would silently fail to serve). Mirrors the HTTP
		// binding's Serve goroutine.
		reapFunnelForwarder(port, ff)
	}()
	return attachFunnelTargetLocked(ff, mount, target, domain, port), nil
}

// reapFunnelForwarder removes [ff] from the registry once its listener has
// closed. Idempotent and safe if a different forwarder has since taken the
// port (it only reaps [ff] itself), so it composes with
// closeAllFunnelForwarders.
func reapFunnelForwarder(port uint16, ff *funnelForwarder) {
	funnelMu.Lock()
	if funnelForwarders[port] != ff {
		funnelMu.Unlock()
		return // already reaped, or the port was reclaimed by a newer forwarder
	}
	delete(funnelForwarders, port)
	funnelMu.Unlock()

	_ = ff.server.Close()
}

// attachFunnelTargetLocked registers a mount on an existing forwarder. The
// caller must hold funnelMu; the only lock it takes (funnelMu -> ff.mu)
// matches every other path, so holding funnelMu across it cannot deadlock
// closeAllFunnelForwarders.
func attachFunnelTargetLocked(ff *funnelForwarder, mount string, target funnelTarget, domain string, port uint16) servePublication {
	ff.mu.Lock()
	ff.targets[mount] = target
	ff.mu.Unlock()
	return servePublication{
		URL:          serveURL(true, domain, port, mount),
		Port:         int(port),
		LocalAddress: target.localAddress,
		LocalPort:    int(target.localPort),
		Path:         mount,
		HTTPS:        true,
		Funnel:       true,
	}
}

func clearFunnelForward(payload serveClearPayload) error {
	port, err := validateServePort("tailnetPort", payload.TailnetPort)
	if err != nil {
		return err
	}
	mount, err := normalizeServePath(payload.Path)
	if err != nil {
		return err
	}

	var removePort bool
	funnelMu.Lock()
	ff := funnelForwarders[port]
	if ff != nil {
		ff.mu.Lock()
		delete(ff.targets, mount)
		removePort = len(ff.targets) == 0
		ff.mu.Unlock()
		if removePort {
			delete(funnelForwarders, port)
		}
	}
	funnelMu.Unlock()

	if ff == nil {
		return nil
	}
	if removePort {
		_ = ff.server.Close()
		_ = ff.listener.Close()
	}
	return nil
}

func closeAllFunnelForwarders() {
	funnelMu.Lock()
	for port, ff := range funnelForwarders {
		_ = ff.server.Close()
		_ = ff.listener.Close()
		delete(funnelForwarders, port)
	}
	funnelMu.Unlock()
}

func (ff *funnelForwarder) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	target, ok := ff.match(r.URL.Path)
	if !ok {
		http.NotFound(w, r)
		return
	}
	target.proxy.ServeHTTP(w, r)
}

func newFunnelReverseProxy(targetURL *url.URL) *httputil.ReverseProxy {
	return &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(targetURL)
			// Preserve the existing Host behavior of NewSingleHostReverseProxy
			// while still using Rewrite's sanitized outbound request.
			pr.Out.Host = pr.In.Host

			// ReverseProxy removes Forwarded/X-Forwarded-* before Rewrite runs.
			// Clear other common client-IP proxy headers before setting the
			// values this Funnel layer wants the backend to trust.
			stripUntrustedProxyHeaders(pr.Out.Header)
			pr.SetXForwarded()
			pr.Out.Header.Set("X-Forwarded-Proto", "https")
			pr.Out.Header.Set("X-Forwarded-Host", pr.In.Host)
			stripReservedIdentityHeaders(pr.Out.Header)
		},
	}
}

// stripUntrustedProxyHeaders deletes proxy-supplied client metadata that is
// spoofable at the public Funnel edge. Forwarded and X-Forwarded-* are already
// removed by httputil.ReverseProxy before Rewrite, but keeping them here makes
// the trust boundary explicit and covers headers Go does not special-case.
func stripUntrustedProxyHeaders(h http.Header) {
	for _, name := range []string{
		"Forwarded",
		"X-Forwarded-For",
		"X-Forwarded-Host",
		"X-Forwarded-Port",
		"X-Forwarded-Proto",
		"X-Forwarded-Ssl",
		"X-Original-Forwarded-For",
		"X-Real-Ip",
	} {
		h.Del(name)
	}
}

// stripReservedIdentityHeaders deletes request headers reserved for
// Tailscale-injected identity context. These must never originate from a
// (potentially anonymous, public) client; only tailscaled's authenticated
// Serve path is allowed to set them.
func stripReservedIdentityHeaders(h http.Header) {
	// Funnel exposes this listener to the anonymous public internet. The
	// Tailscale-* request headers (Tailscale-User-Login, Tailscale-User-Name,
	// Tailscale-User-Profile-Pic, etc.) are reserved for tailscaled-injected,
	// authenticated identity context. They are only trustworthy on the Serve
	// path, where tailscaled strips client-supplied copies and re-sets them
	// from an authenticated WhoIs. This bespoke proxy bypasses that, so without
	// stripping, a public client could send `Tailscale-User-Login: admin@corp`
	// and have it forwarded verbatim to the loopback backend. Delete any the
	// client supplied before proxying so they can never be mistaken for trusted
	// identity.
	for name := range h {
		if strings.HasPrefix(http.CanonicalHeaderKey(name), "Tailscale-") {
			delete(h, name)
		}
	}
}

func (ff *funnelForwarder) match(path string) (funnelTarget, bool) {
	ff.mu.RLock()
	defer ff.mu.RUnlock()
	if target, ok := ff.targets[path]; ok {
		return target, true
	}
	mounts := make([]string, 0, len(ff.targets))
	for mount := range ff.targets {
		mounts = append(mounts, mount)
	}
	sort.Slice(mounts, func(i, j int) bool {
		return len(mounts[i]) > len(mounts[j])
	})
	for _, mount := range mounts {
		if mount == "/" || strings.HasPrefix(path, strings.TrimRight(mount, "/")+"/") {
			return ff.targets[mount], true
		}
	}
	return funnelTarget{}, false
}
