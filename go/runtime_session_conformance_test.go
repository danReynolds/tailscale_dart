package tailscale

import (
	"crypto/hmac"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"tailscale.com/tsnet"
)

func TestRuntimeTransportSessionPerformHandshakeRejectsBadServerHelloMAC(t *testing.T) {
	rt := newTestRuntimeTransportSession()
	clientConn, serverConn := net.Pipe()
	defer clientConn.Close()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		defer serverConn.Close()
		respondWithServerHelloForTest(t, serverConn, rt, func(hello *spikeHelloEnvelope, _ map[string]string) {
			hello.MacB64 = base64.RawURLEncoding.EncodeToString([]byte("wrong-mac"))
		})
	}()

	err := rt.performHandshake(clientConn)
	if err == nil || !strings.Contains(err.Error(), "bad server hello mac") {
		t.Fatalf("performHandshake error = %v, want bad server hello mac", err)
	}
	<-serverDone
}

func TestRuntimeTransportSessionPerformHandshakeRejectsSessionGenerationMismatch(t *testing.T) {
	rt := newTestRuntimeTransportSession()
	clientConn, serverConn := net.Pipe()
	defer clientConn.Close()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		defer serverConn.Close()
		respondWithServerHelloForTest(t, serverConn, rt, func(_ *spikeHelloEnvelope, fields map[string]string) {
			mismatch := base64.RawURLEncoding.EncodeToString(bytesOf(0x44, 16))
			fields["session_generation_id_b64"] = mismatch
		})
	}()

	err := rt.performHandshake(clientConn)
	if err == nil || !strings.Contains(err.Error(), "session generation mismatch") {
		t.Fatalf("performHandshake error = %v, want session generation mismatch", err)
	}
	<-serverDone
}

func TestRuntimeTransportSessionPerformHandshakeRejectsMalformedServerHello(t *testing.T) {
	rt := newTestRuntimeTransportSession()
	clientConn, serverConn := net.Pipe()
	defer clientConn.Close()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		defer serverConn.Close()
		_, _ = readClientHelloForTest(t, serverConn)
		_ = writeRawLengthPrefixed(serverConn, []byte("{"))
	}()

	err := rt.performHandshake(clientConn)
	if err == nil {
		t.Fatal("performHandshake succeeded, want malformed server hello error")
	}
	<-serverDone
}

func TestRuntimeTransportSessionPerformHandshakeRejectsUnexpectedSelectedVersion(t *testing.T) {
	rt := newTestRuntimeTransportSession()
	clientConn, serverConn := net.Pipe()
	defer clientConn.Close()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		defer serverConn.Close()
		respondWithServerHelloForTest(t, serverConn, rt, func(_ *spikeHelloEnvelope, fields map[string]string) {
			fields["selected_version"] = "2"
		})
	}()

	err := rt.performHandshake(clientConn)
	if err == nil || !strings.Contains(err.Error(), "unexpected selected version 2") {
		t.Fatalf("performHandshake error = %v, want unexpected selected version", err)
	}
	<-serverDone
}

func TestRuntimeTransportSessionPerformHandshakeRejectsCarrierBindingMismatch(t *testing.T) {
	rt := newTestRuntimeTransportSession()
	clientConn, serverConn := net.Pipe()
	defer clientConn.Close()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		defer serverConn.Close()
		respondWithServerHelloForTest(t, serverConn, rt, func(_ *spikeHelloEnvelope, fields map[string]string) {
			fields["listener_endpoint"] = "127.0.0.1:4999"
		})
	}()

	err := rt.performHandshake(clientConn)
	if err == nil || !strings.Contains(err.Error(), "carrier binding mismatch") {
		t.Fatalf("performHandshake error = %v, want carrier binding mismatch", err)
	}
	<-serverDone
}

func TestRuntimeTransportSessionPerformHandshakeRejectsUnexpectedAcceptedCapabilities(t *testing.T) {
	rt := newTestRuntimeTransportSession()
	clientConn, serverConn := net.Pipe()
	defer clientConn.Close()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		defer serverConn.Close()
		respondWithServerHelloForTest(t, serverConn, rt, func(hello *spikeHelloEnvelope, fields map[string]string) {
			hello.AcceptedCaps = []string{"future-cap"}
			fields["accepted_capabilities"] = "future-cap"
		})
	}()

	err := rt.performHandshake(clientConn)
	if err == nil || !strings.Contains(err.Error(), "unexpected accepted capabilities") {
		t.Fatalf("performHandshake error = %v, want unexpected accepted capabilities", err)
	}
	<-serverDone
}

