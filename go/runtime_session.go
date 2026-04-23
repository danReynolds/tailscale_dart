package tailscale

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"sync"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/client/tailscale/apitype"
	"tailscale.com/tsnet"
)

const (
	transportProtocolVersion     = 1
	transportInitialStreamCredit = 64 * 1024
	transportMaxDataPayload      = 60 * 1024
	transportMaxDatagramPayload  = 60 * 1024
	transportAttachTimeout       = 10 * time.Second
	transportHandshakeTimeout    = 5 * time.Second
	transportGoAwayDrainTimeout  = 30 * time.Second
	transportWriterQueueCap      = 256
	transportConnWriteQueueCap   = 64

	transportStateIdle        = "idle"
	transportStateAttaching   = "attaching"
	transportStateHandshaking = "handshaking"
	transportStateOpen        = "open"
	transportStateClosing     = "closing"
	transportStateClosed      = "closed"
)

const (
	transportFrameOpen uint8 = iota + 1
	transportFrameData
	transportFrameCredit
	transportFrameFin
	transportFrameRst
	transportFrameBind
	transportFrameDgram
	transportFrameBindClose
	transportFrameBindAbort
	transportFrameGoAway
	transportFrameSessionConfirm
)

type runtimeTransportBootstrap struct {
	MasterSecretB64      string `json:"masterSecretB64"`
	SessionGenerationB64 string `json:"sessionGenerationIdB64"`
	PreferredCarrierKind string `json:"preferredCarrierKind"`
}

type runtimeAttachRequest struct {
	CarrierKind   string `json:"carrierKind"`
	ListenerOwner string `json:"listenerOwner"`
	Host          string `json:"host,omitempty"`
	Port          int    `json:"port,omitempty"`
	Path          string `json:"path,omitempty"`
}

type runtimeOpenPayload struct {
	StreamID  uint64           `json:"streamId"`
	Transport string           `json:"transport"`
	Local     runtimeEndpoint  `json:"local"`
	Remote    runtimeEndpoint  `json:"remote"`
	Identity  *runtimeIdentity `json:"identity,omitempty"`
}

type runtimeIdentity struct {
	StableNodeID    string `json:"stableNodeId,omitempty"`
	NodeName        string `json:"nodeName,omitempty"`
	UserLogin       string `json:"userLogin,omitempty"`
	UserDisplayName string `json:"userDisplayName,omitempty"`
}

type runtimeEndpoint struct {
	IP   string `json:"ip"`
	Port int    `json:"port"`
}

type runtimeBindPayload struct {
	BindingID uint64          `json:"bindingId"`
	Transport string          `json:"transport"`
	Local     runtimeEndpoint `json:"local"`
}

type runtimeDgramPayload struct {
	BindingID uint64           `json:"bindingId"`
	Remote    runtimeEndpoint  `json:"remote"`
	DataB64   string           `json:"dataB64"`
	Identity  *runtimeIdentity `json:"identity,omitempty"`
}

type runtimeOutboundFrame struct {
	kind    uint8
	payload []byte
}

type runtimeConnWriteOpKind uint8

const (
	runtimeConnWriteData runtimeConnWriteOpKind = iota + 1
	runtimeConnWriteFin
)

type runtimeConnWriteOp struct {
	kind runtimeConnWriteOpKind
	data []byte
}

type runtimeTcpListener struct {
	port int
	ln   net.Listener
	done chan struct{}
}

type runtimeDatagramBinding struct {
	id        uint64
	local     runtimeEndpoint
	transport string
	pc        net.PacketConn

	mu      sync.Mutex
	closed  bool
	aborted bool
}

type runtimeStream struct {
	id        uint64
	conn      net.Conn
	local     runtimeEndpoint
	remote    runtimeEndpoint
	identity  *runtimeIdentity
	outbound  int64
	transport string

	mu           sync.Mutex
	writeClosing bool
	writeClosed  bool
	readClosed   bool
	closed       bool
	reset        bool
	cond         *sync.Cond

	writeQueue chan runtimeConnWriteOp
}

type runtimeTransportSession struct {
	mu sync.Mutex

	state               string
	preferredCarrier    string
	listenerOwner       string
	listenerHost        string
	listenerPort        int
	listenerPath        string
	attachDeadline      time.Time
	connectedAt         time.Time
	lastError           string
	masterSecret        []byte
	sessionGenerationID []byte

	conn        net.Conn
	readerDone  chan struct{}
	writerDone  chan struct{}
	writerQ     chan runtimeOutboundFrame
	goAwayTimer *time.Timer

	handshakeKey       []byte
	sessionKey         []byte
	dartToGoKey        []byte
	goToDartKey        []byte
	sendSeq            uint64
	recvSeq            uint64
	goAwayDrainTimeout time.Duration

	nextInboundStreamID  uint64
	nextOutboundStreamID uint64
	nextBindingID        uint64
	streams              map[uint64]*runtimeStream
	tcpListeners         map[int]*runtimeTcpListener
	bindings             map[uint64]*runtimeDatagramBinding
	localClient          *local.Client
}

var transportSession *runtimeTransportSession

func RuntimeTransportBootstrap() *runtimeTransportBootstrap {
	mu.Lock()
	defer mu.Unlock()
	return runtimeTransportBootstrapLocked()
}

func ensureRuntimeTransportLocked() {
	if transportSession != nil {
		return
	}
	masterSecret := make([]byte, 32)
	_, _ = rand.Read(masterSecret)
	sessionGenerationID := make([]byte, 16)
	_, _ = rand.Read(sessionGenerationID)
	transportSession = &runtimeTransportSession{
		state:                transportStateIdle,
		preferredCarrier:     "loopback_tcp",
		masterSecret:         masterSecret,
		sessionGenerationID:  sessionGenerationID,
		nextInboundStreamID:  2,
		nextOutboundStreamID: 1,
		nextBindingID:        2,
		streams:              map[uint64]*runtimeStream{},
		tcpListeners:         map[int]*runtimeTcpListener{},
		bindings:             map[uint64]*runtimeDatagramBinding{},
	}
}

