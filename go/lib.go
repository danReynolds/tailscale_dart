package tailscale

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

// LogLevel controls logging verbosity. 0=silent, 1=error, 2=info.
// Accessed atomically — safe to change at any time from any goroutine.
var LogLevel int32 // default 0 (silent)

var (
	mu sync.Mutex // protects srv, proxyPort, proxyLn, reverseProxyLn

	srv       *tsnet.Server
	proxyPort int
	proxyLn   net.Listener // outgoing proxy listener

	reverseProxyLn net.Listener

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
func Logout(stateDir string) {
	Stop()
	os.RemoveAll(stateDir)
}

// Stop stops the server and closes all listeners.
func Stop() {
	mu.Lock()
	defer mu.Unlock()

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
	}
}

// Start initializes the Tailscale node and starts the outgoing HTTP proxy.
// It returns the proxy port number. Call Listen() separately to accept incoming traffic.
func Start(hostname, authKey, controlURL, stateDir string) (int, error) {
	mu.Lock()
	defer mu.Unlock()

	if srv != nil {
		return proxyPort, nil
	}

	os.Setenv("TS_ENABLE_RAW_DISCO", "false")

	if err := os.MkdirAll(stateDir, 0700); err != nil {
		return 0, fmt.Errorf("failed to create state dir: %v", err)
	}

	statePath := stateDir + "/state.db"
	store, err := NewSQLiteStore(statePath)
	if err != nil {
		return 0, fmt.Errorf("failed to create sqlite store: %v", err)
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
			return 0, fmt.Errorf("failed to start tsnet: %v", err)
		}
	}

	// Start the outgoing HTTP proxy (Dart → tailnet peers)
	outLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, fmt.Errorf("failed to listen for outgoing proxy: %v", err)
	}
	proxyLn = outLn
	proxyPort = outLn.Addr().(*net.TCPAddr).Port
	go http.Serve(outLn, http.HandlerFunc(handleOutgoingProxy))

	return proxyPort, nil
}

// Listen starts the reverse proxy that accepts incoming tailnet traffic on port 80
// and forwards it to a local port. If localPort > 0, traffic is forwarded there.
// If localPort == 0, an ephemeral port is allocated. Returns the local port.
func Listen(localPort int) (int, error) {
	mu.Lock()
	s := srv
	alreadyListening := reverseProxyLn != nil
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

	// If already listening, the handler picks up the new targetPort
	if alreadyListening {
		return localPort, nil
	}

	ln, err := s.Listen("tcp", ":80")
	if err != nil {
		return 0, fmt.Errorf("failed to listen on tsnet:80: %v", err)
	}

	mu.Lock()
	if reverseProxyLn != nil {
		mu.Unlock()
		ln.Close()
		return localPort, nil
	}
	reverseProxyLn = ln
	mu.Unlock()

	go http.Serve(ln, http.HandlerFunc(handleReverseProxy))

	return localPort, nil
}

// handleOutgoingProxy proxies HTTP requests from Dart to Tailscale peers.
func handleOutgoingProxy(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		http.Error(w, "Server not running", 503)
		return
	}

	client := s.HTTPClient()

	targetHost := r.URL.Query().Get("target")
	realPath := r.URL.Path

	if targetHost == "" {
		http.Error(w, "Missing 'target' query param", 400)
		return
	}

	targetURL := fmt.Sprintf("http://%s%s", targetHost, realPath)
	query := r.URL.Query()
	query.Del("target")
	if encoded := query.Encode(); encoded != "" {
		targetURL = targetURL + "?" + encoded
	}

	req, err := http.NewRequestWithContext(r.Context(), r.Method, targetURL, r.Body)
	if err != nil {
		http.Error(w, "Bad Request", 400)
		return
	}
	for k, v := range r.Header {
		req.Header[k] = v
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

// DuneStatus returns the full status JSON from the LocalAPI.
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
	status, err := lc.Status(context.Background())
	if err != nil {
		return jsonError(err)
	}
	jsonBytes, err := json.Marshal(status)
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