func TestRuntimeTransportSessionPerformHandshakeRejectsServerHelloWithoutTranscriptSeparator(t *testing.T) {
	rt := newTestRuntimeTransportSession()
	clientConn, serverConn := net.Pipe()
	defer clientConn.Close()

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		defer serverConn.Close()

		clientHello, clientHelloCanonical := readClientHelloForTest(t, serverConn)
		serverNonce := bytesOf(0x33, 16)
		fields := map[string]string{
			"msg":                       "SERVER_HELLO",
			"selected_version":          "1",
			"client_nonce_b64":          clientHello.ClientNonceB64,
			"server_nonce_b64":          base64.RawURLEncoding.EncodeToString(serverNonce),
			"session_generation_id_b64": clientHello.SessionGenerationID,
			"carrier_kind":              rt.preferredCarrier,
			"listener_owner":            rt.listenerOwner,
			"listener_endpoint":         rt.listenerEndpoint(),
			"accepted_capabilities":     "",
		}
		handshakeKey := hkdfExtract(rt.sessionGenerationID, rt.masterSecret)
		serverHelloCanonical := canonicalLines(fields)
		serverMac := hmacSHA256(handshakeKey, append(clientHelloCanonical, serverHelloCanonical...))
		hello := spikeHelloEnvelope{
			Type:                "SERVER_HELLO",
			SelectedVersion:     transportProtocolVersion,
			ServerNonceB64:      fields["server_nonce_b64"],
			SessionGenerationID: fields["session_generation_id_b64"],
			CarrierKind:         fields["carrier_kind"],
			ListenerOwner:       fields["listener_owner"],
			ListenerEndpoint:    fields["listener_endpoint"],
			AcceptedCaps:        []string{},
			MacB64:              base64.RawURLEncoding.EncodeToString(serverMac),
		}
		if err := writeLengthPrefixedJSON(serverConn, hello); err != nil {
			t.Fatalf("writeLengthPrefixedJSON: %v", err)
		}
	}()

	err := rt.performHandshake(clientConn)
	if err == nil || !strings.Contains(err.Error(), "bad server hello mac") {
		t.Fatalf("performHandshake error = %v, want bad server hello mac", err)
	}
	<-serverDone
}

func TestRuntimeTransportSessionAttachRejectsInvalidStates(t *testing.T) {
	reqJSON := `{"carrierKind":"loopback_tcp","listenerOwner":"dart","host":"127.0.0.1","port":4100}`
	for _, state := range []string{
		transportStateAttaching,
		transportStateHandshaking,
		transportStateOpen,
		transportStateClosing,
		transportStateClosed,
	} {
		t.Run(state, func(t *testing.T) {
			rt := newTestRuntimeTransportSession()
			rt.state = state

			err := rt.attach(reqJSON)
			if err == nil || !strings.Contains(err.Error(), "attach invalid in state") {
				t.Fatalf("attach error = %v, want invalid-state error", err)
			}
			if got := rt.state; got != state {
				t.Fatalf("state = %q, want unchanged %q", got, state)
			}
		})
	}
}

func TestRuntimeTransportSessionBindTCPRejectsNonOpenStates(t *testing.T) {
	for _, state := range []string{
		transportStateIdle,
		transportStateAttaching,
		transportStateHandshaking,
		transportStateClosing,
		transportStateClosed,
	} {
		t.Run(state, func(t *testing.T) {
			rt := newTestRuntimeTransportSession()
			rt.state = state

			err := rt.bindTCP(&tsnet.Server{}, 80)
			if err == nil || !strings.Contains(err.Error(), "transport session not open for new listeners") {
				t.Fatalf("bindTCP error = %v, want wrong-state error", err)
			}
			if got := len(rt.tcpListeners); got != 0 {
				t.Fatalf("tcpListeners len = %d, want 0", got)
			}
		})
	}
}

