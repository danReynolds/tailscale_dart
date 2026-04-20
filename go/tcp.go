package tailscale

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

// loopbackAcceptTimeout bounds how long the bridge waits for the
// Dart-side Socket to connect after we return. If Dart crashes or
// forgets to connect, the tailnet conn would leak without this.
const loopbackAcceptTimeout = 10 * time.Second

// TcpDial opens an outbound TCP connection to a tailnet peer via the
// embedded tsnet.Server, and sets up a short-lived loopback bridge so
// the Dart side can reach it through a standard dart:io Socket.
//
// Returns (loopbackPort, token). Dart connects to 127.0.0.1:loopbackPort,
// writes the token as the first bytes on the wire, and after that gets a
// transparent byte pipe to the tailnet peer. Co-resident processes can
// reach the ephemeral loopback port but can't authenticate past the
// token (32 hex chars generated per call from crypto/rand).
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
		return 0, "", fmt.Errorf("loopback listen: %w", err)
	}

	token, err := randomHexToken(16)
	if err != nil {
		ln.Close()
		tailConn.Close()
		return 0, "", fmt.Errorf("generate token: %w", err)
	}

	loopbackPort := ln.Addr().(*net.TCPAddr).Port

	go bridgeOne(ln, tailConn, token)

	return loopbackPort, token, nil
}

// bridgeOne accepts exactly one loopback connection from the Dart side,
// authenticates it with the expected token, and proxies bytes to/from
// the tailnet conn until either side hangs up. The listener is closed
// as soon as we accept (or fail to accept) — this is a single-use
// bridge.
func bridgeOne(ln net.Listener, tailConn net.Conn, expectedToken string) {
	defer ln.Close()

	if tcpLn, ok := ln.(*net.TCPListener); ok {
		// Prevent leaking the tailnet conn if Dart never connects.
		tcpLn.SetDeadline(time.Now().Add(loopbackAcceptTimeout))
	}

	dartConn, err := ln.Accept()
	if err != nil {
		tailConn.Close()
		return
	}
	// Clear any residual deadline on the accepted conn.
	if tc, ok := dartConn.(*net.TCPConn); ok {
		tc.SetDeadline(time.Time{})
	}

	// Bound the auth read so a co-resident process can't hang by
	// connecting and never writing.
	if tc, ok := dartConn.(*net.TCPConn); ok {
		tc.SetReadDeadline(time.Now().Add(5 * time.Second))
	}
	received := make([]byte, len(expectedToken))
	if _, err := io.ReadFull(dartConn, received); err != nil {
		dartConn.Close()
		tailConn.Close()
		return
	}
	if subtle.ConstantTimeCompare(received, []byte(expectedToken)) != 1 {
		dartConn.Close()
		tailConn.Close()
		return
	}
	if tc, ok := dartConn.(*net.TCPConn); ok {
		tc.SetReadDeadline(time.Time{})
	}

	pipe(dartConn, tailConn)
}

// pipe shuttles bytes bidirectionally between a and b until one side
// closes, then closes both.
func pipe(a, b net.Conn) {
	done := make(chan struct{}, 2)
	go func() {
		io.Copy(a, b)
		done <- struct{}{}
	}()
	go func() {
		io.Copy(b, a)
		done <- struct{}{}
	}()
	<-done
	a.Close()
	b.Close()
	<-done // drain the other side's completion signal
}

func randomHexToken(byteLen int) (string, error) {
	buf := make([]byte, byteLen)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

// bindLoopbackDialTimeout bounds how long Go waits to reach the
// Dart-owned loopback listener per accepted tailnet conn. Short — if
// the Dart side isn't reachable it almost certainly means the Dart
// process closed its ServerSocket.
const bindLoopbackDialTimeout = 5 * time.Second

// tcpBindRegistry tracks active inbound TCP bridges so TcpUnbind can
// tear down a specific one without affecting others. Keyed by the
// Dart-owned loopback port (which is unique per bind on a given node).
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
// Dart is expected to have already bound the loopback ServerSocket
// before this call so the very first tailnet accept has somewhere to
// go. Tear down with TcpUnbind(loopbackPort); the bridge also tears
// itself down if the next accepted tailnet conn can't reach the
// loopback (i.e. Dart closed its ServerSocket).
//
// Note on auth: no per-connection token. Inbound connections are
// initiated by Go to the Dart loopback, so a co-resident process
// *could* connect to the same loopback port and impersonate a
// tailnet peer to the Dart server. Defense-in-depth would require
// either UDS (non-Windows) or wrapping the ServerSocket stream with
// a handshake that the Dart library filters before yielding each
// Socket. Both are plausible follow-ups; shipping the loopback
// variant first keeps the Socket type clean.
func TcpBind(tailnetPort int, tailnetHost string, loopbackPort int) error {
	if tailnetPort < 1 || tailnetPort > 65535 {
		return fmt.Errorf("invalid tailnet port %d", tailnetPort)
	}
	if loopbackPort < 1 || loopbackPort > 65535 {
		return fmt.Errorf("invalid loopback port %d", loopbackPort)
	}

	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return errors.New("TcpBind called before Start")
	}

	addr := fmt.Sprintf(":%d", tailnetPort)
	if tailnetHost != "" {
		addr = net.JoinHostPort(tailnetHost, fmt.Sprintf("%d", tailnetPort))
	}

	ln, err := s.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("tsnet listen %s: %w", addr, err)
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
	return nil
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
// loopback listener. If the loopback dial fails, we assume the Dart
// side shut down and tear ourselves out of the registry so the
// tailnet listener doesn't linger forever.
func bindAcceptLoop(tailnetLn net.Listener, loopbackPort int) {
	for {
		tailConn, err := tailnetLn.Accept()
		if err != nil {
			// Accept failed because the listener was closed (by us
			// via TcpUnbind, or by tsnet.Server teardown).
			break
		}

		dartConn, err := net.DialTimeout(
			"tcp",
			fmt.Sprintf("127.0.0.1:%d", loopbackPort),
			bindLoopbackDialTimeout,
		)
		if err != nil {
			tailConn.Close()
			// Dart closed its loopback listener. Deregister and stop.
			tcpBindRegistryMu.Lock()
			delete(tcpBindRegistry, loopbackPort)
			tcpBindRegistryMu.Unlock()
			tailnetLn.Close()
			return
		}

		go pipe(tailConn, dartConn)
	}

	// Normal teardown — make sure the registry doesn't reference a
	// closed listener.
	tcpBindRegistryMu.Lock()
	if tcpBindRegistry[loopbackPort] == tailnetLn {
		delete(tcpBindRegistry, loopbackPort)
	}
	tcpBindRegistryMu.Unlock()
}
