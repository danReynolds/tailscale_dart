//go:build !windows

package tailscale

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/sys/unix"
	"tailscale.com/net/tlsdial"
	"tailscale.com/tsnet"
)

const (
	httpAcceptBacklog     = 128
	httpMaxHeadBytes      = 256 * 1024
	httpReadHeaderTimeout = 10 * time.Second
	httpIdleTimeout       = 120 * time.Second
)

type HttpFdRequest struct {
	RequestBodyFD  int
	ResponseBodyFD int
}

type HttpBinding struct {
	ID             int64
	TailnetAddress string
	TailnetPort    int
}

type HttpIncomingRequest struct {
	BindingID      int64
	RequestBodyFD  int
	ResponseBodyFD int
	Method         string
	RequestURI     string
	Host           string
	Proto          string
	Headers        map[string][]string
	ContentLength  int64
	RemoteAddress  string
	RemotePort     int
	LocalAddress   string
	LocalPort      int
	// Identity is the resolved identity of the calling node, attached at
	// accept time the same way inbound TCP/TLS connections carry it. Nil for
	// public Funnel callers (no tailnet node) and when the accept-time lookup
	// found nothing or failed.
	Identity *nodeIdentity
}

type httpResponseHead struct {
	StatusCode   int                 `json:"statusCode,omitempty"`
	ReasonPhrase string              `json:"reasonPhrase,omitempty"`
	Headers      map[string][]string `json:"headers,omitempty"`
	// No omitempty: a legitimate Content-Length: 0 (204, empty 200) must reach
	// Dart as 0, not be dropped to null. Unknown length is sent as -1, which
	// the Dart parser maps to null.
	ContentLength int64  `json:"contentLength"`
	Error         string `json:"error,omitempty"`
}

type httpBindingState struct {
	binding  HttpBinding
	ln       net.Listener
	server   *http.Server
	requests chan *HttpIncomingRequest
	done     chan struct{}
	once     sync.Once
}

var (
	httpBindingID       int64
	httpBindingRegistry = map[int64]*httpBindingState{}
	httpBindingMu       sync.Mutex
)

func HttpBind(tailnetPort int) (*HttpBinding, error) {
	if tailnetPort < 0 || tailnetPort > 65535 {
		return nil, fmt.Errorf("invalid tailnet port %d", tailnetPort)
	}

	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return nil, fmt.Errorf("HttpBind called before Start")
	}

	ln, err := s.Listen("tcp", fmt.Sprintf(":%d", tailnetPort))
	if err != nil {
		return nil, fmt.Errorf("failed to listen on tsnet:%d: %v", tailnetPort, err)
	}

	tailnetAddress, effectiveTailnetPort := endpointFromAddr(ln.Addr())
	if effectiveTailnetPort == 0 {
		ln.Close()
		return nil, fmt.Errorf("tsnet listen returned unresolved port")
	}

	id := atomic.AddInt64(&httpBindingID, 1)
	state := &httpBindingState{
		binding: HttpBinding{
			ID:             id,
			TailnetAddress: tailnetAddress,
			TailnetPort:    effectiveTailnetPort,
		},
		ln:       ln,
		requests: make(chan *HttpIncomingRequest, httpAcceptBacklog),
		done:     make(chan struct{}),
	}
	state.server = newHTTPBindingServer(state)

	mu.Lock()
	if srv != s {
		mu.Unlock()
		ln.Close()
		return nil, fmt.Errorf("HttpBind raced with Stop or server replacement")
	}
	mu.Unlock()

	httpBindingMu.Lock()
	httpBindingRegistry[id] = state
	httpBindingMu.Unlock()

	go func() {
		_ = state.server.Serve(ln)
		state.close()
		httpBindingMu.Lock()
		if httpBindingRegistry[id] == state {
			delete(httpBindingRegistry, id)
		}
		httpBindingMu.Unlock()
	}()

	return &state.binding, nil
}

