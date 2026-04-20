package tailscale

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// loopbackAcceptTimeout bounds how long an outbound bridge waits
// for the Dart-side Socket to connect + authenticate. The bridge
// accepts multiple times within this window so a co-resident
// attacker sending a bad token doesn't DoS the legitimate dialer.
const loopbackAcceptTimeout = 10 * time.Second

// loopbackAuthTimeout bounds how long we wait for a single accepted
// loopback conn to send its auth token before giving up on it and
// accepting the next one.
const loopbackAuthTimeout = 2 * time.Second

// bindLoopbackDialTimeout bounds how long Go waits to reach the
// Dart-owned loopback listener per accepted tailnet conn.
const bindLoopbackDialTimeout = 5 * time.Second

// keepAlivePeriod is sent by both ends of a bridged conn so we
// notice silently-dead peers within a couple of minutes rather than
// a couple of hours (the OS default).
const keepAlivePeriod = 30 * time.Second

// TcpDial opens an outbound TCP connection to a tailnet peer via the
// embedded tsnet.Server, and sets up a short-lived loopback bridge so
// the Dart side can reach it through a standard dart:io Socket.
//
// Returns (loopbackPort, token). Dart connects to 127.0.0.1:loopbackPort,
// writes the token as the first bytes on the wire, and after that gets a
// transparent byte pipe to the tailnet peer. The bridge listener keeps
// accepting until a valid-token client authenticates or the overall
// accept timeout elapses — so a co-resident process that sends a bad
// token doesn't consume the single-shot bridge.
//
// timeout applies to the tailnet dial only, not the lifetime of the
// bridged connection. Zero means no timeout.
func TcpDial(host string, port int, timeout time.Duration) (int, string, error) {
	if host == "" {
		return 0, "", errors.New("host is required")
	}
	if port < 1 || port > 65535 {
		return 0, "", fmt.Errorf("invalid port %d", port)
	}

	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return 0, "", errors.New("TcpDial called before Start")
	}

	// Dial the tailnet peer first — if this fails, we don't bother
	// opening a loopback listener.
	ctx := context.Background()
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	tailConn, err := s.Dial(ctx, "tcp", net.JoinHostPort(host, fmt.Sprintf("%d", port)))
	if err != nil {
		return 0, "", fmt.Errorf("tailnet dial %s:%d: %w", host, port, err)
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		tailConn.Close()
		return 0, "", fmt.Errorf("open loopback bridge listener: %w", err)
	}

	token, err := randomHexToken(16)
	if err != nil {
		ln.Close()
		tailConn.Close()
		return 0, "", fmt.Errorf("generate bridge auth token: %w", err)
	}

	loopbackPort := ln.Addr().(*net.TCPAddr).Port

	go runDialBridge(ln, tailConn, token)

	return loopbackPort, token, nil
}

// runDialBridge accepts loopback connections until one authenticates
// successfully, then hands off to pipe. Unauthenticated clients get
// their conn closed but don't consume the bridge.
func runDialBridge(ln net.Listener, tailConn net.Conn, expectedToken string) {
	defer ln.Close()
	deadline := time.Now().Add(loopbackAcceptTimeout)

	for {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			tcpLog("dial bridge: accept timeout; tearing down tailnet conn")
			tailConn.Close()
			return
		}
		if tcpLn, ok := ln.(*net.TCPListener); ok {
			tcpLn.SetDeadline(deadline)
		}

		conn, err := ln.Accept()
		if err != nil {
			// Either the overall deadline elapsed or the listener is
			// closed (which only happens from this goroutine via the
			// defer). Either way: give up, close the tailnet side.
			tcpLog("dial bridge: accept ended: %v", err)
			tailConn.Close()
			return
		}

		if authenticateLoopbackConn(conn, expectedToken) {
			configureTCP(conn)
			configureTCP(tailConn)
			pipe(conn, tailConn)
			return
		}

		// Bad token. Close this conn and keep accepting — the real
		// Dart client may still be racing to connect.
		conn.Close()
	}
}

