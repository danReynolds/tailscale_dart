//go:build !windows

package tailscale

import (
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"os"
	"runtime"
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

// tcpFdListenerID allocates monotonic listener ids; see fdRegistry for why
// the counter stays process-global while the maps live on the runtime.
var tcpFdListenerID int64

// TcpDialFd opens an outbound TCP connection for the exact captured runtime
// token and returns a POSIX fd connected to that tailnet stream.
//
// The returned fd is owned by the caller. Go keeps the other side of a
// socketpair and pipes it to the tsnet connection.
func TcpDialFd(runtimeToken uint64, host string, port int, timeout time.Duration) (*TcpFdConn, error) {
	gate, err := gateForRuntimeToken("TcpDialFd", runtimeToken)
	if err != nil {
		return nil, err
	}
	if host == "" {
		return nil, errors.New("host is required")
	}
	if port < 1 || port > 65535 {
		return nil, fmt.Errorf("invalid port %d", port)
	}

	// Bounded even with no caller timeout — see defaultNativeCallTimeout.
	ctx, cancel := boundedCallCtxFrom(gate.runtime.ctx, timeout)
	defer cancel()
	if err := gate.awaitDataPlaneReady(ctx); err != nil {
		return nil, fmt.Errorf("tailnet dial data plane: %w", err)
	}

	tailConn, err := gate.s.Dial(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	err = gate.runtime.resultError(err)
	if err != nil {
		if tailConn != nil {
			_ = tailConn.Close()
		}
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

// TcpListenFd starts a tailnet TCP listener for the exact captured runtime
// token and registers it in that runtime's listener registry.
//
// Like TcpDialFd, this runs as a capped caller-isolate offload, never on the
// worker FIFO: the readiness wait below may park for the remainder of the
// bounded first-Up publication bootstrap, and that park must not head-of-line
// block worker RPCs queued behind it.
func TcpListenFd(runtimeToken uint64, tailnetPort int, tailnetHost string) (*TcpFdListener, error) {
	if tailnetPort < 0 || tailnetPort > 65535 {
		return nil, fmt.Errorf("invalid port %d", tailnetPort)
	}

	gate, err := gateForRuntimeToken("TcpListenFd", runtimeToken)
	if err != nil {
		return nil, err
	}
	if err := gate.awaitDataPlaneReadyForCall(); err != nil {
		return nil, fmt.Errorf("tcp listen data plane: %w", err)
	}

	addr := net.JoinHostPort(tailnetHost, strconv.Itoa(tailnetPort))
	ln, err := gate.s.Listen("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("tsnet listen %s: %w", addr, err)
	}

	return registerTcpFdListener(gate, ln, tailnetHost)
}

// TlsListenFd starts a TLS-terminated tailnet listener for the exact captured
// runtime token. Offloaded like TcpListenFd — see that function's comment for
// why this must never execute on the worker FIFO.
func TlsListenFd(runtimeToken uint64, tailnetPort int, tailnetHost string) (*TcpFdListener, error) {
	if err := validateTLSListenPlatform(runtime.GOOS); err != nil {
		return nil, err
	}
	if tailnetPort < 0 || tailnetPort > 65535 {
		return nil, fmt.Errorf("invalid port %d", tailnetPort)
	}

	gate, err := gateForRuntimeToken("TlsListenFd", runtimeToken)
	if err != nil {
		return nil, err
	}
	if err := gate.awaitDataPlaneReadyForCall(); err != nil {
		return nil, fmt.Errorf("tls listen data plane: %w", err)
	}
	if gate.runtime.localClient == nil {
		return nil, errors.New("tls listen local client is unavailable")
	}
	getCertificate := secureRuntimeCertificateGetter(
		gate.runtime.runtimeDir,
		gate.runtime.localClient.GetCertificate,
	)

	addr := net.JoinHostPort(tailnetHost, strconv.Itoa(tailnetPort))
	ln, err := listenTLSOnReadyServer(
		gate.s,
		getCertificate,
		"tcp",
		addr,
	)
	if err != nil {
		return nil, fmt.Errorf("tsnet listen tls %s: %w", addr, err)
	}

	return registerTcpFdListener(gate, ln, tailnetHost)
}

func secureRuntimeCertificateGetter(
	runtimeDir string,
	getCertificate func(*tls.ClientHelloInfo) (*tls.Certificate, error),
) func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	var validationOnce sync.Once
	var validationErr error
	return func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
		certificate, err := getCertificate(hello)
		if err != nil {
			return nil, err
		}
		validationOnce.Do(func() {
			validationErr = secureRuntimeSidecarTree(runtimeDir)
		})
		if validationErr != nil {
			return nil, fmt.Errorf("validate TLS sidecars after certificate retrieval: %w", validationErr)
		}
		return certificate, nil
	}
}

func validateTLSListenPlatform(goos string) error {
	switch goos {
	case "android", "ios":
		return fmt.Errorf(
			"tls.bind is not supported on %s: upstream Tailscale disables its LocalAPI certificate endpoint on mobile",
			goos,
		)
	default:
		return nil
	}
}

// readyTLSListenServer is the subset of tsnet.Server used after the runtime's
// mandatory first-Up bootstrap has completed. Deliberately absent is
// ListenTLS: that convenience method calls Server.Up internally and would
// create a second lifecycle/publication-reset authority.
//
// listenTLSOnReadyServer therefore mirrors the composition inside upstream
// tsnet.Server.ListenTLS (tsnet/tsnet.go, v1.102.2) minus its internal Up
// call; diff it against upstream on every tailscale.com bump.
type readyTLSListenServer interface {
	CertDomains() []string
	Listen(network, addr string) (net.Listener, error)
}

func listenTLSOnReadyServer(
	s readyTLSListenServer,
	getCertificate func(*tls.ClientHelloInfo) (*tls.Certificate, error),
	network string,
	addr string,
) (net.Listener, error) {
	if len(s.CertDomains()) == 0 {
		return nil, fmt.Errorf("%w: tsnet: you must enable HTTPS in the admin panel to proceed. See https://tailscale.com/s/https", errFeatureUnavailable)
	}
	ln, err := s.Listen(network, addr)
	if err != nil {
		return nil, err
	}
	return tls.NewListener(ln, &tls.Config{GetCertificate: getCertificate}), nil
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
	// Commit-point check (see fdRegistry): a listen that raced teardown must
	// not land behind the runtime sweep, where it would hold its tailnet port
	// with no owner until process exit.
	if !gate.runtime.fd.tcpListeners.commit(gate, id, ln) {
		ln.Close()
		return nil, errors.New("tcp listen raced node teardown")
	}

	return &TcpFdListener{
		ID:           id,
		LocalAddress: localAddress,
		LocalPort:    localPort,
	}, nil
}

func TcpAcceptFd(listenerID int64) (*TcpFdConn, bool, error) {
	listeners := currentTcpListeners()
	ln, ok := listeners.get(listenerID)
	if !ok {
		return nil, true, nil
	}

	tailConn, err := ln.Accept()
	if err != nil {
		if errors.Is(err, net.ErrClosed) {
			listeners.removeMatching(listenerID, ln)
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
	ln, _ := currentTcpListeners().take(listenerID)
	if ln != nil {
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
