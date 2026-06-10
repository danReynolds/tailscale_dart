package tailscale

import (
	"io"
	"net"
	"sync"
	"time"
)

// keepAlivePeriod is sent by both ends of a proxied conn so we notice
// silently-dead peers within a couple of minutes rather than a couple of hours
// (the OS default).
const keepAlivePeriod = 30 * time.Second

// pipeBufferPool recycles the io.Copy transfer buffers used by pipe. Without
// pooling, each proxied connection allocates two fresh 32 KiB buffers (io.Copy's
// default) for its lifetime; under connection churn that is steady GC pressure.
// Neither side (Unix socketpair / tsnet gVisor conn) offers a ReaderFrom/WriterTo
// fast path, so io.CopyBuffer genuinely uses these.
var pipeBufferPool = sync.Pool{
	New: func() any {
		b := make([]byte, 64*1024)
		return &b
	},
}

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
		buf := pipeBufferPool.Get().(*[]byte)
		_, _ = io.CopyBuffer(a, b, *buf) // reads from b, writes to a
		pipeBufferPool.Put(buf)
		closeWriteOrFull(a)
		done <- struct{}{}
	}()
	go func() {
		buf := pipeBufferPool.Get().(*[]byte)
		_, _ = io.CopyBuffer(b, a, *buf) // reads from a, writes to b
		pipeBufferPool.Put(buf)
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