// authenticateLoopbackConn reads the auth token from conn within a
// bounded window and returns whether it matched expectedToken. On
// success the read deadline is cleared so subsequent pipe reads are
// unbounded.
func authenticateLoopbackConn(conn net.Conn, expectedToken string) bool {
	if tc, ok := conn.(*net.TCPConn); ok {
		tc.SetReadDeadline(time.Now().Add(loopbackAuthTimeout))
	}
	received := make([]byte, len(expectedToken))
	if _, err := io.ReadFull(conn, received); err != nil {
		return false
	}
	if subtle.ConstantTimeCompare(received, []byte(expectedToken)) != 1 {
		return false
	}
	if tc, ok := conn.(*net.TCPConn); ok {
		tc.SetReadDeadline(time.Time{})
	}
	return true
}

// configureTCP enables TCP keep-alive so a silently-dead peer is
// detected within minutes rather than hours. No-op on non-TCP
// conns (e.g. net.Pipe in unit tests).
func configureTCP(conn net.Conn) {
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetKeepAlive(true)
		_ = tc.SetKeepAlivePeriod(keepAlivePeriod)
	}
}

// pipe shuttles bytes bidirectionally between a and b, preserving
// TCP half-close semantics: when one side reaches EOF, the other
// side's write half is closed via CloseWrite (so the peer sees the
// end-of-stream signal), not a full RST. Both conns are
// unconditionally full-closed once both directions have drained.
//
// For non-TCP conns (e.g. net.Pipe in tests) that don't implement
// CloseWrite, we fall back to full-close on EOF.
func pipe(a, b net.Conn) {
	done := make(chan struct{}, 2)

	go func() {
		_, _ = io.Copy(a, b) // reads from b, writes to a
		closeWriteOrFull(a)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(b, a) // reads from a, writes to b
		closeWriteOrFull(b)
		done <- struct{}{}
	}()

	<-done
	<-done

	// Drop any lingering read sides + free file descriptors.
	a.Close()
	b.Close()
}

// closeWriteOrFull half-closes the write side if the conn supports
// it, otherwise full-closes.
func closeWriteOrFull(c net.Conn) {
	if cw, ok := c.(interface{ CloseWrite() error }); ok {
		_ = cw.CloseWrite()
		return
	}
	_ = c.Close()
}

func randomHexToken(byteLen int) (string, error) {
	buf := make([]byte, byteLen)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

// tcpBindRegistry tracks active inbound TCP bridges so TcpUnbind can
// tear down a specific one without affecting others. Keyed by the
// Dart-owned loopback port (unique per bind on a given node).
var (
	tcpBindRegistry   = map[int]net.Listener{}
	tcpBindRegistryMu sync.Mutex
)

// TcpBind starts an inbound TCP bridge: this node's tsnet.Server
// listens on `tailnetPort` (optionally restricted to `tailnetHost`,
// one of this node's tailnet IPs), and every accepted tailnet
// connection is forwarded to the Dart-owned loopback listener at
// `127.0.0.1:loopbackPort`.
//
// Pass `tailnetPort = 0` to request an ephemeral tailnet port; the
// actual assigned port is returned.
//
// Dart is expected to have already bound the loopback ServerSocket
// before this call so the very first tailnet accept has somewhere to
// go. Tear down with TcpUnbind(loopbackPort); the bridge also tears
// itself down if it detects the Dart loopback is unreachable
// (i.e. Dart closed its ServerSocket).
//
// Note on auth: no per-connection token. Inbound connections are
// initiated by Go to the Dart loopback, so a co-resident process
// *could* connect to the same loopback port and impersonate a
// tailnet peer to the Dart server. Defense-in-depth would require
// either UDS (non-Windows) or wrapping the ServerSocket stream with
// a handshake that the Dart library filters before yielding each
// Socket. Both are plausible follow-ups; shipping the loopback
// variant first keeps the Socket type clean.
func TcpBind(tailnetPort int, tailnetHost string, loopbackPort int) (int, error) {
	if tailnetPort < 0 || tailnetPort > 65535 {
		return 0, fmt.Errorf("invalid tailnet port %d", tailnetPort)
	}
	if loopbackPort < 1 || loopbackPort > 65535 {
		return 0, fmt.Errorf("invalid loopback port %d", loopbackPort)
	}

	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return 0, errors.New("TcpBind called before Start")
	}

	addr := fmt.Sprintf(":%d", tailnetPort)
	if tailnetHost != "" {
		addr = net.JoinHostPort(tailnetHost, fmt.Sprintf("%d", tailnetPort))
	}

	ln, err := s.Listen("tcp", addr)
	if err != nil {
		return 0, fmt.Errorf("tsnet listen %s: %w", addr, err)
	}

	actualPort := 0
	if tcpAddr, ok := ln.Addr().(*net.TCPAddr); ok {
		actualPort = tcpAddr.Port
	}
	if actualPort == 0 {
		// tsnet should always give us a concrete port. If it didn't,
		// the caller can't tell peers where to connect, so fail loudly
		// rather than returning 0.
		ln.Close()
		return 0, fmt.Errorf("tsnet listen returned unresolved port")
	}

	tcpBindRegistryMu.Lock()
	// Replace any stale entry on the same loopback port (should be
	// rare — the Dart side gets a new ephemeral port per bind call).
	if prev, ok := tcpBindRegistry[loopbackPort]; ok {
		prev.Close()
	}
	tcpBindRegistry[loopbackPort] = ln
	tcpBindRegistryMu.Unlock()

	go bindAcceptLoop(ln, loopbackPort)
	return actualPort, nil
}

