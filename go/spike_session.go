package tailscale

import (
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
	"strings"
	"sync"
	"time"
)

const (
	spikeProtocolVersion         = 1
	spikeInitialStreamCredit     = 64 * 1024
	spikeMaxDataPayload          = 60 * 1024
	spikeMaxDatagramPayload      = 60 * 1024
	spikeOpenStreamCap           = 1024
	spikeListenerBacklogLimit    = 128
	spikeDatagramQueueLimit      = 256
	spikeWriterQueueCap          = 256
	spikeBootstrapAttachTimeout  = 10 * time.Second
	spikeHandshakeTimeout        = 5 * time.Second
	spikeSessionStateIdle        = "idle"
	spikeSessionStateAttaching   = "attaching"
	spikeSessionStateHandshaking = "handshaking"
	spikeSessionStateOpen        = "open"
	spikeSessionStateClosing     = "closing"
	spikeSessionStateClosed      = "closed"
)

const (
	spikeFrameOpen uint8 = iota + 1
	spikeFrameData
	spikeFrameCredit
	spikeFrameFin
	spikeFrameRst
	spikeFrameBind
	spikeFrameDgram
	spikeFrameBindClose
	spikeFrameBindAbort
	spikeFrameGoAway
)

var (
	spikeMu     sync.Mutex
	activeSpike *spikeRuntime
	base64NoPad = base64.RawURLEncoding
)

type spikeRuntime struct {
	mu sync.Mutex

	masterSecret        []byte
	sessionGenerationID []byte

	state          string
	preferredKind  string
	listenerOwner  string
	listenerHost   string
	listenerPort   int
	listenerPath   string
	lastError      string
	attachedAt     time.Time
	connectedAt    time.Time
	attachDeadline time.Time

	conn        net.Conn
	readerDone  chan struct{}
	writerDone  chan struct{}
	writerQueue chan spikeOutboundFrame

	handshakeKey []byte
	sessionKey   []byte
	dartToGoKey  []byte
	goToDartKey  []byte
	sendSeq      uint64
	recvSeq      uint64

	nextStreamID  uint64
	nextBindingID uint64
	streams       map[uint64]*spikeStream
	bindings      map[uint64]*spikeBinding
	events        []map[string]any
}

type spikeStream struct {
	mu sync.Mutex

	id           uint64
	local        spikeEndpoint
	remote       spikeEndpoint
	identity     *spikeIdentity
	outbound     int64
	writeClosed  bool
	reset        bool
	receivedFin  bool
	receivedRst  bool
	receivedData int
	cond         *sync.Cond
}

type spikeBinding struct {
	id                uint64
	local             spikeEndpoint
	transportKind     string
	sentDatagrams     int
	receivedDatagrams int
	closed            bool
	aborted           bool
}

type spikeEndpoint struct {
	IP   string `json:"ip"`
	Port int    `json:"port"`
}

type spikeIdentity struct {
	StableNodeID    string `json:"stableNodeId,omitempty"`
	NodeName        string `json:"nodeName,omitempty"`
	UserLogin       string `json:"userLogin,omitempty"`
	UserDisplayName string `json:"userDisplayName,omitempty"`
}

type spikeOutboundFrame struct {
	kind    uint8
	payload []byte
}

type spikeAttachRequest struct {
	CarrierKind   string `json:"carrierKind"`
	ListenerOwner string `json:"listenerOwner"`
	Host          string `json:"host,omitempty"`
	Port          int    `json:"port,omitempty"`
	Path          string `json:"path,omitempty"`
}

type spikeOpenStreamRequest struct {
	Local     spikeEndpoint  `json:"local"`
	Remote    spikeEndpoint  `json:"remote"`
	Transport string         `json:"transport"`
	Identity  *spikeIdentity `json:"identity,omitempty"`
}

type spikeWriteStreamRequest struct {
	StreamID uint64 `json:"streamId"`
	DataB64  string `json:"dataB64"`
}

type spikeAbortStreamRequest struct {
	StreamID uint64 `json:"streamId"`
}

type spikeOpenBindingRequest struct {
	Local     spikeEndpoint `json:"local"`
	Transport string        `json:"transport"`
}

type spikeSendDatagramRequest struct {
	BindingID uint64         `json:"bindingId"`
	Remote    spikeEndpoint  `json:"remote"`
	DataB64   string         `json:"dataB64"`
	Identity  *spikeIdentity `json:"identity,omitempty"`
}

type spikeOpenPayload struct {
	StreamID  uint64         `json:"streamId"`
	Transport string         `json:"transport"`
	Local     spikeEndpoint  `json:"local"`
	Remote    spikeEndpoint  `json:"remote"`
	Identity  *spikeIdentity `json:"identity,omitempty"`
}