func runtimeTransportBootstrapLocked() *runtimeTransportBootstrap {
	if transportSession == nil {
		return nil
	}
	return &runtimeTransportBootstrap{
		MasterSecretB64:      base64.RawURLEncoding.EncodeToString(transportSession.masterSecret),
		SessionGenerationB64: base64.RawURLEncoding.EncodeToString(transportSession.sessionGenerationID),
		PreferredCarrierKind: transportSession.preferredCarrier,
	}
}

func closeRuntimeTransportLocked() {
	if transportSession == nil {
		return
	}
	transportSession.closeLocked()
	transportSession = nil
}

func AttachRuntimeTransport(reqJSON string) error {
	mu.Lock()
	rt := transportSession
	mu.Unlock()
	if rt == nil {
		return errors.New("transport session not bootstrapped")
	}
	return rt.attach(reqJSON)
}

func TCPBind(port int) error {
	mu.Lock()
	s := srv
	rt := transportSession
	mu.Unlock()
	if s == nil {
		return errors.New("tcp.bind called before Start")
	}
	if rt == nil {
		return errors.New("transport session not bootstrapped")
	}
	return rt.bindTCP(s, port)
}

func TCPUnbind(port int) error {
	mu.Lock()
	rt := transportSession
	mu.Unlock()
	if rt == nil {
		return errors.New("transport session not bootstrapped")
	}
	return rt.unbindTCP(port)
}

func TCPDial(host string, port int) (uint64, error) {
	mu.Lock()
	s := srv
	rt := transportSession
	mu.Unlock()
	if s == nil {
		return 0, errors.New("tcp.dial called before Start")
	}
	if rt == nil {
		return 0, errors.New("transport session not bootstrapped")
	}
	return rt.dialTCP(s, host, port)
}

func UDPBind(port int) (uint64, error) {
	mu.Lock()
	s := srv
	rt := transportSession
	mu.Unlock()
	if s == nil {
		return 0, errors.New("udp.bind called before Start")
	}
	if rt == nil {
		return 0, errors.New("transport session not bootstrapped")
	}
	return rt.bindUDP(s, port)
}

func (rt *runtimeTransportSession) attach(reqJSON string) error {
	var req runtimeAttachRequest
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		return err
	}
	if req.CarrierKind != "loopback_tcp" {
		return fmt.Errorf("unsupported carrier kind %q", req.CarrierKind)
	}

	rt.mu.Lock()
	defer rt.mu.Unlock()
	if err := rt.requireIdleLocked("attach"); err != nil {
		return err
	}
	if req.ListenerOwner == "" {
		req.ListenerOwner = "dart"
	}
	rt.listenerOwner = req.ListenerOwner
	rt.listenerHost = req.Host
	rt.listenerPort = req.Port
	rt.listenerPath = req.Path
	rt.attachDeadline = time.Now().Add(transportAttachTimeout)
	rt.state = transportStateAttaching
	go rt.attachLoopback()
	return nil
}

func (rt *runtimeTransportSession) requireIdleLocked(op string) error {
	if rt.state != transportStateIdle {
		return fmt.Errorf("%s invalid in state %s", op, rt.state)
	}
	return nil
}

func (rt *runtimeTransportSession) requireOpenLocked(scope string) error {
	if rt.state != transportStateOpen {
		return fmt.Errorf("transport session not open for %s: %s", scope, rt.state)
	}
	return nil
}

func (rt *runtimeTransportSession) requireOperationalLocked() error {
	if rt.state != transportStateOpen && rt.state != transportStateClosing {
		return fmt.Errorf("transport session not open: %s", rt.state)
	}
	return nil
}

func (rt *runtimeTransportSession) bindTCP(s *tsnet.Server, port int) error {
	if port < 1 || port > 65535 {
		return fmt.Errorf("invalid tcp port %d", port)
	}

	rt.mu.Lock()
	if err := rt.requireOpenLocked("new listeners"); err != nil {
		rt.mu.Unlock()
		return err
	}
	if _, ok := rt.tcpListeners[port]; ok {
		rt.mu.Unlock()
		return nil
	}
	rt.mu.Unlock()

	ln, err := s.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		return err
	}

	listener := &runtimeTcpListener{
		port: port,
		ln:   ln,
		done: make(chan struct{}),
	}

	rt.mu.Lock()
	rt.tcpListeners[port] = listener
	rt.mu.Unlock()

	go rt.acceptLoop(listener)
	return nil
}

func (rt *runtimeTransportSession) unbindTCP(port int) error {
	rt.mu.Lock()
	listener := rt.tcpListeners[port]
	if listener != nil {
		delete(rt.tcpListeners, port)
	}
	rt.mu.Unlock()

	if listener == nil {
		return nil
	}
	return listener.ln.Close()
}