func TestRuntimeTransportSessionDialTCPRejectsNonOpenStates(t *testing.T) {
	for _, state := range []string{
		transportStateIdle,
		transportStateAttaching,
		transportStateHandshaking,
		transportStateClosing,
		transportStateClosed,
	} {
		t.Run(state, func(t *testing.T) {
			rt := newTestRuntimeTransportSession()
			rt.state = state

			streamID, err := rt.dialTCP(&tsnet.Server{}, "100.64.0.1", 80)
			if err == nil || !strings.Contains(err.Error(), "transport session not open for new streams") {
				t.Fatalf("dialTCP error = %v, want wrong-state error", err)
			}
			if streamID != 0 {
				t.Fatalf("streamID = %d, want 0", streamID)
			}
		})
	}
}

func TestRuntimeTransportSessionRegisterStreamRejectsClosingState(t *testing.T) {
	rt := newTestRuntimeTransportSession()
	rt.state = transportStateClosing

	clientConn, serverConn := net.Pipe()
	defer clientConn.Close()
	defer serverConn.Close()

	err := rt.registerStream(1, clientConn, "tcp")
	if err == nil || !strings.Contains(err.Error(), "transport session not open for new streams") {
		t.Fatalf("registerStream error = %v, want wrong-state error", err)
	}
	if _, ok := rt.streams[1]; ok {
		t.Fatal("stream registered while closing")
	}
}

func TestRuntimeTransportSessionBindUDPRejectsNonOpenStates(t *testing.T) {
	for _, state := range []string{
		transportStateIdle,
		transportStateAttaching,
		transportStateHandshaking,
		transportStateClosing,
		transportStateClosed,
	} {
		t.Run(state, func(t *testing.T) {
			rt := newTestRuntimeTransportSession()
			rt.state = state

			bindingID, err := rt.bindUDP(&tsnet.Server{}, 53)
			if err == nil || !strings.Contains(err.Error(), "transport session not open for new bindings") {
				t.Fatalf("bindUDP error = %v, want wrong-state error", err)
			}
			if bindingID != 0 {
				t.Fatalf("bindingID = %d, want 0", bindingID)
			}
		})
	}
}

func TestRuntimeTransportSessionAttachLoopbackExpiredDeadlineFailsClosed(t *testing.T) {
	rt := newTestRuntimeTransportSession()
	rt.state = transportStateAttaching
	rt.attachDeadline = time.Now().Add(-time.Second)

	rt.attachLoopback()

	if got := rt.state; got != transportStateClosed {
		t.Fatalf("state = %q, want %q", got, transportStateClosed)
	}
	if got := rt.lastError; got != "carrier_attach_timeout" {
		t.Fatalf("lastError = %q, want carrier_attach_timeout", got)
	}
}

func TestRuntimeTransportSessionAttachLoopbackHandshakeTimeoutFailsClosed(t *testing.T) {
	rt := newTestRuntimeTransportSession()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.Listen: %v", err)
	}
	defer listener.Close()

	address := listener.Addr().(*net.TCPAddr)
	rt.listenerHost = "127.0.0.1"
	rt.listenerPort = address.Port
	rt.state = transportStateAttaching
	rt.attachDeadline = time.Now().Add(transportAttachTimeout)

	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		conn, acceptErr := listener.Accept()
		if acceptErr != nil {
			return
		}
		defer conn.Close()
		time.Sleep(transportHandshakeTimeout + 500*time.Millisecond)
	}()

	start := time.Now()
	rt.attachLoopback()
	elapsed := time.Since(start)
	if elapsed < transportHandshakeTimeout {
		t.Fatalf("attachLoopback returned too quickly: %v", elapsed)
	}
	if got := rt.state; got != transportStateClosed {
		t.Fatalf("state = %q, want %q", got, transportStateClosed)
	}
	if got := rt.lastError; !strings.Contains(got, "handshake_failed:") {
		t.Fatalf("lastError = %q, want handshake_failed", got)
	}
	<-serverDone
}