type spikeBindPayload struct {
	BindingID uint64        `json:"bindingId"`
	Transport string        `json:"transport"`
	Local     spikeEndpoint `json:"local"`
}

type spikeDgramPayload struct {
	BindingID uint64         `json:"bindingId"`
	Remote    spikeEndpoint  `json:"remote"`
	DataB64   string         `json:"dataB64"`
	Identity  *spikeIdentity `json:"identity,omitempty"`
}

type spikeHelloEnvelope struct {
	Type                string   `json:"type"`
	SessionVersions     []int    `json:"sessionProtocolVersions,omitempty"`
	ClientNonceB64      string   `json:"clientNonceB64,omitempty"`
	ServerNonceB64      string   `json:"serverNonceB64,omitempty"`
	SessionGenerationID string   `json:"sessionGenerationIdB64"`
	CarrierKind         string   `json:"carrierKind"`
	ListenerOwner       string   `json:"listenerOwner"`
	ListenerEndpoint    string   `json:"listenerEndpoint"`
	RequestedCaps       []string `json:"requestedCapabilities,omitempty"`
	AcceptedCaps        []string `json:"acceptedCapabilities,omitempty"`
	SelectedVersion     int      `json:"selectedVersion,omitempty"`
	MacB64              string   `json:"macB64"`
}

func SpikeReset() {
	spikeMu.Lock()
	defer spikeMu.Unlock()
	if activeSpike != nil {
		activeSpike.closeLocked()
		activeSpike = nil
	}
}

func SpikeBootstrap() (map[string]any, error) {
	spikeMu.Lock()
	defer spikeMu.Unlock()
	if activeSpike != nil {
		activeSpike.closeLocked()
		activeSpike = nil
	}

	master := make([]byte, 32)
	if _, err := rand.Read(master); err != nil {
		return nil, err
	}
	gen := make([]byte, 16)
	if _, err := rand.Read(gen); err != nil {
		return nil, err
	}

	rt := &spikeRuntime{
		masterSecret:        master,
		sessionGenerationID: gen,
		state:               spikeSessionStateIdle,
		preferredKind:       "loopback_tcp",
		nextStreamID:        2,
		nextBindingID:       2,
		streams:             map[uint64]*spikeStream{},
		bindings:            map[uint64]*spikeBinding{},
	}
	activeSpike = rt

	return map[string]any{
		"masterSecretB64":        base64NoPad.EncodeToString(master),
		"sessionGenerationIdB64": base64NoPad.EncodeToString(gen),
		"preferredCarrierKind":   rt.preferredKind,
	}, nil
}

func SpikeAttach(reqJSON string) (map[string]any, error) {
	var req spikeAttachRequest
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		return nil, err
	}

	spikeMu.Lock()
	rt := activeSpike
	spikeMu.Unlock()
	if rt == nil {
		return nil, errors.New("no spike bootstrap active")
	}

	return rt.attach(req)
}

func SpikeCommand(reqJSON string) (map[string]any, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal([]byte(reqJSON), &raw); err != nil {
		return nil, err
	}
	var op string
	if err := json.Unmarshal(raw["op"], &op); err != nil {
		return nil, err
	}

	spikeMu.Lock()
	rt := activeSpike
	spikeMu.Unlock()
	if rt == nil {
		return nil, errors.New("no spike bootstrap active")
	}

	switch op {
	case "open_stream":
		var req spikeOpenStreamRequest
		if err := json.Unmarshal(raw["args"], &req); err != nil {
			return nil, err
		}
		return rt.openStream(req)
	case "write_stream":
		var req spikeWriteStreamRequest
		if err := json.Unmarshal(raw["args"], &req); err != nil {
			return nil, err
		}
		return rt.writeStreamCommand(req)
	case "close_write":
		var req spikeAbortStreamRequest
		if err := json.Unmarshal(raw["args"], &req); err != nil {
			return nil, err
		}
		return rt.closeWrite(req.StreamID)
	case "abort_stream":
		var req spikeAbortStreamRequest
		if err := json.Unmarshal(raw["args"], &req); err != nil {
			return nil, err
		}
		return rt.abortStream(req.StreamID)
	case "open_binding":
		var req spikeOpenBindingRequest
		if err := json.Unmarshal(raw["args"], &req); err != nil {
			return nil, err
		}
		return rt.openBinding(req)
	case "send_datagram":
		var req spikeSendDatagramRequest
		if err := json.Unmarshal(raw["args"], &req); err != nil {
			return nil, err
		}
		return rt.sendDatagram(req)
	case "goaway":
		return rt.sendGoAway()
	default:
		return nil, fmt.Errorf("unknown spike op %q", op)
	}
}