func newHTTPBindingServer(state *httpBindingState) *http.Server {
	return &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			serveHTTPFdRequest(state, w, r)
		}),
		ReadHeaderTimeout: httpReadHeaderTimeout,
		IdleTimeout:       httpIdleTimeout,
	}
}

func HttpAccept(bindingID int64) (*HttpIncomingRequest, bool, error) {
	httpBindingMu.Lock()
	state := httpBindingRegistry[bindingID]
	httpBindingMu.Unlock()
	if state == nil {
		return nil, true, nil
	}

	select {
	case request := <-state.requests:
		if request == nil {
			return nil, true, nil
		}
		return request, false, nil
	case <-state.done:
		return nil, true, nil
	}
}

func HttpCloseBinding(id int64) {
	httpBindingMu.Lock()
	state := httpBindingRegistry[id]
	delete(httpBindingRegistry, id)
	httpBindingMu.Unlock()
	if state != nil {
		state.close()
	}
}

func closeAllHttpBindings() {
	httpBindingMu.Lock()
	bindings := make([]*httpBindingState, 0, len(httpBindingRegistry))
	for id, state := range httpBindingRegistry {
		bindings = append(bindings, state)
		delete(httpBindingRegistry, id)
	}
	httpBindingMu.Unlock()

	for _, state := range bindings {
		state.close()
	}
}

func (s *httpBindingState) close() {
	s.once.Do(func() {
		close(s.done)
		if s.server != nil {
			_ = s.server.Close()
		}
		if s.ln != nil {
			_ = s.ln.Close()
		}
	})
	// Drain requests that were enqueued but never accepted by Dart and release
	// their fds; otherwise each queued entry leaks two Dart-side descriptors and
	// strands the serveHTTPFdRequest goroutine still blocked on its Go-side
	// response conn. Closing the Dart-side fds here also unblocks that goroutine
	// (its read sees EOF, and its defers close the Go-side conns). The drain
	// runs outside once.Do and is invoked both on explicit close and again when
	// http.Serve returns, so entries that raced the `done` close (Go's select
	// can still pick the enqueue case once done is closed) are reclaimed.
	for {
		select {
		case req := <-s.requests:
			if req != nil {
				_ = unix.Close(req.RequestBodyFD)
				_ = unix.Close(req.ResponseBodyFD)
			}
		default:
			return
		}
	}
}

// HttpStart starts one tailnet HTTP request and returns private fd capabilities
// for request and response bodies.
func HttpStart(
	method string,
	rawURL string,
	headersJSON string,
	contentLength int64,
	followRedirects bool,
	maxRedirects int,
) (*HttpFdRequest, error) {
	if method == "" {
		return nil, errors.New("HTTP method is required")
	}
	if rawURL == "" {
		return nil, errors.New("HTTP URL is required")
	}

	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return nil, errors.New("HttpStart called before Start")
	}

	headers := http.Header{}
	if headersJSON != "" {
		if err := json.Unmarshal([]byte(headersJSON), &headers); err != nil {
			return nil, fmt.Errorf("decode HTTP headers: %w", err)
		}
	}

	responseDartFD, responseConn, err := newSocketPairConn()
	if err != nil {
		return nil, err
	}

	requestDartFD := -1
	var requestConn net.Conn
	if contentLength != 0 {
		requestDartFD, requestConn, err = newSocketPairConn()
		if err != nil {
			responseConn.Close()
			_ = unix.Close(responseDartFD)
			return nil, err
		}
	}

	go runHttpFdRequest(
		s,
		method,
		rawURL,
		headers,
		contentLength,
		followRedirects,
		maxRedirects,
		requestConn,
		responseConn,
	)

	return &HttpFdRequest{
		RequestBodyFD:  requestDartFD,
		ResponseBodyFD: responseDartFD,
	}, nil
}