func TestRuntimeTransportSessionAttachLoopbackSendsSessionConfirmFirst(t *testing.T) {
	rt := newTestRuntimeTransportSession()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.Listen: %v", err)
	}
	defer listener.Close()

	address := listener.Addr().(*net.TCPAddr)
	rt.listenerHost = "127.0.0.1"
	rt.listenerPort = address.Port
	rt.state = transportStateAttaching
	rt.attachDeadline = time.Now().Add(transportAttachTimeout)

	type firstFrame struct {
		header []byte
		mac    []byte
		err    error
	}
	frameCh := make(chan firstFrame, 1)
	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		conn, acceptErr := listener.Accept()
		if acceptErr != nil {
			frameCh <- firstFrame{err: acceptErr}
			return
		}
		defer conn.Close()

		respondWithServerHelloForTest(t, conn, rt, nil)

		header := make([]byte, 16)
		if _, readErr := io.ReadFull(conn, header); readErr != nil {
			frameCh <- firstFrame{err: readErr}
			return
		}
		payloadLen := binary.BigEndian.Uint32(header[12:16])
		if payloadLen != 0 {
			frameCh <- firstFrame{err: fmt.Errorf("payloadLen=%d", payloadLen)}
			return
		}
		mac := make([]byte, 32)
		if _, readErr := io.ReadFull(conn, mac); readErr != nil {
			frameCh <- firstFrame{err: readErr}
			return
		}
		frameCh <- firstFrame{header: header, mac: mac}
	}()

	rt.attachLoopback()
	waitForSessionState(t, rt, transportStateOpen)

	frame := <-frameCh
	if frame.err != nil {
		t.Fatalf("first frame read failed: %v", frame.err)
	}
	if got := frame.header[1]; got != transportFrameSessionConfirm {
		t.Fatalf("first frame kind = %d, want %d", got, transportFrameSessionConfirm)
	}
	if got := binary.BigEndian.Uint64(frame.header[4:12]); got != 1 {
		t.Fatalf("first frame sequence = %d, want 1", got)
	}
	expectedMac := hmacSHA256(rt.goToDartKey, frame.header)
	if !hmac.Equal(frame.mac, expectedMac) {
		t.Fatal("SESSION_CONFIRM MAC mismatch")
	}
	rt.failSession("test shutdown")
	<-serverDone
}

func TestRuntimeTransportSessionReaderLoopRejectsBadFrameMAC(t *testing.T) {
	rt, clientConn, serverConn := newOpenRuntimeTransportSessionForReaderTest()
	defer clientConn.Close()
	defer serverConn.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		rt.readerLoop()
	}()

	header := sessionHeaderForTest(transportFrameGoAway, 1, nil)
	if _, err := serverConn.Write(header); err != nil {
		t.Fatalf("write header: %v", err)
	}
	if _, err := serverConn.Write(make([]byte, 32)); err != nil {
		t.Fatalf("write mac: %v", err)
	}

	waitForSessionState(t, rt, transportStateClosed)
	if got := rt.lastError; got != "bad_frame_mac" {
		t.Fatalf("lastError = %q, want bad_frame_mac", got)
	}
	<-done
}

func TestRuntimeTransportSessionReaderLoopRejectsBadSequence(t *testing.T) {
	rt, clientConn, serverConn := newOpenRuntimeTransportSessionForReaderTest()
	defer clientConn.Close()
	defer serverConn.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		rt.readerLoop()
	}()

	payload := []byte{}
	header := sessionHeaderForTest(transportFrameGoAway, 2, payload)
	mac := hmacSHA256(rt.dartToGoKey, append(header, payload...))
	if _, err := serverConn.Write(header); err != nil {
		t.Fatalf("write header: %v", err)
	}
	if _, err := serverConn.Write(mac); err != nil {
		t.Fatalf("write mac: %v", err)
	}

	waitForSessionState(t, rt, transportStateClosed)
	if got := rt.lastError; !strings.Contains(got, "bad_sequence:2_expected:1") {
		t.Fatalf("lastError = %q, want bad_sequence", got)
	}
	<-done
}

func TestRuntimeTransportSessionReaderLoopRejectsWrongDirectionKey(t *testing.T) {
	rt, clientConn, serverConn := newOpenRuntimeTransportSessionForReaderTest()
	defer clientConn.Close()
	defer serverConn.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		rt.readerLoop()
	}()

	payload := []byte{}
	header := sessionHeaderForTest(transportFrameGoAway, 1, payload)
	mac := hmacSHA256(rt.goToDartKey, append(header, payload...))
	if _, err := serverConn.Write(header); err != nil {
		t.Fatalf("write header: %v", err)
	}
	if _, err := serverConn.Write(mac); err != nil {
		t.Fatalf("write mac: %v", err)
	}

	waitForSessionState(t, rt, transportStateClosed)
	if got := rt.lastError; got != "bad_frame_mac" {
		t.Fatalf("lastError = %q, want bad_frame_mac", got)
	}
	<-done
}