func SpikeSnapshot() map[string]any {
	spikeMu.Lock()
	rt := activeSpike
	spikeMu.Unlock()
	if rt == nil {
		return map[string]any{"state": "none"}
	}
	return rt.snapshot()
}

func (rt *spikeRuntime) attach(req spikeAttachRequest) (map[string]any, error) {
	rt.mu.Lock()
	defer rt.mu.Unlock()

	if rt.state != spikeSessionStateIdle {
		return nil, fmt.Errorf("attach invalid in state %s", rt.state)
	}
	if req.CarrierKind != "loopback_tcp" {
		return nil, fmt.Errorf("unsupported carrier kind %q", req.CarrierKind)
	}
	if req.ListenerOwner == "" {
		req.ListenerOwner = "dart"
	}

	rt.listenerOwner = req.ListenerOwner
	rt.listenerHost = req.Host
	rt.listenerPort = req.Port
	rt.listenerPath = req.Path
	rt.attachDeadline = time.Now().Add(spikeBootstrapAttachTimeout)
	rt.state = spikeSessionStateAttaching

	go rt.attachLoopback()

	return map[string]any{"ok": true}, nil
}

func (rt *spikeRuntime) attachLoopback() {
	rt.mu.Lock()
	host := rt.listenerHost
	port := rt.listenerPort
	if host == "" {
		host = "127.0.0.1"
	}
	address := net.JoinHostPort(host, strconv.Itoa(port))
	deadline := rt.attachDeadline
	rt.mu.Unlock()

	timeout := time.Until(deadline)
	if timeout <= 0 {
		rt.failSession("carrier_attach_timeout")
		return
	}

	conn, err := net.DialTimeout("tcp", address, timeout)
	if err != nil {
		rt.failSession("attach_dial_failed: " + err.Error())
		return
	}
	if err := conn.SetDeadline(time.Now().Add(spikeHandshakeTimeout)); err != nil {
		conn.Close()
		rt.failSession("set_deadline_failed: " + err.Error())
		return
	}

	if err := rt.performHandshake(conn); err != nil {
		conn.Close()
		rt.failSession("handshake_failed: " + err.Error())
		return
	}
	_ = conn.SetDeadline(time.Time{})

	rt.mu.Lock()
	if rt.state == spikeSessionStateClosed {
		rt.mu.Unlock()
		conn.Close()
		return
	}
	rt.conn = conn
	rt.connectedAt = time.Now()
	rt.writerQueue = make(chan spikeOutboundFrame, spikeWriterQueueCap)
	rt.readerDone = make(chan struct{})
	rt.writerDone = make(chan struct{})
	rt.state = spikeSessionStateOpen
	rt.appendEventLocked(map[string]any{"type": "session_open"})
	rt.mu.Unlock()

	go rt.writerLoop()
	go rt.readerLoop()
}

func (rt *spikeRuntime) performHandshake(conn net.Conn) error {
	clientNonce := make([]byte, 16)
	if _, err := rand.Read(clientNonce); err != nil {
		return err
	}

	handshakeKey := hkdfExtract(rt.sessionGenerationID, rt.masterSecret)
	clientHelloCanonical := rt.clientHelloCanonical(clientNonce)
	clientMac := hmacSHA256(handshakeKey, clientHelloCanonical)

	clientHello := spikeHelloEnvelope{
		Type:                "CLIENT_HELLO",
		SessionVersions:     []int{spikeProtocolVersion},
		ClientNonceB64:      base64NoPad.EncodeToString(clientNonce),
		SessionGenerationID: base64NoPad.EncodeToString(rt.sessionGenerationID),
		CarrierKind:         rt.preferredKind,
		ListenerOwner:       rt.listenerOwner,
		ListenerEndpoint:    rt.listenerEndpoint(),
		RequestedCaps:       []string{},
		MacB64:              base64NoPad.EncodeToString(clientMac),
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
	if serverHello.SelectedVersion != spikeProtocolVersion {
		return fmt.Errorf("unexpected selected version %d", serverHello.SelectedVersion)
	}
	if serverHello.SessionGenerationID != base64NoPad.EncodeToString(rt.sessionGenerationID) {
		return errors.New("session generation mismatch")
	}
	if serverHello.CarrierKind != rt.preferredKind ||
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
		"carrier_kind":              rt.preferredKind,
		"listener_owner":            rt.listenerOwner,
		"listener_endpoint":         rt.listenerEndpoint(),
		"accepted_capabilities":     "",
	})
	expectedServerMac := hmacSHA256(
		handshakeKey,
		appendWithNull(clientHelloCanonical, serverHelloCanonical),
	)
	serverMac, err := base64NoPad.DecodeString(serverHello.MacB64)
	if err != nil {
		return err
	}
	if !hmac.Equal(serverMac, expectedServerMac) {
		return errors.New("bad server hello mac")
	}

	transcriptHash := sha256.Sum256(appendWithNull(clientHelloCanonical, serverHelloCanonical))
	sessionSecret := hkdfExpand(handshakeKey, append([]byte("tailscale_dart:v1:session"), transcriptHash[:]...), 32)

	rt.mu.Lock()
	rt.handshakeKey = handshakeKey
	rt.sessionKey = sessionSecret
	rt.dartToGoKey = hkdfExpand(sessionSecret, []byte("tailscale_dart:v1:dart_to_go_frame"), 32)
	rt.goToDartKey = hkdfExpand(sessionSecret, []byte("tailscale_dart:v1:go_to_dart_frame"), 32)
	rt.state = spikeSessionStateHandshaking
	rt.mu.Unlock()
	return nil
}

