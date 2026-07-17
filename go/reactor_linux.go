//go:build !windows && (linux || android)

package tailscale

import (
	"encoding/binary"
	"fmt"

	"golang.org/x/sys/unix"
)

// epollReactorPoller multiplexes one shard's fds via epoll on Linux/Android.
//
// EpollEvent only carries 32 bits of user data, but the public reactor API
// hands out int64 transport ids (matching the kqueue Udata pointer width on
// Darwin). We side-step the truncation by storing the id in fdToID and
// recovering it on dispatch via the fd reported by epoll.
type epollReactorPoller struct {
	epfd    int
	wakeFd  int
	fdToID  map[int]int64
	closed  bool
	scratch []unix.EpollEvent // reused across Wait calls to avoid per-poll alloc
}

func newReactorPoller() (reactorPoller, error) {
	epfd, err := unix.EpollCreate1(unix.EPOLL_CLOEXEC)
	if err != nil {
		return nil, fmt.Errorf("epoll_create1: %w", err)
	}
	wakeFd, err := unix.Eventfd(0, unix.EFD_NONBLOCK|unix.EFD_CLOEXEC)
	if err != nil {
		_ = unix.Close(epfd)
		return nil, fmt.Errorf("eventfd: %w", err)
	}
	p := &epollReactorPoller{
		epfd:   epfd,
		wakeFd: wakeFd,
		fdToID: map[int]int64{},
	}
	// We stash the wake fd's own value in EpollEvent.Fd; on dispatch we
	// recognise the wake by comparing ev.Fd == p.wakeFd. Real transport ids
	// live in the fdToID side-table because EpollEvent.Fd is only int32 and
	// transport ids are int64.
	if err := unix.EpollCtl(epfd, unix.EPOLL_CTL_ADD, wakeFd, &unix.EpollEvent{
		Events: unix.EPOLLIN,
		Fd:     int32(wakeFd),
	}); err != nil {
		_ = unix.Close(wakeFd)
		_ = unix.Close(epfd)
		return nil, fmt.Errorf("epoll wake register: %w", err)
	}
	return p, nil
}

func setReactorNonblock(fd int) error {
	if err := unix.SetNonblock(fd, true); err != nil {
		return fmt.Errorf("set nonblock fd %d: %w", fd, err)
	}
	return nil
}

func (p *epollReactorPoller) Close() error {
	if p.closed {
		return nil
	}
	p.closed = true
	err1 := unix.Close(p.wakeFd)
	err2 := unix.Close(p.epfd)
	if err1 != nil {
		return err1
	}
	return err2
}

func (p *epollReactorPoller) Wake() error {
	var buf [8]byte
	binary.LittleEndian.PutUint64(buf[:], 1)
	_, err := unix.Write(p.wakeFd, buf[:])
	if err == unix.EAGAIN {
		return nil
	}
	if err != nil {
		return fmt.Errorf("eventfd wake: %w", err)
	}
	return nil
}

func (p *epollReactorPoller) Register(fd int, id int64, events int) error {
	if err := p.epollCtl(unix.EPOLL_CTL_ADD, fd, events); err != nil {
		return err
	}
	p.fdToID[fd] = id
	return nil
}

func (p *epollReactorPoller) Update(fd int, id int64, events int) error {
	_ = id
	return p.epollCtl(unix.EPOLL_CTL_MOD, fd, events)
}

func (p *epollReactorPoller) Unregister(fd int) error {
	_ = unix.EpollCtl(p.epfd, unix.EPOLL_CTL_DEL, fd, nil)
	delete(p.fdToID, fd)
	return nil
}

func (p *epollReactorPoller) Wait(out []ReactorEvent, timeoutMillis int) (int, error) {
	if cap(p.scratch) < len(out) {
		p.scratch = make([]unix.EpollEvent, len(out))
	}
	events := p.scratch[:len(out)]
	n, err := unix.EpollWait(p.epfd, events, timeoutMillis)
	if err != nil {
		if err == unix.EINTR {
			return 0, nil
		}
		return -1, fmt.Errorf("epoll wait: %w", err)
	}
	count := 0
	for i := 0; i < n; i++ {
		ev := events[i]
		fd := int(ev.Fd)
		if fd == p.wakeFd {
			p.drainWake()
			out[count] = ReactorEvent{Events: ReactorEventWake}
			count++
			continue
		}
		id, ok := p.fdToID[fd]
		if !ok {
			continue
		}
		flags := int32(0)
		if ev.Events&unix.EPOLLIN != 0 {
			flags |= ReactorEventRead
		}
		if ev.Events&unix.EPOLLOUT != 0 {
			flags |= ReactorEventWrite
		}
		if ev.Events&(unix.EPOLLHUP|unix.EPOLLRDHUP) != 0 {
			flags |= ReactorEventHup
		}
		if ev.Events&unix.EPOLLERR != 0 {
			flags |= ReactorEventError
		}
		out[count] = ReactorEvent{ID: id, Events: flags}
		count++
	}
	return count, nil
}

func (p *epollReactorPoller) epollCtl(op int, fd int, events int) error {
	flags := epollInterestFlags(events)
	if err := unix.EpollCtl(p.epfd, op, fd, &unix.EpollEvent{
		Events: flags,
		Fd:     int32(fd),
	}); err != nil {
		return fmt.Errorf("epoll ctl fd %d: %w", fd, err)
	}
	return nil
}

// epollInterestFlags maps the reactor's read/write interest to an epoll event
// mask.
//
// EPOLLERR and EPOLLHUP are always reported by epoll regardless of the mask, so
// listing them is documentation, not a subscription. EPOLLRDHUP, by contrast,
// IS maskable — and is deliberately armed only alongside read interest. epoll
// is level-triggered, so a peer half-close (FIN) leaves EPOLLRDHUP asserted
// indefinitely; if it were armed while the Dart side has reads disabled (paused
// for backpressure, not yet listened, or already drained to EOF) nothing would
// consume it and epoll_wait would return immediately forever, pinning a core at
// 100% CPU. Tying EPOLLRDHUP to EPOLLIN means the half-close is delivered
// exactly when the reactor is prepared to act on it, and is silently deferred —
// not spun on — until the consumer re-enables reads (which re-arms it).
//
// (A genuine full-duplex EPOLLHUP/EPOLLERR is unmaskable and still delivered;
// that is a real terminal event, not the spurious half-close spin fixed here.)
func epollInterestFlags(events int) uint32 {
	flags := uint32(unix.EPOLLERR | unix.EPOLLHUP)
	if events&ReactorEventRead != 0 {
		flags |= unix.EPOLLIN | unix.EPOLLRDHUP
	}
	if events&ReactorEventWrite != 0 {
		flags |= unix.EPOLLOUT
	}
	return flags
}

func (p *epollReactorPoller) drainWake() {
	var buf [8]byte
	for {
		_, err := unix.Read(p.wakeFd, buf[:])
		if err == unix.EAGAIN || err == unix.EWOULDBLOCK {
			return
		}
		if err != nil {
			return
		}
	}
}
