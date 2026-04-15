package tailscale

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
)

// LogLevel controls logging verbosity. 0=silent, 1=error, 2=info.
// Accessed atomically — safe to change at any time from any goroutine.
var LogLevel int32 // default 0 (silent)

var (
	mu sync.Mutex // protects srv, proxyPort, proxyLn, reverseProxyLn, proxyAuthToken

	srv            *tsnet.Server
	proxyPort      int
	proxyLn        net.Listener // outgoing proxy listener
	proxyAuthToken string

	reverseProxyLn          net.Listener
	reverseProxyTailnetPort int

	// targetPort is the local Dart port we forward to.
	targetPort   int
	targetPortMu sync.Mutex

	// reverseClient is reused across reverse-proxy requests for connection pooling.
	reverseClient = &http.Client{
		Timeout: 30 * time.Second,
	}
)

const (
	localForwardMaxAttempts = 3
	localForwardRetryDelay  = 150 * time.Millisecond
	proxyRequestPath        = "/proxy"
	proxyAuthHeader         = "X-Tailscale-Proxy-Token"
)

// HasState checks if the state directory contains a valid machine key.
func HasState(stateDir string) bool {
	statePath := stateDir + "/state.db"
	store, err := NewSQLiteStore(statePath)
	if err != nil {
		return false
	}
	defer store.Close()

	val, err := store.ReadState(ipn.MachineKeyStateKey)
	if err != nil {
		return false
	}
	return len(val) > 0
}

// Logout stops the server and removes the state directory.
func Logout(stateDir string) error {
	if strings.TrimSpace(stateDir) == "" {
		return fmt.Errorf("state dir is empty")
	}

	Stop()
	if err := os.RemoveAll(stateDir); err != nil {
		return fmt.Errorf("failed to remove state dir: %w", err)
	}
	return nil
}

// Stop stops the server and closes all listeners.
func Stop() {
	mu.Lock()
	defer mu.Unlock()
	stopLocked()
}

// stopLocked tears down the server and all listeners. Caller must hold mu.
func stopLocked() {
	if reverseProxyLn != nil {
		reverseProxyLn.Close()
		reverseProxyLn = nil
	}

	if proxyLn != nil {
		proxyLn.Close()
		proxyLn = nil
	}

	if srv != nil {
		srv.Close()
		srv = nil
		proxyPort = 0
		proxyAuthToken = ""
		reverseProxyTailnetPort = 0
	}
}

// Start initializes the Tailscale node and starts the outgoing HTTP proxy.
// It returns the proxy port number and per-session proxy auth token.
func Start(hostname, authKey, controlURL, stateDir string) (int, string, error) {
	mu.Lock()
	defer mu.Unlock()

	if srv != nil {
		if authKey == "" {
			return proxyPort, proxyAuthToken, nil
		}
		// Auth key provided on an already-running server — tear down
		// and restart so the new key is applied. Clear persisted state
		// so tsnet treats it as a fresh node; otherwise the existing
		// NeedsLogin state causes tsnet to call StartLoginInteractive
		// and ignore the auth key.
		stopLocked()
		if err := os.RemoveAll(stateDir); err != nil {
			return 0, "", fmt.Errorf("failed to clear state dir for re-auth: %w", err)
		}
	}

	os.Setenv("TS_ENABLE_RAW_DISCO", "false")

	if err := os.MkdirAll(stateDir, 0700); err != nil {
		return 0, "", fmt.Errorf("failed to create state dir: %v", err)
	}

	statePath := stateDir + "/state.db"
	store, err := NewSQLiteStore(statePath)
	if err != nil {
		return 0, "", fmt.Errorf("failed to create sqlite store: %v", err)
	}

	srv = &tsnet.Server{
		Hostname:   hostname,
		AuthKey:    authKey,
		ControlURL: controlURL,
		Dir:        stateDir,
		Store:      store,
		Logf: func(format string, args ...any) {
			if atomic.LoadInt32(&LogLevel) >= 2 {
				log.Printf("TSNET: "+format, args...)
			}
		},
	}

	if err := srv.Start(); err != nil {
		if strings.Contains(err.Error(), "permission denied") || strings.Contains(err.Error(), "netlink") {
			logInfo("Ignoring expected Android permission error: %v", err)
		} else {
			srv.Close()
			srv = nil
			return 0, "", fmt.Errorf("failed to start tsnet: %v", err)
		}
	}

	token, err := newProxyAuthToken()
	if err != nil {
		srv.Close()
		srv = nil
		return 0, "", fmt.Errorf("failed to create proxy auth token: %v", err)
	}

	// Start the outgoing HTTP proxy (Dart → tailnet peers)
	outLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		srv.Close()
		srv = nil
		return 0, "", fmt.Errorf("failed to listen for outgoing proxy: %v", err)
	}
	proxyLn = outLn
	proxyPort = outLn.Addr().(*net.TCPAddr).Port
	proxyAuthToken = token
	go http.Serve(outLn, http.HandlerFunc(handleOutgoingProxy))

	return proxyPort, proxyAuthToken, nil
}