func TestRuntimeTransportSessionReaderLoopRejectsBadFrameVersion(t *testing.T) {
	rt, clientConn, serverConn := newOpenRuntimeTransportSessionForReaderTest()
	defer clientConn.Close()
	defer serverConn.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		rt.readerLoop()
	}()

	payload := []byte{}
	header := sessionHeaderForTest(transportFrameGoAway, 1, payload)
	header[0] = 99
	mac := hmacSHA256(rt.dartToGoKey, append(header, payload...))
	if _, err := serverConn.Write(header); err != nil {
		t.Fatalf("write header: %v", err)
	}
	if _, err := serverConn.Write(mac); err != nil {
		t.Fatalf("write mac: %v", err)
	}

	waitForSessionState(t, rt, transportStateClosed)
	if got := rt.lastError; got != "bad_frame_version:99" {
		t.Fatalf("lastError = %q, want bad_frame_version:99", got)
	}
	<-done
}

func TestRuntimeTransportSessionReaderLoopGoAwayClosesImmediatelyWhenDrained(t *testing.T) {
	rt, clientConn, serverConn := newOpenRuntimeTransportSessionForReaderTest()
	defer clientConn.Close()
	defer serverConn.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		rt.readerLoop()
	}()

	payload := []byte{}
	header := sessionHeaderForTest(transportFrameGoAway, 1, payload)
	mac := hmacSHA256(rt.dartToGoKey, append(header, payload...))
	if _, err := serverConn.Write(header); err != nil {
		t.Fatalf("write header: %v", err)
	}
	if _, err := serverConn.Write(mac); err != nil {
		t.Fatalf("write mac: %v", err)
	}

	waitForSessionState(t, rt, transportStateClosed)
	if got := rt.lastError; got != "" {
		t.Fatalf("lastError = %q, want empty", got)
	}
	<-done
}

func TestRuntimeTransportSessionReaderLoopGoAwayForcesCloseAfterDrainTimeout(t *testing.T) {
	rt, clientConn, serverConn := newOpenRuntimeTransportSessionForReaderTest()
	defer clientConn.Close()
	defer serverConn.Close()
	rt.goAwayDrainTimeout = 50 * time.Millisecond

	streamConn, peerConn := net.Pipe()
	defer peerConn.Close()
	st := &runtimeStream{
		id:         2,
		conn:       streamConn,
		outbound:   transportInitialStreamCredit,
		writeQueue: make(chan runtimeConnWriteOp, transportConnWriteQueueCap),
	}
	st.cond = sync.NewCond(&st.mu)
	rt.streams[st.id] = st

	done := make(chan struct{})
	go func() {
		defer close(done)
		rt.readerLoop()
	}()

	payload := []byte{}
	header := sessionHeaderForTest(transportFrameGoAway, 1, payload)
	mac := hmacSHA256(rt.dartToGoKey, append(header, payload...))
	if _, err := serverConn.Write(header); err != nil {
		t.Fatalf("write header: %v", err)
	}
	if _, err := serverConn.Write(mac); err != nil {
		t.Fatalf("write mac: %v", err)
	}

	waitForSessionState(t, rt, transportStateClosing)
	waitForSessionState(t, rt, transportStateClosed)
	if got := rt.lastError; got != "goaway_drain_timeout" {
		t.Fatalf("lastError = %q, want goaway_drain_timeout", got)
	}
	<-done
}

func TestRuntimeTransportSessionGracefulStreamFinalizationRemovesLiveStream(t *testing.T) {
	rt := newTestRuntimeTransportSession()
	clientConn, serverConn := net.Pipe()
	defer clientConn.Close()
	defer serverConn.Close()

	st := &runtimeStream{
		id:         2,
		conn:       clientConn,
		outbound:   transportInitialStreamCredit,
		writeQueue: make(chan runtimeConnWriteOp, transportConnWriteQueueCap),
	}
	st.cond = sync.NewCond(&st.mu)
	rt.streams[st.id] = st

	rt.markStreamReadClosed(st)
	if _, ok := rt.streams[st.id]; !ok {
		t.Fatal("stream removed before both halves were terminal")
	}

	rt.markStreamWriteClosed(st)
	if _, ok := rt.streams[st.id]; ok {
		t.Fatal("stream still present after graceful two-sided completion")
	}
}

