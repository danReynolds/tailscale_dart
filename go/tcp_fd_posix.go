//go:build !windows

package tailscale

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/sys/unix"
)

type TcpFdConn struct {
	FD            int
	LocalAddress  string
	LocalPort     int
	RemoteAddress string
	RemotePort    int
	// Identity is the resolved identity of the remote node, attached at
	// accept time for inbound connections. Nil for outbound dials and
	// when the accept-time WhoIs lookup found nothing or failed.
	Identity *nodeIdentity
}

type TcpFdListener struct {
	ID           int64
	LocalAddress string
	LocalPort    int
}

var (
	tcpFdListenerID       int64
	tcpFdListenerRegistry = map[int64]net.Listener{}
	tcpFdListenerMu       sync.Mutex
)

// TcpDialFd opens an outbound TCP connection to a tailnet peer and returns a
// POSIX fd connected to that stream.
//
// The returned fd is owned by the caller. Go keeps the other side of a
// socketpair and pipes it to the tsnet connection.
func TcpDialFd(host string, port int, timeout time.Duration) (*TcpFdConn, error) {
	if host == "" {
		return nil, errors.New("host is required")
	}
	if port < 1 || port > 65535 {
		return nil, fmt.Errorf("invalid port %d", port)
	}

	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return nil, errors.New("TcpDialFd called before Start")
	}

	ctx := context.Background()
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}

	tailConn, err := s.Dial(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		return nil, fmt.Errorf("tailnet dial %s:%d: %w", host, port, err)
	}

	dartFd, goConn, err := newSocketPairConn()
	if err != nil {
		tailConn.Close()
		return nil, err
	}

	configureTCP(tailConn)
	localAddress, localPort := endpointFromAddr(tailConn.LocalAddr())
	remoteAddress, remotePort := endpointFromAddr(tailConn.RemoteAddr())
	go pipe(goConn, tailConn)
	return &TcpFdConn{
		FD:            dartFd,
		LocalAddress:  localAddress,
		LocalPort:     localPort,
		RemoteAddress: remoteAddress,
		RemotePort:    remotePort,
	}, nil
}

func TcpListenFd(tailnetPort int, tailnetHost string) (*TcpFdListener, error) {
	if tailnetPort < 0 || tailnetPort > 65535 {
		return nil, fmt.Errorf("invalid port %d", tailnetPort)
	}

	gate, ok := acquireNodeGate()
	if !ok {
		return nil, errors.New("TcpListenFd called before Start")
	}

	addr := net.JoinHostPort(tailnetHost, strconv.Itoa(tailnetPort))
	ln, err := gate.s.Listen("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("tsnet listen %s: %w", addr, err)
	}

	return registerTcpFdListener(gate, ln, tailnetHost)
}

func TlsListenFd(tailnetPort int, tailnetHost string) (*TcpFdListener, error) {
	if tailnetPort < 0 || tailnetPort > 65535 {
		return nil, fmt.Errorf("invalid port %d", tailnetPort)
	}

	gate, ok := acquireNodeGate()
	if !ok {
		return nil, errors.New("TlsListenFd called before Start")
	}

	addr := net.JoinHostPort(tailnetHost, strconv.Itoa(tailnetPort))
	ln, err := gate.s.ListenTLS("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("tsnet listen tls %s: %w", addr, err)
	}

	return registerTcpFdListener(gate, ln, tailnetHost)
}

func registerTcpFdListener(gate nodeGate, ln net.Listener, fallbackAddress string) (*TcpFdListener, error) {
	localAddress, localPort := endpointFromAddr(ln.Addr())
	if localPort == 0 {
		ln.Close()
		return nil, fmt.Errorf("tsnet listen returned unresolved port")
	}
	if localAddress == "" {
		localAddress = fallbackAddress
	}

	id := atomic.AddInt64(&tcpFdListenerID, 1)
	tcpFdListenerMu.Lock()
	// Commit-point epoch check (see nodeGate): a listen that raced teardown
	// must not land in the registry behind closeAllTcpFdListeners' sweep,
	// where it would hold its tailnet port with no owner until process exit.
	if !gate.stillCurrent() {
		tcpFdListenerMu.Unlock()
		ln.Close()
		return nil, errors.New("tcp listen raced node teardown")
	}
	tcpFdListenerRegistry[id] = ln
	tcpFdListenerMu.Unlock()

	return &TcpFdListener{
		ID:           id,
		LocalAddress: localAddress,
		LocalPort:    localPort,
	}, nil
}

