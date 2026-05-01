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
	"sync"
	"sync/atomic"

	"golang.org/x/sys/unix"
	"tailscale.com/net/tlsdial"
	"tailscale.com/tsnet"
)

const httpAcceptBacklog = 128

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
}

type httpResponseHead struct {
	StatusCode    int                 `json:"statusCode,omitempty"`
	ReasonPhrase  string              `json:"reasonPhrase,omitempty"`
	Headers       map[string][]string `json:"headers,omitempty"`
	ContentLength int64               `json:"contentLength,omitempty"`
	Error         string              `json:"error,omitempty"`
}

type httpBindingState struct {
	binding  HttpBinding
	ln       net.Listener
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
		_ = http.Serve(ln, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			serveHTTPFdRequest(state, w, r)
		}))
		state.close()
		httpBindingMu.Lock()
		if httpBindingRegistry[id] == state {
			delete(httpBindingRegistry, id)
		}
		httpBindingMu.Unlock()
	}()

	return &state.binding, nil
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
		_ = s.ln.Close()
	})
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

	client := tailnetHTTPClient(s.HTTPClient())
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
		StatusCode:    resp.StatusCode,
		ReasonPhrase:  resp.Status,
		Headers:       map[string][]string(resp.Header),
		ContentLength: resp.ContentLength,
	}); err != nil {
		return
	}
	if _, err := io.Copy(responseConn, resp.Body); err != nil {
		logInfo("HTTP fd response body copy failed: %v", err)
	}
}

func tailnetHTTPClient(baseClient *http.Client) http.Client {
	client := *baseClient
	if transport, ok := baseClient.Transport.(*http.Transport); ok {
		cloned := transport.Clone()
		// Match Tailscale's own outbound TLS policy: system roots first, then
		// baked-in Let's Encrypt roots as a fallback for constrained platforms.
		cloned.TLSClientConfig = tlsdial.Config(nil, cloned.TLSClientConfig)
		client.Transport = cloned
	}
	return client
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
	_, err = io.Copy(w, r)
	return err
}

func readHTTPResponseHead(r io.Reader) (httpResponseHead, error) {
	var prefix [4]byte
	if _, err := io.ReadFull(r, prefix[:]); err != nil {
		return httpResponseHead{}, err
	}
	length := binary.BigEndian.Uint32(prefix[:])
	if length == 0 || length > 16*1024*1024 {
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
	if len(payload) > 16*1024*1024 {
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