func (rt *runtimeTransportSession) bindUDP(s *tsnet.Server, port int) (uint64, error) {
	if port < 1 || port > 65535 {
		return 0, fmt.Errorf("invalid udp port %d", port)
	}

	rt.mu.Lock()
	if err := rt.requireOpenLocked("new bindings"); err != nil {
		rt.mu.Unlock()
		return 0, err
	}
	rt.mu.Unlock()

	listenAddr, err := rt.localUDPEndpoint(port)
	if err != nil {
		return 0, err
	}

	pc, err := s.ListenPacket("udp", listenAddr)
	if err != nil {
		return 0, err
	}

	binding := &runtimeDatagramBinding{
		local:     endpointFromAddr(pc.LocalAddr()),
		transport: "udp",
		pc:        pc,
	}

	rt.mu.Lock()
	if err := rt.requireOpenLocked("new bindings"); err != nil {
		rt.mu.Unlock()
		_ = pc.Close()
		return 0, err
	}
	binding.id = rt.nextBindingID
	rt.nextBindingID += 2
	rt.bindings[binding.id] = binding
	rt.mu.Unlock()

	payload, err := json.Marshal(runtimeBindPayload{
		BindingID: binding.id,
		Transport: binding.transport,
		Local:     binding.local,
	})
	if err != nil {
		rt.dropBinding(binding.id, false)
		return 0, err
	}
	if err := rt.enqueueFrame(transportFrameBind, payload); err != nil {
		rt.dropBinding(binding.id, false)
		return 0, err
	}

	go rt.bindingReadLoop(binding)
	return binding.id, nil
}

func (rt *runtimeTransportSession) localUDPEndpoint(port int) (string, error) {
	lc, err := rt.getLocalClient()
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	status, err := lc.StatusWithoutPeers(ctx)
	if err != nil {
		return "", err
	}
	if status == nil {
		return "", errors.New("local status unavailable")
	}
	for _, addr := range status.TailscaleIPs {
		if addr.Is4() {
			return net.JoinHostPort(addr.String(), strconv.Itoa(port)), nil
		}
	}
	for _, addr := range status.TailscaleIPs {
		if addr.Is6() {
			return net.JoinHostPort(addr.String(), strconv.Itoa(port)), nil
		}
	}
	return "", errors.New("no tailscale IP assigned")
}

func (rt *runtimeTransportSession) dialTCP(s *tsnet.Server, host string, port int) (uint64, error) {
	if port < 1 || port > 65535 {
		return 0, fmt.Errorf("invalid tcp port %d", port)
	}

	rt.mu.Lock()
	if err := rt.requireOpenLocked("new streams"); err != nil {
		rt.mu.Unlock()
		return 0, err
	}
	streamID := rt.nextOutboundStreamID
	rt.nextOutboundStreamID += 2
	rt.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn, err := s.Dial(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		return 0, err
	}

	if err := rt.registerStream(streamID, conn, "tcp"); err != nil {
		_ = conn.Close()
		return 0, err
	}
	return streamID, nil
}

func (rt *runtimeTransportSession) registerStream(streamID uint64, conn net.Conn, transport string) error {
	localEndpoint := endpointFromAddr(conn.LocalAddr())
	remoteEndpoint := endpointFromAddr(conn.RemoteAddr())
	identity := rt.lookupIdentity("tcp", conn.RemoteAddr().String())

	st := &runtimeStream{
		id:         streamID,
		conn:       conn,
		local:      localEndpoint,
		remote:     remoteEndpoint,
		identity:   identity,
		outbound:   transportInitialStreamCredit,
		transport:  transport,
		writeQueue: make(chan runtimeConnWriteOp, transportConnWriteQueueCap),
	}
	st.cond = sync.NewCond(&st.mu)

	rt.mu.Lock()
	if err := rt.requireOpenLocked("new streams"); err != nil {
		rt.mu.Unlock()
		return err
	}
	rt.streams[streamID] = st
	rt.mu.Unlock()

	payload, err := json.Marshal(runtimeOpenPayload{
		StreamID:  streamID,
		Transport: transport,
		Local:     localEndpoint,
		Remote:    remoteEndpoint,
		Identity:  identity,
	})
	if err != nil {
		rt.dropStream(streamID)
		return err
	}
	if err := rt.enqueueFrame(transportFrameOpen, payload); err != nil {
		rt.dropStream(streamID)
		return err
	}

	go rt.streamConnWriterLoop(st)
	go rt.streamConnReaderLoop(st)
	return nil
}

func (rt *runtimeTransportSession) acceptLoop(listener *runtimeTcpListener) {
	defer close(listener.done)
	for {
		conn, err := listener.ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			rt.failSession("tcp_accept:" + err.Error())
			return
		}
		rt.mu.Lock()
		streamID := rt.nextInboundStreamID
		rt.nextInboundStreamID += 2
		rt.mu.Unlock()
		if err := rt.registerStream(streamID, conn, "tcp"); err != nil {
			_ = conn.Close()
			rt.failSession("stream_register:" + err.Error())
			return
		}
	}
}

func (rt *runtimeTransportSession) streamConnWriterLoop(st *runtimeStream) {
	for op := range st.writeQueue {
		switch op.kind {
		case runtimeConnWriteData:
			if _, err := st.conn.Write(op.data); err != nil {
				rt.sendRstAndDropStream(st.id)
				return
			}
			rt.grantCredit(st.id, len(op.data))
		case runtimeConnWriteFin:
			if cw, ok := st.conn.(interface{ CloseWrite() error }); ok {
				_ = cw.CloseWrite()
			} else {
				_ = st.conn.Close()
			}
			rt.markStreamWriteClosed(st)
			return
		}
	}
}

func (rt *runtimeTransportSession) streamConnReaderLoop(st *runtimeStream) {
	buffer := make([]byte, transportMaxDataPayload)
	for {
		n, err := st.conn.Read(buffer)
		if n > 0 {
			if writeErr := rt.writeStreamData(st, buffer[:n]); writeErr != nil {
				rt.failSession("stream_write_data:" + writeErr.Error())
				return
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				_ = rt.enqueueFrame(transportFrameFin, u64Bytes(st.id))
				rt.markStreamReadClosed(st)
				return
			}
			rt.sendRstAndDropStream(st.id)
			return
		}
	}
}

