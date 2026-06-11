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

var (
	funnelMu            sync.Mutex
	funnelForwarders    = map[uint16]*funnelForwarder{}
	funnelPublicationMu sync.Mutex
	funnelPublications  = map[servePublicationKey]struct{}{}
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

	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return servePublication{}, errors.New("FunnelForward called before Start")
	}

	st, err := s.Up(context.Background())
	if err != nil {
		return servePublication{}, err
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

	funnelMu.Lock()
	defer funnelMu.Unlock()
	ff := funnelForwarders[port]
	if ff == nil {
		rawLn, err := s.ListenFunnel("tcp", fmt.Sprintf(":%d", port), tsnet.FunnelOnly())
		if err != nil {
			return servePublication{}, err
		}
		ln := netutil.LimitListener(rawLn, funnelMaxConcurrentConns)
		ff = &funnelForwarder{
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
		}()
	} else if ff.domain != domain {
		return servePublication{}, fmt.Errorf("funnel port %d is already serving domain %s", port, ff.domain)
	}

	ff.mu.Lock()
	ff.targets[mount] = target
	ff.mu.Unlock()
	trackFunnelPublication(servePublicationKey{host: domain, port: port, path: mount})

	return servePublication{
		URL:          serveURL(true, domain, port, mount),
		Port:         int(port),
		LocalAddress: localAddress,
		LocalPort:    int(localPort),
		Path:         mount,
		HTTPS:        true,
		Funnel:       true,
	}, nil
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

	var domain string
	var removePort bool
	funnelMu.Lock()
	ff := funnelForwarders[port]
	if ff != nil {
		domain = ff.domain
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
	untrackFunnelPublication(servePublicationKey{host: domain, port: port, path: mount})
	if removePort {
		_ = ff.server.Close()
		_ = ff.listener.Close()
	}
	return nil
}

func trackFunnelPublication(key servePublicationKey) {
	if key.host == "" || key.port == 0 || key.path == "" {
		return
	}
	funnelPublicationMu.Lock()
	funnelPublications[key] = struct{}{}
	funnelPublicationMu.Unlock()
}

func untrackFunnelPublication(key servePublicationKey) {
	funnelPublicationMu.Lock()
	delete(funnelPublications, key)
	funnelPublicationMu.Unlock()
}

func untrackFunnelPublications(keys []servePublicationKey) {
	funnelPublicationMu.Lock()
	for _, key := range keys {
		delete(funnelPublications, key)
	}
	funnelPublicationMu.Unlock()
}

func takeFunnelPublications() []servePublicationKey {
	funnelPublicationMu.Lock()
	defer funnelPublicationMu.Unlock()
	keys := make([]servePublicationKey, 0, len(funnelPublications))
	for key := range funnelPublications {
		keys = append(keys, key)
	}
	funnelPublications = map[servePublicationKey]struct{}{}
	return keys
}

func closeAllFunnelForwarders() {
	funnelMu.Lock()
	keys := make([]servePublicationKey, 0)
	for port, ff := range funnelForwarders {
		_ = ff.server.Close()
		_ = ff.listener.Close()
		ff.mu.RLock()
		for mount := range ff.targets {
			keys = append(keys, servePublicationKey{
				host: ff.domain,
				port: port,
				path: mount,
			})
		}
		ff.mu.RUnlock()
		delete(funnelForwarders, port)
	}
	funnelMu.Unlock()
	if len(keys) == 0 {
		keys = takeFunnelPublications()
	} else {
		untrackFunnelPublications(keys)
	}
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
