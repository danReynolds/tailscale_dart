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

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

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
	mount, err := normalizeServePath(payload.Path)
	if err != nil {
		return servePublication{}, err
	}

	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return servePublication{}, errors.New("ServeForward called before Start")
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
		proxy:        httputil.NewSingleHostReverseProxy(targetURL),
	}

	funnelMu.Lock()
	defer funnelMu.Unlock()
	ff := funnelForwarders[port]
	if ff == nil {
		ln, err := s.ListenFunnel("tcp", fmt.Sprintf(":%d", port), tsnet.FunnelOnly())
		if err != nil {
			return servePublication{}, err
		}
		ff = &funnelForwarder{
			port:    port,
			domain:  domain,
			targets: map[string]funnelTarget{},
		}
		ff.server = &http.Server{Handler: ff}
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

func clearFunnelForward(lc *local.Client, payload serveClearPayload) error {
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
		return clearFunnelServeConfig(lc, domain, port)
	}
	return nil
}

func clearFunnelServeConfig(lc *local.Client, domain string, port uint16) error {
	if domain == "" {
		return nil
	}
	ctx := context.Background()
	sc, err := lc.GetServeConfig(ctx)
	if err != nil {
		return err
	}
	if sc == nil {
		return nil
	}
	sc.SetFunnel(domain, port, false)
	return lc.SetServeConfig(ctx, sc)
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

func closeAllFunnelForwarders(lc *local.Client) {
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
	if lc == nil || len(keys) == 0 {
		return
	}
	for _, key := range keys {
		_ = clearFunnelServeConfig(lc, key.host, key.port)
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