func (rt *runtimeTransportSession) bindingReadLoop(binding *runtimeDatagramBinding) {
	buffer := make([]byte, transportMaxDatagramPayload)
	for {
		n, remoteAddr, err := binding.pc.ReadFrom(buffer)
		if n > 0 {
			data := append([]byte(nil), buffer[:n]...)
			payload, marshalErr := json.Marshal(runtimeDgramPayload{
				BindingID: binding.id,
				Remote:    endpointFromAddr(remoteAddr),
				DataB64:   base64.RawURLEncoding.EncodeToString(data),
				Identity:  rt.lookupIdentity("udp", remoteAddr.String()),
			})
			if marshalErr != nil {
				rt.failSession("binding_marshal:" + marshalErr.Error())
				return
			}
			ok, enqueueErr := rt.tryEnqueueFrame(transportFrameDgram, payload)
			if enqueueErr != nil {
				if rt.isOperational() {
					rt.failSession("binding_enqueue:" + enqueueErr.Error())
				}
				return
			}
			if !ok {
				continue
			}
		}
		if err != nil {
			if errors.Is(err, net.ErrClosed) || binding.isClosed() {
				return
			}
			rt.failSession("binding_read:" + err.Error())
			return
		}
	}
}

func (rt *runtimeTransportSession) writeStreamData(st *runtimeStream, data []byte) error {
	offset := 0
	for offset < len(data) {
		st.mu.Lock()
		for st.outbound <= 0 && !st.reset && rt.isOperational() {
			st.cond.Wait()
		}
		if st.reset || !rt.isOperational() {
			st.mu.Unlock()
			return errors.New("stream reset or session closed")
		}
		allowed := len(data) - offset
		if allowed > transportMaxDataPayload {
			allowed = transportMaxDataPayload
		}
		if allowed > int(st.outbound) {
			allowed = int(st.outbound)
		}
		st.outbound -= int64(allowed)
		st.mu.Unlock()

		payload := make([]byte, 8+allowed)
		binary.BigEndian.PutUint64(payload[:8], st.id)
		copy(payload[8:], data[offset:offset+allowed])
		if err := rt.enqueueFrame(transportFrameData, payload); err != nil {
			return err
		}
		offset += allowed
	}
	return nil
}

func (rt *runtimeTransportSession) grantCredit(streamID uint64, amount int) {
	if amount <= 0 {
		return
	}
	payload := make([]byte, 12)
	binary.BigEndian.PutUint64(payload[:8], streamID)
	binary.BigEndian.PutUint32(payload[8:12], uint32(amount))
	_ = rt.enqueueFrame(transportFrameCredit, payload)
}

func (rt *runtimeTransportSession) attachLoopback() {
	rt.mu.Lock()
	host := rt.listenerHost
	port := rt.listenerPort
	deadline := rt.attachDeadline
	rt.mu.Unlock()

	if host == "" {
		host = "127.0.0.1"
	}
	timeout := time.Until(deadline)
	if timeout <= 0 {
		rt.failSession("carrier_attach_timeout")
		return
	}

	conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(port)), timeout)
	if err != nil {
		rt.failSession("attach_dial_failed:" + err.Error())
		return
	}
	if err := conn.SetDeadline(time.Now().Add(transportHandshakeTimeout)); err != nil {
		_ = conn.Close()
		rt.failSession("set_deadline_failed:" + err.Error())
		return
	}
	if err := rt.performHandshake(conn); err != nil {
		_ = conn.Close()
		rt.failSession("handshake_failed:" + err.Error())
		return
	}
	_ = conn.SetDeadline(time.Time{})

	rt.mu.Lock()
	if rt.state == transportStateClosed {
		rt.mu.Unlock()
		_ = conn.Close()
		return
	}
	rt.conn = conn
	rt.connectedAt = time.Now()
	rt.writerQ = make(chan runtimeOutboundFrame, transportWriterQueueCap)
	rt.readerDone = make(chan struct{})
	rt.writerDone = make(chan struct{})
	rt.state = transportStateOpen
	if err := rt.enqueueFrameLocked(transportFrameSessionConfirm, nil); err != nil {
		rt.mu.Unlock()
		_ = conn.Close()
		rt.failSession("session_confirm_enqueue_failed:" + err.Error())
		return
	}
	rt.mu.Unlock()

	go rt.writerLoop()
	go rt.readerLoop()
}