// Listen starts the reverse proxy that accepts incoming tailnet HTTP traffic on
// tailnetPort and forwards it to a local port. If localPort > 0, traffic is
// forwarded there. If localPort == 0, an ephemeral port is allocated.
// Returns the local port.
func Listen(localPort, tailnetPort int) (int, error) {
	if tailnetPort < 1 || tailnetPort > 65535 {
		return 0, fmt.Errorf("invalid tailnet port %d", tailnetPort)
	}

	mu.Lock()
	s := srv
	alreadyListening := reverseProxyLn != nil
	currentTailnetPort := reverseProxyTailnetPort
	mu.Unlock()

	if s == nil {
		return 0, fmt.Errorf("Listen called before Start")
	}

	// Allocate ephemeral port if needed
	if localPort == 0 {
		tmpLn, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return 0, fmt.Errorf("failed to allocate listen port: %v", err)
		}
		localPort = tmpLn.Addr().(*net.TCPAddr).Port
		tmpLn.Close()
	}

	// Update the target port
	targetPortMu.Lock()
	targetPort = localPort
	targetPortMu.Unlock()

	// If already listening on the requested port, the handler picks up the new targetPort.
	if alreadyListening && currentTailnetPort == tailnetPort {
		return localPort, nil
	}

	if alreadyListening {
		mu.Lock()
		if reverseProxyLn != nil {
			reverseProxyLn.Close()
			reverseProxyLn = nil
			reverseProxyTailnetPort = 0
		}
		mu.Unlock()
	}

	ln, err := s.Listen("tcp", fmt.Sprintf(":%d", tailnetPort))
	if err != nil {
		return 0, fmt.Errorf("failed to listen on tsnet:%d: %v", tailnetPort, err)
	}

	mu.Lock()
	if reverseProxyLn != nil {
		mu.Unlock()
		ln.Close()
		return localPort, nil
	}
	reverseProxyLn = ln
	reverseProxyTailnetPort = tailnetPort
	mu.Unlock()

	go http.Serve(ln, http.HandlerFunc(handleReverseProxy))

	return localPort, nil
}

// handleOutgoingProxy proxies HTTP/HTTPS requests from Dart to Tailscale peers.
func handleOutgoingProxy(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	s := srv
	expectedToken := proxyAuthToken
	mu.Unlock()
	if s == nil {
		http.Error(w, "Server not running", 503)
		return
	}
	if r.URL.Path != proxyRequestPath {
		http.Error(w, "Not Found", 404)
		return
	}
	if !isAuthorizedOutgoingProxyRequest(r, expectedToken) {
		http.Error(w, "Unauthorized", 401)
		return
	}

	client := s.HTTPClient()

	targetURL, err := parseOutgoingTarget(r.URL.Query().Get("target"))
	if err != nil {
		http.Error(w, err.Error(), 400)
		return
	}

	req, err := http.NewRequestWithContext(
		r.Context(),
		r.Method,
		targetURL.String(),
		r.Body,
	)
	if err != nil {
		http.Error(w, "Bad Request", 400)
		return
	}
	for k, v := range filteredProxyRequestHeaders(r.Header) {
		req.Header[k] = append([]string(nil), v...)
	}

	resp, err := client.Do(req)
	if err != nil {
		http.Error(w, fmt.Sprintf("Proxy Error: %v", err), 502)
		return
	}
	defer resp.Body.Close()

	for k, v := range resp.Header {
		w.Header()[k] = v
	}
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

func parseOutgoingTarget(raw string) (*url.URL, error) {
	if raw == "" {
		return nil, fmt.Errorf("missing 'target' query param")
	}

	targetURL, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("invalid target URL: %v", err)
	}
	if targetURL.Scheme != "http" && targetURL.Scheme != "https" {
		return nil, fmt.Errorf("invalid target URL scheme %q", targetURL.Scheme)
	}
	if targetURL.Host == "" {
		return nil, fmt.Errorf("invalid target URL: missing host")
	}

	return targetURL, nil
}