func TcpAcceptFd(listenerID int64) (*TcpFdConn, bool, error) {
	tcpFdListenerMu.Lock()
	ln := tcpFdListenerRegistry[listenerID]
	tcpFdListenerMu.Unlock()
	if ln == nil {
		return nil, true, nil
	}

	tailConn, err := ln.Accept()
	if err != nil {
		if errors.Is(err, net.ErrClosed) {
			tcpFdListenerMu.Lock()
			if tcpFdListenerRegistry[listenerID] == ln {
				delete(tcpFdListenerRegistry, listenerID)
			}
			tcpFdListenerMu.Unlock()
			return nil, true, nil
		}
		return nil, false, fmt.Errorf("tailnet accept: %w", err)
	}

	dartFd, goConn, err := newSocketPairConn()
	if err != nil {
		tailConn.Close()
		return nil, false, err
	}

	configureTCP(tailConn)
	localAddress, localPort := endpointFromAddr(tailConn.LocalAddr())
	remoteAddress, remotePort := endpointFromAddr(tailConn.RemoteAddr())
	// Resolve the remote node's identity before handing the connection to
	// Dart so authorization decisions don't need a second async round-trip.
	// Best-effort: a nil result still delivers the connection (IP-only).
	identity := lookupNodeIdentity(remoteAddress)
	go pipe(goConn, tailConn)
	return &TcpFdConn{
		FD:            dartFd,
		LocalAddress:  localAddress,
		LocalPort:     localPort,
		RemoteAddress: remoteAddress,
		RemotePort:    remotePort,
		Identity:      identity,
	}, false, nil
}

func TcpCloseFdListener(listenerID int64) {
	tcpFdListenerMu.Lock()
	ln := tcpFdListenerRegistry[listenerID]
	delete(tcpFdListenerRegistry, listenerID)
	tcpFdListenerMu.Unlock()
	if ln != nil {
		ln.Close()
	}
}

func closeAllTcpFdListeners() {
	tcpFdListenerMu.Lock()
	listeners := make([]net.Listener, 0, len(tcpFdListenerRegistry))
	for id, ln := range tcpFdListenerRegistry {
		listeners = append(listeners, ln)
		delete(tcpFdListenerRegistry, id)
	}
	tcpFdListenerMu.Unlock()

	for _, ln := range listeners {
		ln.Close()
	}
}

func endpointFromAddr(addr net.Addr) (string, int) {
	if addr == nil {
		return "", 0
	}
	host, portText, err := net.SplitHostPort(addr.String())
	if err != nil {
		return "", 0
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 0 || port > 65535 {
		return host, 0
	}
	return host, port
}

// socketPairBufferBytes is the SO_SNDBUF/SO_RCVBUF target for the bridge
// socketpairs. The OS default is small on macOS/iOS, which forces a full
// reactor write chunk (64 KiB) to drain across several EPOLLOUT cycles — each a
// reactor round-trip — capping single-stream throughput. A larger buffer lets a
// chunk land in one syscall and keeps a few chunks in flight. The kernel clamps
// to its own max (kern.ipc.maxsockbuf / net.core.wmem_max), so this is a hint.
const socketPairBufferBytes = 256 * 1024

// tuneSocketPairBuffers best-effort enlarges the send/receive buffers on both
// ends of a bridge socketpair. Errors are ignored: the platform may clamp the
// value and the default still works (just slower).
func tuneSocketPairBuffers(fds ...int) {
	for _, fd := range fds {
		_ = unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_SNDBUF, socketPairBufferBytes)
		_ = unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_RCVBUF, socketPairBufferBytes)
	}
}

func newSocketPairConn() (int, net.Conn, error) {
	dartFd, goFd, err := newSocketPairCloexec(unix.SOCK_STREAM)
	if err != nil {
		return -1, nil, err
	}
	// Enlarge both ends before either side is used; the setting lives on the
	// socket and survives the net.FileConn dup below.
	tuneSocketPairBuffers(dartFd, goFd)

	file := os.NewFile(uintptr(goFd), "tailscale-dart-tcp-go")
	if file == nil {
		_ = unix.Close(dartFd)
		_ = unix.Close(goFd)
		return -1, nil, errors.New("socketpair fd could not be wrapped")
	}

	// From here on `file` owns goFd; file.Close() (below) closes it exactly
	// once, on both the success and the FileConn-error path. So the cleanup
	// defer must NOT also close goFd — doing so double-closes it, and under fd
	// pressure (EMFILE, which is exactly when FileConn's dup fails) the second
	// close can sever an unrelated freshly-allocated descriptor.
	success := false
	defer func() {
		if !success {
			_ = unix.Close(dartFd)
		}
	}()

	conn, err := net.FileConn(file)
	_ = file.Close()
	if err != nil {
		return -1, nil, fmt.Errorf("wrap socketpair fd: %w", err)
	}

	success = true
	return dartFd, conn, nil
}