func (rt *runtimeTransportSession) performHandshake(conn net.Conn) error {
	clientNonce := make([]byte, 16)
	if _, err := rand.Read(clientNonce); err != nil {
		return err
	}

	handshakeKey := hkdfExtract(rt.sessionGenerationID, rt.masterSecret)
	clientHelloCanonical := canonicalLines(map[string]string{
		"msg":                       "CLIENT_HELLO",
		"session_protocol_versions": strconv.Itoa(transportProtocolVersion),
		"client_nonce_b64":          base64.RawURLEncoding.EncodeToString(clientNonce),
		"session_generation_id_b64": base64.RawURLEncoding.EncodeToString(rt.sessionGenerationID),
		"carrier_kind":              rt.preferredCarrier,
		"listener_owner":            rt.listenerOwner,
		"listener_endpoint":         rt.listenerEndpoint(),
		"requested_capabilities":    "",
	})
	clientMac := hmacSHA256(handshakeKey, clientHelloCanonical)
	clientHello := spikeHelloEnvelope{
		Type:                "CLIENT_HELLO",
		SessionVersions:     []int{transportProtocolVersion},
		ClientNonceB64:      base64.RawURLEncoding.EncodeToString(clientNonce),
		SessionGenerationID: base64.RawURLEncoding.EncodeToString(rt.sessionGenerationID),
		CarrierKind:         rt.preferredCarrier,
		ListenerOwner:       rt.listenerOwner,
		ListenerEndpoint:    rt.listenerEndpoint(),
		RequestedCaps:       []string{},
		MacB64:              base64.RawURLEncoding.EncodeToString(clientMac),
	}
	if err := writeLengthPrefixedJSON(conn, clientHello); err != nil {
		return err
	}

	var serverHello spikeHelloEnvelope
	if err := readLengthPrefixedJSON(conn, &serverHello); err != nil {
		return err
	}
	if serverHello.Type != "SERVER_HELLO" {
		return fmt.Errorf("unexpected handshake message %q", serverHello.Type)
	}
	if serverHello.SelectedVersion != transportProtocolVersion {
		return fmt.Errorf("unexpected selected version %d", serverHello.SelectedVersion)
	}
	if serverHello.SessionGenerationID != base64.RawURLEncoding.EncodeToString(rt.sessionGenerationID) {
		return errors.New("session generation mismatch")
	}
	if serverHello.CarrierKind != rt.preferredCarrier ||
		serverHello.ListenerOwner != rt.listenerOwner ||
		serverHello.ListenerEndpoint != rt.listenerEndpoint() {
		return errors.New("carrier binding mismatch")
	}
	if len(serverHello.AcceptedCaps) != 0 {
		return errors.New("unexpected accepted capabilities")
	}

	serverHelloCanonical := canonicalLines(map[string]string{
		"msg":                       "SERVER_HELLO",
		"selected_version":          strconv.Itoa(serverHello.SelectedVersion),
		"client_nonce_b64":          clientHello.ClientNonceB64,
		"server_nonce_b64":          serverHello.ServerNonceB64,
		"session_generation_id_b64": clientHello.SessionGenerationID,
		"carrier_kind":              rt.preferredCarrier,
		"listener_owner":            rt.listenerOwner,
		"listener_endpoint":         rt.listenerEndpoint(),
		"accepted_capabilities":     "",
	})
	expectedServerMac := hmacSHA256(
		handshakeKey,
		appendWithNull(clientHelloCanonical, serverHelloCanonical),
	)
	serverMac, err := base64.RawURLEncoding.DecodeString(serverHello.MacB64)
	if err != nil {
		return err
	}
	if !hmac.Equal(serverMac, expectedServerMac) {
		return errors.New("bad server hello mac")
	}

	transcriptHash := sha256.Sum256(appendWithNull(clientHelloCanonical, serverHelloCanonical))
	sessionSecret := hkdfExpand(
		handshakeKey,
		append([]byte("tailscale_dart:v1:session"), transcriptHash[:]...),
		32,
	)

	rt.mu.Lock()
	rt.handshakeKey = handshakeKey
	rt.sessionKey = sessionSecret
	rt.dartToGoKey = hkdfExpand(sessionSecret, []byte("tailscale_dart:v1:dart_to_go_frame"), 32)
	rt.goToDartKey = hkdfExpand(sessionSecret, []byte("tailscale_dart:v1:go_to_dart_frame"), 32)
	rt.state = transportStateHandshaking
	rt.mu.Unlock()
	return nil
}

func (rt *runtimeTransportSession) readerLoop() {
	defer close(rt.readerDone)
	for {
		rt.mu.Lock()
		conn := rt.conn
		rt.mu.Unlock()
		if conn == nil {
			return
		}
		headerBytes := make([]byte, 16)
		if _, err := io.ReadFull(conn, headerBytes); err != nil {
			rt.failSession("reader_error:" + err.Error())
			return
		}
		payloadLen := binary.BigEndian.Uint32(headerBytes[12:16])
		payload := make([]byte, payloadLen)
		if _, err := io.ReadFull(conn, payload); err != nil {
			rt.failSession("reader_payload_error:" + err.Error())
			return
		}
		macBytes := make([]byte, 32)
		if _, err := io.ReadFull(conn, macBytes); err != nil {
			rt.failSession("reader_mac_error:" + err.Error())
			return
		}
		if headerBytes[0] != transportProtocolVersion {
			rt.failSession(fmt.Sprintf("bad_frame_version:%d", headerBytes[0]))
			return
		}

		rt.mu.Lock()
		key := append([]byte(nil), rt.dartToGoKey...)
		expectedSeq := rt.recvSeq + 1
		rt.mu.Unlock()

		gotSeq := binary.BigEndian.Uint64(headerBytes[4:12])
		if gotSeq != expectedSeq {
			rt.failSession(fmt.Sprintf("bad_sequence:%d_expected:%d", gotSeq, expectedSeq))
			return
		}
		expectedMac := hmacSHA256(key, append(headerBytes, payload...))
		if !hmac.Equal(macBytes, expectedMac) {
			rt.failSession("bad_frame_mac")
			return
		}

		rt.mu.Lock()
		rt.recvSeq = gotSeq
		rt.mu.Unlock()

		if err := rt.handleFrame(headerBytes[1], payload); err != nil {
			rt.failSession("handle_frame:" + err.Error())
			return
		}
	}
}

func (rt *runtimeTransportSession) writerLoop() {
	defer close(rt.writerDone)
	for frame := range rt.writerQ {
		rt.mu.Lock()
		if rt.conn == nil {
			rt.mu.Unlock()
			return
		}
		rt.sendSeq++
		seq := rt.sendSeq
		key := append([]byte(nil), rt.goToDartKey...)
		conn := rt.conn
		rt.mu.Unlock()

		header := make([]byte, 16)
		header[0] = transportProtocolVersion
		header[1] = frame.kind
		binary.BigEndian.PutUint64(header[4:12], seq)
		binary.BigEndian.PutUint32(header[12:16], uint32(len(frame.payload)))
		macBytes := hmacSHA256(key, append(header, frame.payload...))
		if _, err := conn.Write(header); err != nil {
			rt.failSession("writer_header_error:" + err.Error())
			return
		}
		if len(frame.payload) > 0 {
			if _, err := conn.Write(frame.payload); err != nil {
				rt.failSession("writer_payload_error:" + err.Error())
				return
			}
		}
		if _, err := conn.Write(macBytes); err != nil {
			rt.failSession("writer_mac_error:" + err.Error())
			return
		}
	}
}