func (rt *spikeRuntime) openStream(req spikeOpenStreamRequest) (map[string]any, error) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if err := rt.requireOpenLocked(); err != nil {
		return nil, err
	}
	if len(rt.streams) >= spikeOpenStreamCap {
		return nil, errors.New("stream cap reached")
	}

	streamID := rt.nextStreamID
	rt.nextStreamID += 2
	st := &spikeStream{
		id:       streamID,
		local:    req.Local,
		remote:   req.Remote,
		identity: req.Identity,
		outbound: spikeInitialStreamCredit,
	}
	st.cond = sync.NewCond(&st.mu)
	rt.streams[streamID] = st

	payload, err := json.Marshal(spikeOpenPayload{
		StreamID:  streamID,
		Transport: req.Transport,
		Local:     req.Local,
		Remote:    req.Remote,
		Identity:  req.Identity,
	})
	if err != nil {
		delete(rt.streams, streamID)
		return nil, err
	}
	if err := rt.enqueueFrameLocked(spikeFrameOpen, payload); err != nil {
		delete(rt.streams, streamID)
		return nil, err
	}
	rt.appendEventLocked(map[string]any{"type": "stream_open_sent", "streamId": streamID})
	return map[string]any{"streamId": streamID}, nil
}

func (rt *spikeRuntime) writeStreamCommand(req spikeWriteStreamRequest) (map[string]any, error) {
	data, err := base64NoPad.DecodeString(req.DataB64)
	if err != nil {
		return nil, err
	}
	if err := rt.writeStream(req.StreamID, data); err != nil {
		return nil, err
	}
	return map[string]any{"ok": true}, nil
}

func (rt *spikeRuntime) writeStream(streamID uint64, data []byte) error {
	rt.mu.Lock()
	if err := rt.requireOperationalLocked(); err != nil {
		rt.mu.Unlock()
		return err
	}
	st := rt.streams[streamID]
	rt.mu.Unlock()
	if st == nil {
		return fmt.Errorf("unknown stream %d", streamID)
	}

	offset := 0
	for offset < len(data) {
		st.mu.Lock()
		for st.outbound <= 0 && !st.reset && !st.writeClosed && rt.isOperational() {
			st.cond.Wait()
		}
		if st.reset || !rt.isOperational() {
			st.mu.Unlock()
			return errors.New("stream reset or session closed")
		}
		allowed := len(data) - offset
		if allowed > spikeMaxDataPayload {
			allowed = spikeMaxDataPayload
		}
		if allowed > int(st.outbound) {
			allowed = int(st.outbound)
		}
		st.outbound -= int64(allowed)
		st.mu.Unlock()

		payload := make([]byte, 8+allowed)
		binary.BigEndian.PutUint64(payload[:8], streamID)
		copy(payload[8:], data[offset:offset+allowed])
		if err := rt.enqueueFrame(spikeFrameData, payload); err != nil {
			return err
		}
		offset += allowed
	}

	rt.mu.Lock()
	rt.appendEventLocked(map[string]any{
		"type":     "stream_write_sent",
		"streamId": streamID,
		"bytes":    len(data),
	})
	rt.mu.Unlock()
	return nil
}

func (rt *spikeRuntime) closeWrite(streamID uint64) (map[string]any, error) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if err := rt.requireOperationalLocked(); err != nil {
		return nil, err
	}
	st := rt.streams[streamID]
	if st == nil {
		return nil, fmt.Errorf("unknown stream %d", streamID)
	}
	st.mu.Lock()
	if st.writeClosed {
		st.mu.Unlock()
		return map[string]any{"ok": true}, nil
	}
	st.writeClosed = true
	st.mu.Unlock()

	payload := make([]byte, 8)
	binary.BigEndian.PutUint64(payload, streamID)
	if err := rt.enqueueFrameLocked(spikeFrameFin, payload); err != nil {
		return nil, err
	}
	rt.appendEventLocked(map[string]any{"type": "stream_fin_sent", "streamId": streamID})
	return map[string]any{"ok": true}, nil
}