func TestRuntimeTransportSessionGracefulStreamFinalizationClosesClosingSession(t *testing.T) {
	rt := newTestRuntimeTransportSession()
	clientConn, serverConn := net.Pipe()
	defer clientConn.Close()
	defer serverConn.Close()

	rt.state = transportStateClosing
	rt.conn = serverConn
	rt.writerQ = make(chan runtimeOutboundFrame, transportWriterQueueCap)

	st := &runtimeStream{
		id:         2,
		conn:       clientConn,
		outbound:   transportInitialStreamCredit,
		writeQueue: make(chan runtimeConnWriteOp, transportConnWriteQueueCap),
	}
	st.cond = sync.NewCond(&st.mu)
	rt.streams[st.id] = st

	rt.markStreamReadClosed(st)
	if got := rt.state; got != transportStateClosing {
		t.Fatalf("state after one-way graceful close = %q, want %q", got, transportStateClosing)
	}

	rt.markStreamWriteClosed(st)
	waitForSessionState(t, rt, transportStateClosed)
}

func TestRuntimeTransportSessionReaderLoopRejectsMalformedCreditPayload(t *testing.T) {
	rt, clientConn, serverConn := newOpenRuntimeTransportSessionForReaderTest()
	defer clientConn.Close()
	defer serverConn.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		rt.readerLoop()
	}()

	payload := bytesOf(0x55, 8)
	header := sessionHeaderForTest(transportFrameCredit, 1, payload)
	mac := hmacSHA256(rt.dartToGoKey, append(header, payload...))
	if _, err := serverConn.Write(header); err != nil {
		t.Fatalf("write header: %v", err)
	}
	if _, err := serverConn.Write(payload); err != nil {
		t.Fatalf("write payload: %v", err)
	}
	if _, err := serverConn.Write(mac); err != nil {
		t.Fatalf("write mac: %v", err)
	}

	waitForSessionState(t, rt, transportStateClosed)
	if got := rt.lastError; !strings.Contains(got, "handle_frame:invalid credit payload") {
		t.Fatalf("lastError = %q, want invalid credit payload", got)
	}
	<-done
}

func TestRuntimeTransportSessionFailSessionClosesManagedResources(t *testing.T) {
	rt := newTestRuntimeTransportSession()
	rt.state = transportStateOpen

	sessionConn, sessionPeer := net.Pipe()
	defer sessionPeer.Close()
	rt.conn = sessionConn

	writerQ := make(chan runtimeOutboundFrame)
	rt.writerQ = writerQ

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.Listen: %v", err)
	}
	rt.tcpListeners[1234] = &runtimeTcpListener{
		port: 1234,
		ln:   listener,
		done: make(chan struct{}),
	}

	streamConn, streamPeer := net.Pipe()
	defer streamPeer.Close()
	streamWriteQ := make(chan runtimeConnWriteOp)
	stream := &runtimeStream{
		id:         7,
		conn:       streamConn,
		writeQueue: streamWriteQ,
	}
	stream.cond = sync.NewCond(&stream.mu)
	rt.streams[stream.id] = stream

	packetConn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.ListenPacket: %v", err)
	}
	binding := &runtimeDatagramBinding{
		id:        9,
		local:     endpointFromAddr(packetConn.LocalAddr()),
		transport: "udp",
		pc:        packetConn,
	}
	rt.bindings[binding.id] = binding

	rt.failSession("test-failure")

	if got := rt.state; got != transportStateClosed {
		t.Fatalf("state = %q, want %q", got, transportStateClosed)
	}
	if got := rt.lastError; got != "test-failure" {
		t.Fatalf("lastError = %q, want test-failure", got)
	}
	assertClosedOutboundFrameChannel(t, writerQ)
	assertClosedConnWriteChannel(t, streamWriteQ)

	stream.mu.Lock()
	reset := stream.reset
	stream.mu.Unlock()
	if !reset {
		t.Fatal("stream reset = false, want true after session failure")
	}
	if !binding.isClosed() {
		t.Fatal("binding should be closed after session failure")
	}
	if _, err := listener.Accept(); err == nil {
		t.Fatal("listener Accept succeeded after session failure, want closed listener")
	}
}