func (rt *runtimeTransportSession) handleFrame(kind uint8, payload []byte) error {
	switch kind {
	case transportFrameData:
		if len(payload) < 8 {
			return errors.New("invalid data payload")
		}
		streamID := binary.BigEndian.Uint64(payload[:8])
		rt.mu.Lock()
		st := rt.streams[streamID]
		rt.mu.Unlock()
		if st == nil {
			return errors.New("data before open")
		}
		st.mu.Lock()
		if st.writeClosing || st.writeClosed || st.closed {
			st.mu.Unlock()
			return errors.New("data after fin")
		}
		writeQueue := st.writeQueue
		st.mu.Unlock()
		if writeQueue == nil {
			return errors.New("stream write queue unavailable")
		}
		data := append([]byte(nil), payload[8:]...)
		select {
		case writeQueue <- runtimeConnWriteOp{kind: runtimeConnWriteData, data: data}:
			return nil
		default:
			return errors.New("stream write queue full")
		}
	case transportFrameCredit:
		if len(payload) != 12 {
			return errors.New("invalid credit payload")
		}
		streamID := binary.BigEndian.Uint64(payload[:8])
		credit := binary.BigEndian.Uint32(payload[8:12])
		rt.mu.Lock()
		st := rt.streams[streamID]
		rt.mu.Unlock()
		if st == nil {
			return nil
		}
		st.mu.Lock()
		st.outbound += int64(credit)
		st.cond.Broadcast()
		st.mu.Unlock()
		return nil
	case transportFrameFin:
		if len(payload) != 8 {
			return errors.New("invalid fin payload")
		}
		streamID := binary.BigEndian.Uint64(payload)
		rt.mu.Lock()
		st := rt.streams[streamID]
		rt.mu.Unlock()
		if st == nil {
			return errors.New("fin for unknown stream")
		}
		st.mu.Lock()
		if st.writeClosing || st.writeClosed || st.closed {
			st.mu.Unlock()
			return nil
		}
		st.writeClosing = true
		writeQueue := st.writeQueue
		st.mu.Unlock()
		if writeQueue == nil {
			return errors.New("stream write queue unavailable")
		}
		select {
		case writeQueue <- runtimeConnWriteOp{kind: runtimeConnWriteFin}:
			return nil
		default:
			return errors.New("stream write queue full")
		}
	case transportFrameRst:
		if len(payload) != 8 {
			return errors.New("invalid rst payload")
		}
		streamID := binary.BigEndian.Uint64(payload)
		rt.sendRstAndDropStream(streamID)
		return nil
	case transportFrameGoAway:
		rt.beginClosing()
		return nil
	case transportFrameSessionConfirm:
		return errors.New("unexpected session confirm from responder")
	case transportFrameOpen:
		return errors.New("dart-initiated OPEN not supported in v1 slice")
	case transportFrameBind:
		return errors.New("dart-initiated BIND not supported in v1 slice")
	case transportFrameDgram:
		var payloadObj runtimeDgramPayload
		if err := json.Unmarshal(payload, &payloadObj); err != nil {
			return err
		}
		data, err := base64.RawURLEncoding.DecodeString(payloadObj.DataB64)
		if err != nil {
			return err
		}
		if len(data) > transportMaxDatagramPayload {
			return errors.New("datagram payload too large")
		}
		rt.mu.Lock()
		binding := rt.bindings[payloadObj.BindingID]
		rt.mu.Unlock()
		if binding == nil || binding.isClosed() {
			return errors.New("dgram for unknown binding")
		}
		remote := endpointToUDPAddr(payloadObj.Remote)
		if remote == nil {
			return errors.New("invalid datagram remote endpoint")
		}
		if _, err := binding.pc.WriteTo(data, remote); err != nil {
			return err
		}
		return nil
	case transportFrameBindClose:
		if len(payload) != 8 {
			return errors.New("invalid bind_close payload")
		}
		if !rt.dropBinding(binary.BigEndian.Uint64(payload), false) {
			return errors.New("bind_close for unknown binding")
		}
		return nil
	case transportFrameBindAbort:
		if len(payload) != 8 {
			return errors.New("invalid bind_abort payload")
		}
		if !rt.dropBinding(binary.BigEndian.Uint64(payload), true) {
			return errors.New("bind_abort for unknown binding")
		}
		return nil
	default:
		return fmt.Errorf("unknown frame kind %d", kind)
	}
}

func (rt *runtimeTransportSession) sendRstAndDropStream(streamID uint64) {
	_ = rt.enqueueFrame(transportFrameRst, u64Bytes(streamID))
	rt.dropStream(streamID)
}

func (rt *runtimeTransportSession) dropStream(streamID uint64) {
	rt.mu.Lock()
	st := rt.streams[streamID]
	if st != nil {
		delete(rt.streams, streamID)
	}
	rt.mu.Unlock()
	if st == nil {
		return
	}
	st.mu.Lock()
	if !st.reset {
		st.reset = true
		st.cond.Broadcast()
	}
	st.closed = true
	writeQueue := st.writeQueue
	st.writeQueue = nil
	st.mu.Unlock()
	if writeQueue != nil {
		close(writeQueue)
	}
	_ = st.conn.Close()
	rt.maybeFinishClosing()
}