func (rt *spikeRuntime) abortStream(streamID uint64) (map[string]any, error) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if err := rt.requireOperationalLocked(); err != nil {
		return nil, err
	}
	st := rt.streams[streamID]
	if st == nil {
		return nil, fmt.Errorf("unknown stream %d", streamID)
	}
	st.mu.Lock()
	st.reset = true
	st.cond.Broadcast()
	st.mu.Unlock()
	payload := make([]byte, 8)
	binary.BigEndian.PutUint64(payload, streamID)
	if rt.state == spikeSessionStateOpen || rt.state == spikeSessionStateClosing {
		_ = rt.enqueueFrameLocked(spikeFrameRst, payload)
	}
	rt.appendEventLocked(map[string]any{"type": "stream_rst_sent", "streamId": streamID})
	return map[string]any{"ok": true}, nil
}

func (rt *spikeRuntime) openBinding(req spikeOpenBindingRequest) (map[string]any, error) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if err := rt.requireOpenLocked(); err != nil {
		return nil, err
	}
	bindingID := rt.nextBindingID
	rt.nextBindingID += 2
	binding := &spikeBinding{
		id:            bindingID,
		local:         req.Local,
		transportKind: req.Transport,
	}
	rt.bindings[bindingID] = binding
	payload, err := json.Marshal(spikeBindPayload{
		BindingID: bindingID,
		Transport: req.Transport,
		Local:     req.Local,
	})
	if err != nil {
		delete(rt.bindings, bindingID)
		return nil, err
	}
	if err := rt.enqueueFrameLocked(spikeFrameBind, payload); err != nil {
		delete(rt.bindings, bindingID)
		return nil, err
	}
	rt.appendEventLocked(map[string]any{"type": "binding_open_sent", "bindingId": bindingID})
	return map[string]any{"bindingId": bindingID}, nil
}

func (rt *spikeRuntime) sendDatagram(req spikeSendDatagramRequest) (map[string]any, error) {
	data, err := base64NoPad.DecodeString(req.DataB64)
	if err != nil {
		return nil, err
	}
	if len(data) > spikeMaxDatagramPayload {
		return nil, fmt.Errorf("datagram too large: %d", len(data))
	}

	rt.mu.Lock()
	defer rt.mu.Unlock()
	if err := rt.requireOperationalLocked(); err != nil {
		return nil, err
	}
	binding := rt.bindings[req.BindingID]
	if binding == nil || binding.closed || binding.aborted {
		return nil, fmt.Errorf("invalid binding %d", req.BindingID)
	}
	payload, err := json.Marshal(spikeDgramPayload{
		BindingID: req.BindingID,
		Remote:    req.Remote,
		DataB64:   base64NoPad.EncodeToString(data),
		Identity:  req.Identity,
	})
	if err != nil {
		return nil, err
	}
	if err := rt.enqueueFrameLocked(spikeFrameDgram, payload); err != nil {
		return nil, err
	}
	binding.sentDatagrams++
	rt.appendEventLocked(map[string]any{
		"type":      "datagram_sent",
		"bindingId": req.BindingID,
		"bytes":     len(data),
	})
	return map[string]any{"ok": true}, nil
}

func (rt *spikeRuntime) sendGoAway() (map[string]any, error) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if rt.state != spikeSessionStateOpen {
		return nil, fmt.Errorf("session not open")
	}
	rt.state = spikeSessionStateClosing
	if err := rt.enqueueFrameLocked(spikeFrameGoAway, nil); err != nil {
		return nil, err
	}
	rt.appendEventLocked(map[string]any{"type": "goaway_sent"})
	return map[string]any{"ok": true}, nil
}

func (rt *spikeRuntime) snapshot() map[string]any {
	rt.mu.Lock()
	defer rt.mu.Unlock()

	streams := make([]map[string]any, 0, len(rt.streams))
	for id, st := range rt.streams {
		st.mu.Lock()
		streams = append(streams, map[string]any{
			"id":           id,
			"outbound":     st.outbound,
			"writeClosed":  st.writeClosed,
			"reset":        st.reset,
			"receivedFin":  st.receivedFin,
			"receivedRst":  st.receivedRst,
			"receivedData": st.receivedData,
		})
		st.mu.Unlock()
	}
	bindings := make([]map[string]any, 0, len(rt.bindings))
	for id, b := range rt.bindings {
		bindings = append(bindings, map[string]any{
			"id":                id,
			"sentDatagrams":     b.sentDatagrams,
			"receivedDatagrams": b.receivedDatagrams,
			"closed":            b.closed,
			"aborted":           b.aborted,
		})
	}
	events := make([]map[string]any, len(rt.events))
	copy(events, rt.events)

	return map[string]any{
		"state":            rt.state,
		"listenerOwner":    rt.listenerOwner,
		"listenerEndpoint": rt.listenerEndpoint(),
		"lastError":        rt.lastError,
		"streams":          streams,
		"bindings":         bindings,
		"events":           events,
	}
}