func runHttpFdRequest(
	s *tsnet.Server,
	method string,
	rawURL string,
	headers http.Header,
	contentLength int64,
	followRedirects bool,
	maxRedirects int,
	requestConn net.Conn,
	responseConn net.Conn,
) {
	defer responseConn.Close()
	if requestConn != nil {
		defer requestConn.Close()
	}

	var body io.ReadCloser = http.NoBody
	if requestConn != nil {
		body = requestConn
	}

	req, err := http.NewRequest(method, rawURL, body)
	if err != nil {
		_ = writeHTTPResponseHead(responseConn, httpResponseHead{Error: err.Error()})
		return
	}
	req.Header = headers.Clone()
	req.ContentLength = contentLength

	// Reuse a cached transport (connection pool + TLS session cache) across
	// requests instead of building a fresh one per request. The per-request
	// bits (redirect policy) live on the Client, so only the Client is
	// per-request; the Transport is shared. See sharedTailnetTransport for the
	// identity-lifecycle guarantee.
	client := http.Client{Transport: sharedTailnetTransport(s)}
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if !followRedirects {
			return http.ErrUseLastResponse
		}
		if maxRedirects >= 0 && len(via) > maxRedirects {
			return fmt.Errorf("stopped after %d redirects", maxRedirects)
		}
		return nil
	}

	resp, err := client.Do(req)
	if err != nil {
		_ = writeHTTPResponseHead(responseConn, httpResponseHead{Error: err.Error()})
		return
	}
	defer resp.Body.Close()

	if err := writeHTTPResponseHead(responseConn, httpResponseHead{
		StatusCode: resp.StatusCode,
		// resp.Status is the full status line ("200 OK"); package:http expects
		// just the reason phrase ("OK"). Strip the leading "<code> ".
		ReasonPhrase:  strings.TrimPrefix(resp.Status, strconv.Itoa(resp.StatusCode)+" "),
		Headers:       map[string][]string(resp.Header),
		ContentLength: resp.ContentLength,
	}); err != nil {
		return
	}
	if _, err := io.Copy(responseConn, resp.Body); err != nil {
		logInfo("HTTP fd response body copy failed: %v", err)
	}
}

// httpTransportCache holds one *http.Transport (an HTTP connection pool + TLS
// session cache) and rebuilds it whenever its owner changes.
//
// The owner is the *tsnet.Server the pooled connections were dialed and
// authenticated through. This is a SECURITY boundary, not just hygiene: a
// pooled connection carries the tailnet identity that was live when it was
// dialed, so if the node logs out and back in as a different identity (a new
// *tsnet.Server), the old connections must never serve new-identity requests.
// Keying the cache on the owner guarantees a fresh, empty pool per identity;
// CloseIdleConnections on swap/reset stops the old identity's connections from
// lingering. Cross-host isolation is inherent to http.Transport (its pool is
// keyed by host:port), so a peer-A connection is never handed to a peer-B
// request.
//
// INVARIANT: the *tsnet.Server pointer is a proxy for identity. This is correct
// only because every identity change produces a *distinct* server — Start
// always allocates a fresh tsnet.Server (lib.go) and routes an existing node
// through stopLocked (reset) first, so the identity and the pointer change
// together. If a live server were ever re-authenticated in place (same pointer,
// new identity, without Start), this key would fail open and keep serving the
// old identity's connections; such a path must also reset() this cache.
type httpTransportCache struct {
	mu        sync.Mutex
	owner     any
	transport *http.Transport
}

// get returns the cached transport for [owner], building it via [build] (and
// discarding any transport from a previous owner) when the owner differs.
func (c *httpTransportCache) get(owner any, build func() *http.Transport) *http.Transport {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.transport == nil || c.owner != owner {
		if c.transport != nil {
			c.transport.CloseIdleConnections()
		}
		c.transport = build()
		c.owner = owner
	}
	return c.transport
}

// reset drops the cached transport and closes its idle connections. Called on
// node teardown so no pooled connection outlives the node/identity.
func (c *httpTransportCache) reset() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.transport != nil {
		c.transport.CloseIdleConnections()
	}
	c.transport = nil
	c.owner = nil
}

var tailnetHTTPTransports httpTransportCache