// TcpUnbind tears down the inbound bridge registered against
// `loopbackPort`. Idempotent — unknown ports are a no-op.
func TcpUnbind(loopbackPort int) {
	tcpBindRegistryMu.Lock()
	ln, ok := tcpBindRegistry[loopbackPort]
	delete(tcpBindRegistry, loopbackPort)
	tcpBindRegistryMu.Unlock()
	if ok {
		ln.Close()
	}
}

// bindAcceptLoop forwards each tailnet Accept to the Dart-owned
// loopback listener. Each accept spawns its own goroutine to do the
// loopback dial + pipe so a slow loopback dial doesn't block further
// tailnet accepts.
//
// If a loopback dial fails, we assume the Dart side shut down and
// tear ourselves out of the registry (and close the tailnet
// listener) so it doesn't linger forever.
func bindAcceptLoop(tailnetLn net.Listener, loopbackPort int) {
	for {
		tailConn, err := tailnetLn.Accept()
		if err != nil {
			break
		}
		go forwardBindAccept(tailConn, loopbackPort, tailnetLn)
	}

	tcpBindRegistryMu.Lock()
	if tcpBindRegistry[loopbackPort] == tailnetLn {
		delete(tcpBindRegistry, loopbackPort)
	}
	tcpBindRegistryMu.Unlock()
}

// forwardBindAccept dials the Dart-owned loopback for a single
// accepted tailnet conn and pipes bytes between them. Runs on its
// own goroutine so a slow loopback dial doesn't hold up further
// tailnet accepts.
//
// If the loopback is unreachable, this goroutine closes the tailnet
// listener, which unblocks bindAcceptLoop's next Accept, and the
// registry cleans itself up.
func forwardBindAccept(tailConn net.Conn, loopbackPort int, tailnetLn net.Listener) {
	dartConn, err := net.DialTimeout(
		"tcp",
		fmt.Sprintf("127.0.0.1:%d", loopbackPort),
		bindLoopbackDialTimeout,
	)
	if err != nil {
		tailConn.Close()
		// Dart side is gone (or transiently unreachable). Tear down.
		tcpLog("bind: loopback unreachable (port %d): %v; tearing down", loopbackPort, err)
		tailnetLn.Close()
		return
	}

	configureTCP(tailConn)
	configureTCP(dartConn)
	pipe(tailConn, dartConn)
}

// tcpLog writes a message when LogLevel >= info. Silent by default
// so production logs aren't noisy; flip on via DuneSetLogLevel(2)
// when debugging bridge behavior.
func tcpLog(format string, args ...any) {
	if atomic.LoadInt32(&LogLevel) >= 2 {
		log.Printf("tailscale/tcp: "+format, args...)
	}
}