func TestRuntimeTransportSessionFailureRequiresTransportReset(t *testing.T) {
	mu.Lock()
	original := transportSession
	transportSession = nil
	mu.Unlock()
	t.Cleanup(func() {
		mu.Lock()
		if transportSession != nil && transportSession != original {
			transportSession.closeLocked()
		}
		transportSession = original
		mu.Unlock()
	})

	mu.Lock()
	ensureRuntimeTransportLocked()
	first := runtimeTransportBootstrapLocked()
	rt := transportSession
	mu.Unlock()
	if rt == nil || first == nil {
		t.Fatal("transport session/bootstrap not initialized")
	}

	rt.failSession("session-fatal")

	reqJSON, err := json.Marshal(runtimeAttachRequest{
		CarrierKind:   "loopback_tcp",
		ListenerOwner: "dart",
		Host:          "127.0.0.1",
		Port:          4000,
	})
	if err != nil {
		t.Fatalf("json.Marshal(runtimeAttachRequest): %v", err)
	}
	if err := AttachRuntimeTransport(string(reqJSON)); err == nil || !strings.Contains(err.Error(), "attach invalid in state closed") {
		t.Fatalf("AttachRuntimeTransport error = %v, want attach invalid in state closed", err)
	}

	mu.Lock()
	closeRuntimeTransportLocked()
	ensureRuntimeTransportLocked()
	second := runtimeTransportBootstrapLocked()
	mu.Unlock()
	if second == nil {
		t.Fatal("second transport bootstrap is nil")
	}
	if first.MasterSecretB64 == second.MasterSecretB64 {
		t.Fatal("master secret was reused after transport reset")
	}
	if first.SessionGenerationB64 == second.SessionGenerationB64 {
		t.Fatal("session generation was reused after transport reset")
	}
}

func newTestRuntimeTransportSession() *runtimeTransportSession {
	return &runtimeTransportSession{
		state:                transportStateIdle,
		preferredCarrier:     "loopback_tcp",
		listenerOwner:        "dart",
		listenerHost:         "127.0.0.1",
		listenerPort:         4100,
		masterSecret:         bytesOf(0x11, 32),
		sessionGenerationID:  bytesOf(0x22, 16),
		nextInboundStreamID:  2,
		nextOutboundStreamID: 1,
		nextBindingID:        2,
		streams:              map[uint64]*runtimeStream{},
		tcpListeners:         map[int]*runtimeTcpListener{},
		bindings:             map[uint64]*runtimeDatagramBinding{},
	}
}

func newOpenRuntimeTransportSessionForReaderTest() (*runtimeTransportSession, net.Conn, net.Conn) {
	rt := newTestRuntimeTransportSession()
	clientConn, serverConn := net.Pipe()
	rt.conn = clientConn
	rt.state = transportStateOpen
	rt.dartToGoKey = bytesOf(0x31, 32)
	rt.goToDartKey = bytesOf(0x32, 32)
	rt.readerDone = make(chan struct{})
	return rt, clientConn, serverConn
}