func (rt *spikeRuntime) readerLoop() {
	defer close(rt.readerDone)
	for {
		headerBytes := make([]byte, 16)
		if _, err := io.ReadFull(rt.conn, headerBytes); err != nil {
			rt.failSession("reader_error: " + err.Error())
			return
		}
		payloadLen := binary.BigEndian.Uint32(headerBytes[12:16])
		payload := make([]byte, payloadLen)
		if _, err := io.ReadFull(rt.conn, payload); err != nil {
			rt.failSession("reader_payload_error: " + err.Error())
			return
		}
		macBytes := make([]byte, 32)
		if _, err := io.ReadFull(rt.conn, macBytes); err != nil {
			rt.failSession("reader_mac_error: " + err.Error())
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

		kind := headerBytes[1]
		if err := rt.handleFrame(kind, payload); err != nil {
			rt.failSession("handle_frame:" + err.Error())
			return
		}
	}
}

func (rt *spikeRuntime) writerLoop() {
	defer close(rt.writerDone)
	for frame := range rt.writerQueue {
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
		header[0] = spikeProtocolVersion
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

func (rt *spikeRuntime) handleFrame(kind uint8, payload []byte) error {
	switch kind {
	case spikeFrameCredit:
		if len(payload) != 12 {
			return errors.New("invalid credit payload")
		}
		streamID := binary.BigEndian.Uint64(payload[:8])
		credit := binary.BigEndian.Uint32(payload[8:12])
		rt.mu.Lock()
		st := rt.streams[streamID]
		rt.mu.Unlock()
		if st != nil {
			st.mu.Lock()
			st.outbound += int64(credit)
			st.cond.Broadcast()
			st.mu.Unlock()
		}
		return nil
	case spikeFrameFin:
		if len(payload) != 8 {
			return errors.New("invalid fin payload")
		}
		streamID := binary.BigEndian.Uint64(payload)
		rt.mu.Lock()
		st := rt.streams[streamID]
		if st == nil {
			rt.mu.Unlock()
			return errors.New("fin for unknown stream")
		}
		st.mu.Lock()
		st.receivedFin = true
		st.mu.Unlock()
		rt.appendEventLocked(map[string]any{"type": "stream_fin_received", "streamId": streamID})
		rt.mu.Unlock()
		return nil
	case spikeFrameRst:
		if len(payload) != 8 {
			return errors.New("invalid rst payload")
		}
		streamID := binary.BigEndian.Uint64(payload)
		rt.mu.Lock()
		st := rt.streams[streamID]
		if st == nil {
			rt.mu.Unlock()
			return errors.New("rst for unknown stream")
		}
		st.mu.Lock()
		st.reset = true
		st.receivedRst = true
		st.cond.Broadcast()
		st.mu.Unlock()
		rt.appendEventLocked(map[string]any{"type": "stream_rst_received", "streamId": streamID})
		rt.mu.Unlock()
		return nil
	case spikeFrameGoAway:
		rt.mu.Lock()
		if rt.state == spikeSessionStateOpen {
			rt.state = spikeSessionStateClosing
		}
		rt.appendEventLocked(map[string]any{"type": "goaway_received"})
		rt.mu.Unlock()
		return nil
	case spikeFrameOpen:
		var payloadObj spikeOpenPayload
		if err := json.Unmarshal(payload, &payloadObj); err != nil {
			return err
		}
		rt.mu.Lock()
		if _, ok := rt.streams[payloadObj.StreamID]; ok {
			rt.mu.Unlock()
			return errors.New("open on reused stream id")
		}
		if payloadObj.StreamID%2 != 1 {
			rt.mu.Unlock()
			return errors.New("open with wrong parity")
		}
		if len(rt.streams) >= spikeOpenStreamCap {
			rt.appendEventLocked(map[string]any{
				"type":     "stream_open_rejected",
				"streamId": payloadObj.StreamID,
				"reason":   "stream_cap",
			})
			rt.mu.Unlock()

			rstPayload := make([]byte, 8)
			binary.BigEndian.PutUint64(rstPayload, payloadObj.StreamID)
			return rt.enqueueFrame(spikeFrameRst, rstPayload)
		}
		st := &spikeStream{
			id:       payloadObj.StreamID,
			local:    payloadObj.Local,
			remote:   payloadObj.Remote,
			identity: payloadObj.Identity,
			outbound: spikeInitialStreamCredit,
		}
		st.cond = sync.NewCond(&st.mu)
		rt.streams[payloadObj.StreamID] = st
		rt.appendEventLocked(map[string]any{"type": "stream_open_received", "streamId": payloadObj.StreamID})
		rt.mu.Unlock()
		return nil
	case spikeFrameData:
		if len(payload) < 8 {
			return errors.New("invalid data payload")
		}
		streamID := binary.BigEndian.Uint64(payload[:8])
		rt.mu.Lock()
		st := rt.streams[streamID]
		if st == nil {
			rt.mu.Unlock()
			return errors.New("data before open")
		}
		st.mu.Lock()
		st.receivedData += len(payload) - 8
		st.mu.Unlock()
		rt.appendEventLocked(map[string]any{"type": "stream_data_received", "streamId": streamID, "bytes": len(payload) - 8})
		rt.mu.Unlock()
		return nil
	case spikeFrameBind:
		var payloadObj spikeBindPayload
		if err := json.Unmarshal(payload, &payloadObj); err != nil {
			return err
		}
		rt.mu.Lock()
		if _, ok := rt.bindings[payloadObj.BindingID]; ok {
			rt.mu.Unlock()
			return errors.New("bind on reused id")
		}
		if payloadObj.BindingID%2 != 1 {
			rt.mu.Unlock()
			return errors.New("bind wrong parity")
		}
		rt.bindings[payloadObj.BindingID] = &spikeBinding{
			id:            payloadObj.BindingID,
			local:         payloadObj.Local,
			transportKind: payloadObj.Transport,
		}
		rt.appendEventLocked(map[string]any{"type": "binding_open_received", "bindingId": payloadObj.BindingID})
		rt.mu.Unlock()
		return nil
	case spikeFrameDgram:
		var payloadObj spikeDgramPayload
		if err := json.Unmarshal(payload, &payloadObj); err != nil {
			return err
		}
		rt.mu.Lock()
		b := rt.bindings[payloadObj.BindingID]
		if b == nil {
			rt.mu.Unlock()
			return errors.New("dgram before bind")
		}
		b.receivedDatagrams++
		rt.appendEventLocked(map[string]any{"type": "datagram_received", "bindingId": payloadObj.BindingID})
		rt.mu.Unlock()
		return nil
	case spikeFrameBindClose:
		if len(payload) != 8 {
			return errors.New("invalid bind_close payload")
		}
		bindingID := binary.BigEndian.Uint64(payload)
		rt.mu.Lock()
		b := rt.bindings[bindingID]
		if b == nil {
			rt.mu.Unlock()
			return errors.New("bind_close for unknown binding")
		}
		if b.closed {
			rt.mu.Unlock()
			return nil
		}
		b.closed = true
		rt.appendEventLocked(map[string]any{"type": "binding_close_received", "bindingId": bindingID})
		rt.mu.Unlock()
		return nil
	case spikeFrameBindAbort:
		if len(payload) != 8 {
			return errors.New("invalid bind_abort payload")
		}
		bindingID := binary.BigEndian.Uint64(payload)
		rt.mu.Lock()
		b := rt.bindings[bindingID]
		if b == nil {
			rt.mu.Unlock()
			return errors.New("bind_abort for unknown binding")
		}
		if b.aborted {
			rt.mu.Unlock()
			return nil
		}
		b.aborted = true
		rt.appendEventLocked(map[string]any{"type": "binding_abort_received", "bindingId": bindingID})
		rt.mu.Unlock()
		return nil
	default:
		return fmt.Errorf("unknown frame kind %d", kind)
	}
}

func (rt *spikeRuntime) enqueueFrame(kind uint8, payload []byte) error {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	return rt.enqueueFrameLocked(kind, payload)
}

func (rt *spikeRuntime) enqueueFrameLocked(kind uint8, payload []byte) error {
	if rt.state != spikeSessionStateOpen && rt.state != spikeSessionStateClosing {
		return fmt.Errorf("session not open: %s", rt.state)
	}
	frame := spikeOutboundFrame{kind: kind, payload: append([]byte(nil), payload...)}
	select {
	case rt.writerQueue <- frame:
		return nil
	default:
		return errors.New("writer queue full")
	}
}

func (rt *spikeRuntime) requireOpenLocked() error {
	if rt.state != spikeSessionStateOpen {
		return fmt.Errorf("session not open: %s", rt.state)
	}
	return nil
}

func (rt *spikeRuntime) requireOperationalLocked() error {
	if rt.state != spikeSessionStateOpen && rt.state != spikeSessionStateClosing {
		return fmt.Errorf("session not open: %s", rt.state)
	}
	return nil
}

func (rt *spikeRuntime) isOperational() bool {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	return rt.state == spikeSessionStateOpen || rt.state == spikeSessionStateClosing
}

func (rt *spikeRuntime) failSession(reason string) {
	rt.mu.Lock()
	if rt.state == spikeSessionStateClosed {
		rt.mu.Unlock()
		return
	}
	rt.lastError = reason
	rt.state = spikeSessionStateClosed
	rt.appendEventLocked(map[string]any{"type": "session_failed", "reason": reason})
	for _, st := range rt.streams {
		st.mu.Lock()
		st.reset = true
		st.cond.Broadcast()
		st.mu.Unlock()
	}
	conn := rt.conn
	writerQueue := rt.writerQueue
	rt.conn = nil
	rt.writerQueue = nil
	rt.mu.Unlock()

	if writerQueue != nil {
		close(writerQueue)
	}
	if conn != nil {
		_ = conn.Close()
	}
}

func (rt *spikeRuntime) closeLocked() {
	if rt.state != spikeSessionStateClosed {
		rt.state = spikeSessionStateClosed
	}
	if rt.writerQueue != nil {
		close(rt.writerQueue)
		rt.writerQueue = nil
	}
	if rt.conn != nil {
		_ = rt.conn.Close()
		rt.conn = nil
	}
	for _, st := range rt.streams {
		st.mu.Lock()
		st.reset = true
		st.cond.Broadcast()
		st.mu.Unlock()
	}
}

func (rt *spikeRuntime) listenerEndpoint() string {
	if rt.preferredKind == "uds" {
		return rt.listenerPath
	}
	return net.JoinHostPort(rt.listenerHost, strconv.Itoa(rt.listenerPort))
}

func (rt *spikeRuntime) clientHelloCanonical(clientNonce []byte) []byte {
	return canonicalLines(map[string]string{
		"msg":                       "CLIENT_HELLO",
		"session_protocol_versions": strconv.Itoa(spikeProtocolVersion),
		"client_nonce_b64":          base64NoPad.EncodeToString(clientNonce),
		"session_generation_id_b64": base64NoPad.EncodeToString(rt.sessionGenerationID),
		"carrier_kind":              rt.preferredKind,
		"listener_owner":            rt.listenerOwner,
		"listener_endpoint":         rt.listenerEndpoint(),
		"requested_capabilities":    "",
	})
}

func (rt *spikeRuntime) appendEventLocked(event map[string]any) {
	if len(rt.events) >= 256 {
		rt.events = rt.events[1:]
	}
	rt.events = append(rt.events, event)
}

func writeLengthPrefixedJSON(w io.Writer, value any) error {
	bytes, err := json.Marshal(value)
	if err != nil {
		return err
	}
	header := make([]byte, 4)
	binary.BigEndian.PutUint32(header, uint32(len(bytes)))
	if _, err := w.Write(header); err != nil {
		return err
	}
	_, err = w.Write(bytes)
	return err
}

func readLengthPrefixedJSON(r io.Reader, out any) error {
	header := make([]byte, 4)
	if _, err := io.ReadFull(r, header); err != nil {
		return err
	}
	length := binary.BigEndian.Uint32(header)
	payload := make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		return err
	}
	return json.Unmarshal(payload, out)
}

func hmacSHA256(key, data []byte) []byte {
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write(data)
	return mac.Sum(nil)
}

func hkdfExtract(salt, ikm []byte) []byte {
	return hmacSHA256(salt, ikm)
}

func hkdfExpand(prk, info []byte, length int) []byte {
	var result []byte
	var previous []byte
	counter := byte(1)
	for len(result) < length {
		mac := hmac.New(sha256.New, prk)
		if len(previous) > 0 {
			_, _ = mac.Write(previous)
		}
		_, _ = mac.Write(info)
		_, _ = mac.Write([]byte{counter})
		previous = mac.Sum(nil)
		result = append(result, previous...)
		counter++
	}
	return result[:length]
}

func canonicalLines(fields map[string]string) []byte {
	order := []string{
		"msg",
		"session_protocol_versions",
		"selected_version",
		"client_nonce_b64",
		"server_nonce_b64",
		"session_generation_id_b64",
		"carrier_kind",
		"listener_owner",
		"listener_endpoint",
		"requested_capabilities",
		"accepted_capabilities",
	}
	lines := make([]string, 0, len(order))
	for _, key := range order {
		value, ok := fields[key]
		if !ok {
			continue
		}
		lines = append(lines, key+"="+value)
	}
	return []byte(strings.Join(lines, "\n"))
}

func appendWithNull(left, right []byte) []byte {
	out := make([]byte, 0, len(left)+1+len(right))
	out = append(out, left...)
	out = append(out, 0)
	out = append(out, right...)
	return out
}