func (rt *runtimeTransportSession) markStreamReadClosed(st *runtimeStream) {
	st.mu.Lock()
	if st.reset || st.closed {
		st.mu.Unlock()
		return
	}
	st.readClosed = true
	shouldFinalize := st.writeClosed
	if shouldFinalize {
		st.closed = true
	}
	writeQueue := st.writeQueue
	if shouldFinalize {
		st.writeQueue = nil
	}
	conn := st.conn
	streamID := st.id
	st.mu.Unlock()

	if shouldFinalize {
		rt.finishStreamGracefully(streamID, st, writeQueue, conn)
	}
}

func (rt *runtimeTransportSession) markStreamWriteClosed(st *runtimeStream) {
	st.mu.Lock()
	if st.reset || st.closed {
		st.mu.Unlock()
		return
	}
	st.writeClosed = true
	shouldFinalize := st.readClosed
	if shouldFinalize {
		st.closed = true
	}
	writeQueue := st.writeQueue
	if shouldFinalize {
		st.writeQueue = nil
	}
	conn := st.conn
	streamID := st.id
	st.mu.Unlock()

	if shouldFinalize {
		rt.finishStreamGracefully(streamID, st, writeQueue, conn)
	}
}

func (rt *runtimeTransportSession) finishStreamGracefully(
	streamID uint64,
	st *runtimeStream,
	writeQueue chan runtimeConnWriteOp,
	conn net.Conn,
) {
	rt.mu.Lock()
	if rt.streams[streamID] == st {
		delete(rt.streams, streamID)
	}
	rt.mu.Unlock()

	if writeQueue != nil {
		close(writeQueue)
	}
	_ = conn.Close()
	rt.maybeFinishClosing()
}

func (rt *runtimeTransportSession) dropBinding(bindingID uint64, aborted bool) bool {
	rt.mu.Lock()
	binding := rt.bindings[bindingID]
	if binding != nil {
		delete(rt.bindings, bindingID)
	}
	rt.mu.Unlock()
	if binding == nil {
		return false
	}
	binding.mu.Lock()
	binding.closed = true
	binding.aborted = binding.aborted || aborted
	binding.mu.Unlock()
	_ = binding.pc.Close()
	rt.maybeFinishClosing()
	return true
}

func (rt *runtimeTransportSession) beginClosing() {
	rt.mu.Lock()
	if rt.state == transportStateClosed || rt.state == transportStateClosing {
		rt.mu.Unlock()
		return
	}
	if rt.state != transportStateOpen {
		rt.mu.Unlock()
		rt.failSession("invalid_closing_transition:" + rt.state)
		return
	}
	rt.state = transportStateClosing
	timeout := rt.goAwayDrainTimeout
	if timeout <= 0 {
		timeout = transportGoAwayDrainTimeout
	}
	rt.stopGoAwayTimerLocked()
	if timeout > 0 {
		rt.goAwayTimer = time.AfterFunc(timeout, func() {
			rt.failSession("goaway_drain_timeout")
		})
	}
	listeners := make([]*runtimeTcpListener, 0, len(rt.tcpListeners))
	for port, listener := range rt.tcpListeners {
		listeners = append(listeners, listener)
		delete(rt.tcpListeners, port)
	}
	shouldFinish := len(rt.streams) == 0 && len(rt.bindings) == 0
	conn := rt.conn
	writerQ := rt.writerQ
	if shouldFinish {
		rt.stopGoAwayTimerLocked()
		rt.state = transportStateClosed
		rt.conn = nil
		rt.writerQ = nil
	}
	rt.mu.Unlock()

	for _, listener := range listeners {
		_ = listener.ln.Close()
	}
	if shouldFinish {
		if writerQ != nil {
			close(writerQ)
		}
		if conn != nil {
			_ = conn.Close()
		}
	}
}

func (rt *runtimeTransportSession) maybeFinishClosing() {
	rt.mu.Lock()
	if rt.state != transportStateClosing || len(rt.streams) != 0 || len(rt.bindings) != 0 {
		rt.mu.Unlock()
		return
	}
	rt.stopGoAwayTimerLocked()
	rt.state = transportStateClosed
	conn := rt.conn
	writerQ := rt.writerQ
	rt.conn = nil
	rt.writerQ = nil
	rt.mu.Unlock()

	if writerQ != nil {
		close(writerQ)
	}
	if conn != nil {
		_ = conn.Close()
	}
}

func (rt *runtimeTransportSession) enqueueFrame(kind uint8, payload []byte) error {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	return rt.enqueueFrameLocked(kind, payload)
}

func (rt *runtimeTransportSession) tryEnqueueFrame(kind uint8, payload []byte) (bool, error) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if err := rt.requireOperationalLocked(); err != nil {
		return false, err
	}
	if rt.writerQ == nil {
		return false, errors.New("writer queue not ready")
	}
	frame := runtimeOutboundFrame{
		kind:    kind,
		payload: append([]byte(nil), payload...),
	}
	select {
	case rt.writerQ <- frame:
		return true, nil
	default:
		return false, nil
	}
}

func (rt *runtimeTransportSession) enqueueFrameLocked(kind uint8, payload []byte) error {
	if err := rt.requireOperationalLocked(); err != nil {
		return err
	}
	if rt.writerQ == nil {
		return errors.New("writer queue not ready")
	}
	frame := runtimeOutboundFrame{
		kind:    kind,
		payload: append([]byte(nil), payload...),
	}
	select {
	case rt.writerQ <- frame:
		return nil
	default:
		return errors.New("writer queue full")
	}
}

func (rt *runtimeTransportSession) isOperational() bool {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	return rt.state == transportStateOpen || rt.state == transportStateClosing
}