// sharedTailnetTransport returns the process-wide tailnet HTTP transport for
// server [s], rebuilding it if the server (identity) changed since last use.
func sharedTailnetTransport(s *tsnet.Server) *http.Transport {
	// Only cache the transport for the currently-published server. A request
	// whose captured `s` was already stopped/replaced (Stop reset the cache,
	// then this late goroutine arrives) gets a one-off transport instead, so it
	// can't repopulate the cache with a dead server that would then be retained
	// (with its whole netstack/wireguard graph) until the next HTTP request.
	mu.Lock()
	live := srv == s
	mu.Unlock()
	if !live {
		return buildTailnetTransport(s)
	}
	return tailnetHTTPTransports.get(s, func() *http.Transport {
		return buildTailnetTransport(s)
	})
}

func buildTailnetTransport(s *tsnet.Server) *http.Transport {
	base := s.HTTPClient()
	transport, ok := base.Transport.(*http.Transport)
	if !ok {
		// Defensive: tsnet always returns an *http.Transport today.
		return &http.Transport{DialContext: s.Dial}
	}
	return applyTailnetTLS(transport)
}

// applyTailnetTLS returns a clone of [base] with Tailscale's outbound TLS policy
// applied (system roots first, then baked-in Let's Encrypt roots as a fallback
// for constrained platforms). The input is left untouched.
func applyTailnetTLS(base *http.Transport) *http.Transport {
	cloned := base.Clone()
	cloned.TLSClientConfig = tlsdial.Config(nil, cloned.TLSClientConfig)
	return cloned
}

// resetTailnetHTTPTransport drops the cached HTTP transport and closes its idle
// connections. Called from stopLocked so pooled connections never survive a
// node/identity change.
func resetTailnetHTTPTransport() {
	tailnetHTTPTransports.reset()
}

func serveHTTPFdRequest(state *httpBindingState, w http.ResponseWriter, r *http.Request) {
	// HTTP/1 handlers normally need to read the request body before writing
	// the response. Dart handlers may choose to answer without consuming the
	// full body, so explicitly opt into full-duplex where Go supports it.
	_ = http.NewResponseController(w).EnableFullDuplex()

	requestDartFD, requestConn, err := newSocketPairConn()
	if err != nil {
		http.Error(w, "Failed to allocate request body fd", http.StatusInternalServerError)
		return
	}
	responseDartFD, responseConn, err := newSocketPairConn()
	if err != nil {
		_ = requestConn.Close()
		_ = unix.Close(requestDartFD)
		http.Error(w, "Failed to allocate response body fd", http.StatusInternalServerError)
		return
	}

	remoteAddress, remotePort := endpointFromAddrString(r.RemoteAddr)
	var localAddress string
	var localPort int
	if localAddr, ok := r.Context().Value(http.LocalAddrContextKey).(net.Addr); ok {
		localAddress, localPort = endpointFromAddr(localAddr)
	}
	incoming := &HttpIncomingRequest{
		BindingID:      state.binding.ID,
		RequestBodyFD:  requestDartFD,
		ResponseBodyFD: responseDartFD,
		Method:         r.Method,
		RequestURI:     r.URL.RequestURI(),
		Host:           r.Host,
		Proto:          r.Proto,
		Headers:        map[string][]string(r.Header.Clone()),
		ContentLength:  r.ContentLength,
		RemoteAddress:  remoteAddress,
		RemotePort:     remotePort,
		LocalAddress:   localAddress,
		LocalPort:      localPort,
		// Best-effort, like the TCP accept path: a nil result still delivers
		// the request (IP-only). A map read against the netmap identity cache
		// once warm; only the brief cold-cache window falls back to a live
		// WhoIs (bounded by identityLookupTimeout).
		Identity: lookupNodeIdentity(remoteAddress),
	}

	select {
	case state.requests <- incoming:
	default:
		_ = requestConn.Close()
		_ = responseConn.Close()
		_ = unix.Close(requestDartFD)
		_ = unix.Close(responseDartFD)
		http.Error(w, "HTTP accept backlog full", http.StatusServiceUnavailable)
		return
	case <-state.done:
		_ = requestConn.Close()
		_ = responseConn.Close()
		_ = unix.Close(requestDartFD)
		_ = unix.Close(responseDartFD)
		http.Error(w, "HTTP binding closed", http.StatusServiceUnavailable)
		return
	case <-r.Context().Done():
		_ = requestConn.Close()
		_ = responseConn.Close()
		_ = unix.Close(requestDartFD)
		_ = unix.Close(responseDartFD)
		return
	}

	// The inner Close signals EOF on the request body fd to the Dart handler
	// when the inbound body finishes naturally. The outer Close unblocks the
	// goroutine if the Dart handler returns without draining the body.
	go func() {
		defer requestConn.Close()
		_, _ = io.Copy(requestConn, r.Body)
	}()
	defer requestConn.Close()
	defer responseConn.Close()

	if err := writeDartHTTPResponse(w, responseConn); err != nil {
		logInfo("HTTP fd response failed: %v", err)
		return
	}
}