func respondWithServerHelloForTest(
	t *testing.T,
	serverConn net.Conn,
	rt *runtimeTransportSession,
	mutate func(*spikeHelloEnvelope, map[string]string),
) {
	t.Helper()
	clientHello, clientHelloCanonical := readClientHelloForTest(t, serverConn)

	serverNonce := bytesOf(0x33, 16)
	fields := map[string]string{
		"msg":                       "SERVER_HELLO",
		"selected_version":          "1",
		"client_nonce_b64":          clientHello.ClientNonceB64,
		"server_nonce_b64":          base64.RawURLEncoding.EncodeToString(serverNonce),
		"session_generation_id_b64": clientHello.SessionGenerationID,
		"carrier_kind":              rt.preferredCarrier,
		"listener_owner":            rt.listenerOwner,
		"listener_endpoint":         rt.listenerEndpoint(),
		"accepted_capabilities":     "",
	}
	hello := &spikeHelloEnvelope{
		Type:                "SERVER_HELLO",
		SelectedVersion:     transportProtocolVersion,
		ServerNonceB64:      fields["server_nonce_b64"],
		SessionGenerationID: fields["session_generation_id_b64"],
		CarrierKind:         fields["carrier_kind"],
		ListenerOwner:       fields["listener_owner"],
		ListenerEndpoint:    fields["listener_endpoint"],
		AcceptedCaps:        []string{},
	}

	if mutate != nil {
		mutate(hello, fields)
	}
	if selectedVersion, err := strconv.Atoi(fields["selected_version"]); err == nil {
		hello.SelectedVersion = selectedVersion
	}
	hello.SessionGenerationID = fields["session_generation_id_b64"]
	hello.CarrierKind = fields["carrier_kind"]
	hello.ListenerOwner = fields["listener_owner"]
	hello.ListenerEndpoint = fields["listener_endpoint"]
	if accepted := fields["accepted_capabilities"]; accepted == "" {
		hello.AcceptedCaps = []string{}
	}
	if hello.MacB64 == "" {
		handshakeKey := hkdfExtract(rt.sessionGenerationID, rt.masterSecret)
		serverHelloCanonical := canonicalLines(fields)
		hello.MacB64 = base64.RawURLEncoding.EncodeToString(
			hmacSHA256(handshakeKey, appendWithNull(clientHelloCanonical, serverHelloCanonical)),
		)
	}
	if err := writeLengthPrefixedJSON(serverConn, hello); err != nil {
		t.Fatalf("writeLengthPrefixedJSON: %v", err)
	}
}

func readClientHelloForTest(t *testing.T, conn net.Conn) (spikeHelloEnvelope, []byte) {
	t.Helper()
	var clientHello spikeHelloEnvelope
	if err := readLengthPrefixedJSON(conn, &clientHello); err != nil {
		t.Fatalf("readLengthPrefixedJSON(client hello): %v", err)
	}
	clientHelloCanonical := canonicalLines(map[string]string{
		"msg":                       "CLIENT_HELLO",
		"session_protocol_versions": "1",
		"client_nonce_b64":          clientHello.ClientNonceB64,
		"session_generation_id_b64": clientHello.SessionGenerationID,
		"carrier_kind":              clientHello.CarrierKind,
		"listener_owner":            clientHello.ListenerOwner,
		"listener_endpoint":         clientHello.ListenerEndpoint,
		"requested_capabilities":    "",
	})
	return clientHello, clientHelloCanonical
}

func writeRawLengthPrefixed(conn net.Conn, payload []byte) error {
	header := make([]byte, 4)
	binary.BigEndian.PutUint32(header, uint32(len(payload)))
	if _, err := conn.Write(header); err != nil {
		return err
	}
	_, err := conn.Write(payload)
	return err
}

func sessionHeaderForTest(kind uint8, seq uint64, payload []byte) []byte {
	header := make([]byte, 16)
	header[0] = transportProtocolVersion
	header[1] = kind
	binary.BigEndian.PutUint64(header[4:12], seq)
	binary.BigEndian.PutUint32(header[12:16], uint32(len(payload)))
	return header
}

func waitForSessionState(t *testing.T, rt *runtimeTransportSession, want string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		rt.mu.Lock()
		state := rt.state
		rt.mu.Unlock()
		if state == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	rt.mu.Lock()
	state := rt.state
	lastError := rt.lastError
	rt.mu.Unlock()
	t.Fatalf("timed out waiting for state %q; current state=%q lastError=%q", want, state, lastError)
}

func assertClosedOutboundFrameChannel(t *testing.T, ch chan runtimeOutboundFrame) {
	t.Helper()
	select {
	case _, ok := <-ch:
		if ok {
			t.Fatal("runtime outbound frame channel is still open")
		}
	default:
		t.Fatal("runtime outbound frame channel was not closed")
	}
}

func assertClosedConnWriteChannel(t *testing.T, ch chan runtimeConnWriteOp) {
	t.Helper()
	select {
	case _, ok := <-ch:
		if ok {
			t.Fatal("stream write queue is still open")
		}
	default:
		t.Fatal("stream write queue was not closed")
	}
}

func bytesOf(value byte, length int) []byte {
	out := make([]byte, length)
	for index := range out {
		out[index] = value
	}
	return out
}