func (rt *runtimeTransportSession) failSession(reason string) {
	postMessage(map[string]any{
		"type":  "error",
		"code":  "transport",
		"error": reason,
	})

	rt.mu.Lock()
	if rt.state == transportStateClosed {
		rt.mu.Unlock()
		return
	}
	rt.lastError = reason
	rt.state = transportStateClosed
	rt.stopGoAwayTimerLocked()
	conn := rt.conn
	writerQ := rt.writerQ
	rt.conn = nil
	rt.writerQ = nil
	listeners := make([]*runtimeTcpListener, 0, len(rt.tcpListeners))
	for _, listener := range rt.tcpListeners {
		listeners = append(listeners, listener)
	}
	streams := make([]*runtimeStream, 0, len(rt.streams))
	for _, st := range rt.streams {
		streams = append(streams, st)
	}
	bindings := make([]*runtimeDatagramBinding, 0, len(rt.bindings))
	for _, binding := range rt.bindings {
		bindings = append(bindings, binding)
	}
	rt.mu.Unlock()

	if writerQ != nil {
		close(writerQ)
	}
	if conn != nil {
		_ = conn.Close()
	}
	for _, listener := range listeners {
		_ = listener.ln.Close()
	}
	for _, st := range streams {
		st.mu.Lock()
		st.reset = true
		st.cond.Broadcast()
		writeQueue := st.writeQueue
		st.writeQueue = nil
		st.mu.Unlock()
		if writeQueue != nil {
			close(writeQueue)
		}
		_ = st.conn.Close()
	}
	for _, binding := range bindings {
		binding.mu.Lock()
		binding.closed = true
		binding.aborted = true
		binding.mu.Unlock()
		_ = binding.pc.Close()
	}
}

func (rt *runtimeTransportSession) closeLocked() {
	rt.stopGoAwayTimerLocked()
	if rt.state != transportStateClosed {
		rt.state = transportStateClosed
	}
	if rt.writerQ != nil {
		close(rt.writerQ)
		rt.writerQ = nil
	}
	if rt.conn != nil {
		_ = rt.conn.Close()
		rt.conn = nil
	}
	for _, listener := range rt.tcpListeners {
		_ = listener.ln.Close()
	}
	for _, st := range rt.streams {
		st.mu.Lock()
		st.reset = true
		st.cond.Broadcast()
		writeQueue := st.writeQueue
		st.writeQueue = nil
		st.mu.Unlock()
		if writeQueue != nil {
			close(writeQueue)
		}
		_ = st.conn.Close()
	}
	for _, binding := range rt.bindings {
		binding.mu.Lock()
		binding.closed = true
		binding.aborted = true
		binding.mu.Unlock()
		_ = binding.pc.Close()
	}
}

func (rt *runtimeTransportSession) stopGoAwayTimerLocked() {
	if rt.goAwayTimer != nil {
		rt.goAwayTimer.Stop()
		rt.goAwayTimer = nil
	}
}

func (rt *runtimeTransportSession) listenerEndpoint() string {
	if rt.preferredCarrier == "uds" {
		return rt.listenerPath
	}
	return net.JoinHostPort(rt.listenerHost, strconv.Itoa(rt.listenerPort))
}

func (rt *runtimeTransportSession) lookupIdentity(proto, remoteAddr string) *runtimeIdentity {
	lc, err := rt.getLocalClient()
	if err != nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	who, err := lc.WhoIsProto(ctx, proto, remoteAddr)
	if err != nil || who == nil {
		return nil
	}
	return identityFromWhoIs(who)
}

func (rt *runtimeTransportSession) getLocalClient() (*local.Client, error) {
	rt.mu.Lock()
	if rt.localClient != nil {
		lc := rt.localClient
		rt.mu.Unlock()
		return lc, nil
	}
	rt.mu.Unlock()

	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return nil, errors.New("tsnet server not running")
	}
	lc, err := s.LocalClient()
	if err != nil {
		return nil, err
	}
	rt.mu.Lock()
	if rt.localClient == nil {
		rt.localClient = lc
	}
	rt.mu.Unlock()
	return lc, nil
}

func identityFromWhoIs(who *apitype.WhoIsResponse) *runtimeIdentity {
	if who == nil || who.Node == nil || who.UserProfile == nil {
		return nil
	}
	nodeName := who.Node.ComputedName
	if nodeName == "" {
		nodeName = who.Node.Name
	}
	return &runtimeIdentity{
		StableNodeID:    string(who.Node.StableID),
		NodeName:        nodeName,
		UserLogin:       who.UserProfile.LoginName,
		UserDisplayName: who.UserProfile.DisplayName,
	}
}

func endpointFromAddr(addr net.Addr) runtimeEndpoint {
	switch value := addr.(type) {
	case *net.TCPAddr:
		return runtimeEndpoint{IP: value.IP.String(), Port: value.Port}
	case *net.UDPAddr:
		return runtimeEndpoint{IP: value.IP.String(), Port: value.Port}
	default:
		host, portText, err := net.SplitHostPort(addr.String())
		if err != nil {
			return runtimeEndpoint{IP: addr.String(), Port: 0}
		}
		port, _ := strconv.Atoi(portText)
		return runtimeEndpoint{IP: host, Port: port}
	}
}

func u64Bytes(value uint64) []byte {
	out := make([]byte, 8)
	binary.BigEndian.PutUint64(out, value)
	return out
}

func endpointToUDPAddr(endpoint runtimeEndpoint) *net.UDPAddr {
	ip := net.ParseIP(endpoint.IP)
	if ip == nil || endpoint.Port <= 0 {
		return nil
	}
	return &net.UDPAddr{IP: ip, Port: endpoint.Port}
}

func (binding *runtimeDatagramBinding) isClosed() bool {
	binding.mu.Lock()
	defer binding.mu.Unlock()
	return binding.closed || binding.aborted
}