func writeDartHTTPResponse(w http.ResponseWriter, r io.Reader) error {
	head, err := readHTTPResponseHead(r)
	if err != nil {
		http.Error(w, "Failed to read Dart HTTP response", http.StatusBadGateway)
		return err
	}
	if head.Error != "" {
		http.Error(w, head.Error, http.StatusInternalServerError)
		return nil
	}

	statusCode := head.StatusCode
	if statusCode == 0 {
		statusCode = http.StatusOK
	}
	if statusCode < 100 || statusCode > 999 {
		statusCode = http.StatusInternalServerError
	}

	for key, values := range head.Headers {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}
	w.WriteHeader(statusCode)
	return flushDartHTTPBody(w, r)
}

// flushDartHTTPBody streams the Dart handler's response body to the wire,
// flushing after each chunk. net/http buffers small writes and won't emit them
// until the buffer fills or the handler returns, which stalls streaming
// handlers (SSE, long-poll) that emit small events over time. Flushing each
// chunk delivers them promptly. Uses the shared 64 KiB buffer pool rather than
// io.Copy's per-call 32 KiB allocation.
func flushDartHTTPBody(w http.ResponseWriter, r io.Reader) error {
	flusher, _ := w.(http.Flusher)
	bufp := pipeBufferPool.Get().(*[]byte)
	defer pipeBufferPool.Put(bufp)
	buf := *bufp
	for {
		n, readErr := r.Read(buf)
		if n > 0 {
			if _, writeErr := w.Write(buf[:n]); writeErr != nil {
				return writeErr
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if readErr != nil {
			if readErr == io.EOF {
				return nil
			}
			return readErr
		}
	}
}

func readHTTPResponseHead(r io.Reader) (httpResponseHead, error) {
	var prefix [4]byte
	if _, err := io.ReadFull(r, prefix[:]); err != nil {
		return httpResponseHead{}, err
	}
	length := binary.BigEndian.Uint32(prefix[:])
	if length == 0 || length > httpMaxHeadBytes {
		return httpResponseHead{}, fmt.Errorf("invalid HTTP response head length %d", length)
	}

	payload := make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		return httpResponseHead{}, err
	}

	var head httpResponseHead
	if err := json.Unmarshal(payload, &head); err != nil {
		return httpResponseHead{}, err
	}
	return head, nil
}

func writeHTTPResponseHead(w io.Writer, head httpResponseHead) error {
	payload, err := json.Marshal(head)
	if err != nil {
		return err
	}
	if len(payload) > httpMaxHeadBytes {
		return fmt.Errorf("HTTP response head too large: %d bytes", len(payload))
	}

	var prefix [4]byte
	binary.BigEndian.PutUint32(prefix[:], uint32(len(payload)))
	if _, err := w.Write(prefix[:]); err != nil {
		return err
	}
	_, err = w.Write(payload)
	return err
}

func endpointFromAddrString(addr string) (string, int) {
	host, portText, err := net.SplitHostPort(addr)
	if err != nil {
		return addr, 0
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 0 || port > 65535 {
		return host, 0
	}
	return host, port
}
