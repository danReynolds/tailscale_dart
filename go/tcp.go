package tailscale

import (
	"io"
	"net"
	"time"
)

// keepAlivePeriod is sent by both ends of a proxied conn so we notice
// silently-dead peers within a couple of minutes rather than a couple of hours
// (the OS default).
const keepAlivePeriod = 30 * time.Second

// configureTCP enables TCP keep-alive. No-op on non-TCP conns, including the
// socketpair side of the POSIX fd backend.
func configureTCP(conn net.Conn) {
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetKeepAlive(true)
		_ = tc.SetKeepAlivePeriod(keepAlivePeriod)
	}
}

// pipe shuttles bytes bidirectionally between a and b, preserving TCP
// half-close semantics: when one side reaches EOF, the other side's write half
// is closed via CloseWrite so the peer sees end-of-stream instead of a full
// reset. Both conns are full-closed once both directions drain.
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

	_ = a.Close()
	_ = b.Close()
}

// closeWriteOrFull half-closes the write side if the conn supports it,
// otherwise full-closes.
func closeWriteOrFull(c net.Conn) {
	if cw, ok := c.(interface{ CloseWrite() error }); ok {
		_ = cw.CloseWrite()
		return
	}
	_ = c.Close()
}