func isAuthorizedOutgoingProxyRequest(r *http.Request, expectedToken string) bool {
	if expectedToken == "" {
		return false
	}
	return r.Header.Get(proxyAuthHeader) == expectedToken
}

func filteredProxyRequestHeaders(src http.Header) http.Header {
	filtered := make(http.Header, len(src))
	for k, v := range src {
		if http.CanonicalHeaderKey(k) == proxyAuthHeader {
			continue
		}
		filtered[k] = append([]string(nil), v...)
	}
	return filtered
}

// handleReverseProxy forwards incoming Tailscale traffic to the local Dart server.
func handleReverseProxy(w http.ResponseWriter, r *http.Request) {
	targetPortMu.Lock()
	port := targetPort
	targetPortMu.Unlock()

	target := fmt.Sprintf("http://127.0.0.1:%d", port)
	targetURL := target + r.URL.RequestURI()

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Failed to read request body", 500)
		return
	}
	r.Body.Close()

	remoteIp, _, remoteIpErr := net.SplitHostPort(r.RemoteAddr)

	var resp *http.Response
	for attempt := 1; attempt <= localForwardMaxAttempts; attempt++ {
		outReq, err := http.NewRequestWithContext(r.Context(), r.Method, targetURL, bytes.NewReader(body))
		if err != nil {
			http.Error(w, "Failed to create proxy request", 500)
			return
		}

		for k, v := range r.Header {
			outReq.Header[k] = append([]string(nil), v...)
		}

		if remoteIpErr == nil {
			outReq.Header.Set("X-Dune-Peer-Ip", remoteIp)
		}

		resp, err = reverseClient.Do(outReq)
		if err == nil {
			break
		}

		if attempt == localForwardMaxAttempts {
			http.Error(w, fmt.Sprintf("Local Forward Error: %v", err), 502)
			return
		}

		time.Sleep(localForwardRetryDelay)
	}
	defer resp.Body.Close()

	for k, v := range resp.Header {
		w.Header()[k] = v
	}
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

// GetLocalIP returns the first IPv4 address of the local node.
func GetLocalIP() string {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return ""
	}
	lc, err := s.LocalClient()
	if err != nil {
		return ""
	}
	status, err := lc.Status(context.Background())
	if err != nil {
		return ""
	}
	for _, ip := range status.TailscaleIPs {
		if ip.Is4() {
			return ip.String()
		}
	}
	return ""
}

// GetPeers returns a JSON string list of online peer IPv4 addresses.
func GetPeers() string {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return "[]"
	}

	lc, err := s.LocalClient()
	if err != nil {
		return "[]"
	}

	status, err := lc.Status(context.Background())
	if err != nil {
		return "[]"
	}

	var peers []string
	for _, peer := range status.Peer {
		if !peer.Online {
			continue
		}
		for _, ip := range peer.TailscaleIPs {
			if ip.Is4() {
				peers = append(peers, ip.String())
			}
		}
	}
	jsonBytes, _ := json.Marshal(peers)
	return string(jsonBytes)
}

// DuneStatus returns the local-node status JSON from the LocalAPI.
func DuneStatus() string {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return "{}"
	}
	lc, err := s.LocalClient()
	if err != nil {
		return jsonError(err)
	}
	status, err := lc.StatusWithoutPeers(context.Background())
	if err != nil {
		return jsonError(err)
	}
	jsonBytes, err := json.Marshal(status)
	if err != nil {
		return jsonError(err)
	}
	return string(jsonBytes)
}

// DunePeers returns the current peer list as JSON.
func DunePeers() string {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return "[]"
	}
	lc, err := s.LocalClient()
	if err != nil {
		return jsonError(err)
	}
	status, err := lc.Status(context.Background())
	if err != nil {
		return jsonError(err)
	}

	peers := make([]*ipnstate.PeerStatus, 0, len(status.Peer))
	for _, peer := range status.Peer {
		peers = append(peers, peer)
	}
	ipnstate.SortPeers(peers)

	jsonBytes, err := json.Marshal(peers)
	if err != nil {
		return jsonError(err)
	}
	return string(jsonBytes)
}

func jsonError(err error) string {
	m := map[string]string{"error": err.Error()}
	b, _ := json.Marshal(m)
	return string(b)
}

func logInfo(format string, args ...any) {
	if atomic.LoadInt32(&LogLevel) >= 2 {
		log.Printf("TSNET: "+format, args...)
	}
}

func logError(format string, args ...any) {
	if atomic.LoadInt32(&LogLevel) >= 1 {
		log.Printf("TSNET ERROR: "+format, args...)
	}
}

func newProxyAuthToken() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw[:]), nil
}
