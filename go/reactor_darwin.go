//go:build !windows && darwin

package tailscale

import (
	"fmt"
	"time"

	"golang.org/x/sys/unix"
)

// EVFILT_USER ident reserved for the self-wake. EVFILT_USER lives in a
// distinct ident namespace from EVFILT_READ/EVFILT_WRITE (which key off fds),
// so this value cannot collide with a real transport.
const reactorWakeIdent = 1

// kqueueReactorPoller multiplexes one shard's fds via kqueue on macOS/iOS.
//
// Wake-up uses EVFILT_USER + NOTE_TRIGGER (no fd burned). Transport ids live
// in the fdToID side-table and are recovered on dispatch via the fd reported
// in the kevent's Ident — the same scheme the Linux poller uses. (Udata could
// carry the id inline, but stuffing an int64 through unsafe.Pointer trips
// vet's unsafeptr check; the side-table costs one map lookup per readiness
// event and keeps the package unsafe-free so CI can gate on a clean vet.)
// Like the Linux poller's, the map is unsynchronized: the owning shard
// serializes all poller calls.
type kqueueReactorPoller struct {
	kq      int
	fdToID  map[int]int64
	closed  bool
	scratch []unix.Kevent_t // reused across Wait calls to avoid per-poll alloc
}

func newReactorPoller() (reactorPoller, error) {
	kq, err := unix.Kqueue()
	if err != nil {
		return nil, fmt.Errorf("kqueue: %w", err)
	}
	p := &kqueueReactorPoller{kq: kq, fdToID: map[int]int64{}}
	wake := unix.Kevent_t{
		Ident:  reactorWakeIdent,
		Filter: unix.EVFILT_USER,
		Flags:  unix.EV_ADD | unix.EV_CLEAR,
	}
	if _, err := unix.Kevent(kq, []unix.Kevent_t{wake}, nil, nil); err != nil {
		_ = unix.Close(kq)
		return nil, fmt.Errorf("kqueue wake register: %w", err)
	}
	return p, nil
}

func setReactorNonblock(fd int) error {
	if err := unix.SetNonblock(fd, true); err != nil {
		return fmt.Errorf("set nonblock fd %d: %w", fd, err)
	}
	return nil
}

func (p *kqueueReactorPoller) Close() error {
	if p.closed {
		return nil
	}
	p.closed = true
	return unix.Close(p.kq)
}

func (p *kqueueReactorPoller) Wake() error {
	change := unix.Kevent_t{
		Ident:  reactorWakeIdent,
		Filter: unix.EVFILT_USER,
		Fflags: unix.NOTE_TRIGGER,
	}
	if _, err := unix.Kevent(p.kq, []unix.Kevent_t{change}, nil, nil); err != nil {
		return fmt.Errorf("kqueue wake trigger: %w", err)
	}
	return nil
}

func (p *kqueueReactorPoller) Register(fd int, id int64, events int) error {
	if err := p.applyInterest(fd, events); err != nil {
		return err
	}
	p.fdToID[fd] = id
	return nil
}

func (p *kqueueReactorPoller) Update(fd int, id int64, events int) error {
	_ = id // ids are immutable per registration; recovered via fdToID
	return p.applyInterest(fd, events)
}

func (p *kqueueReactorPoller) applyInterest(fd int, events int) error {
	changes := make([]unix.Kevent_t, 0, 2)
	readFlags := uint16(unix.EV_ADD)
	writeFlags := uint16(unix.EV_ADD)
	if events&ReactorEventRead != 0 {
		readFlags |= unix.EV_ENABLE
	} else {
		readFlags |= unix.EV_DISABLE
	}
	if events&ReactorEventWrite != 0 {
		writeFlags |= unix.EV_ENABLE
	} else {
		writeFlags |= unix.EV_DISABLE
	}
	changes = append(changes, unix.Kevent_t{
		Ident:  uint64(fd),
		Filter: unix.EVFILT_READ,
		Flags:  readFlags,
	})
	changes = append(changes, unix.Kevent_t{
		Ident:  uint64(fd),
		Filter: unix.EVFILT_WRITE,
		Flags:  writeFlags,
	})
	if _, err := unix.Kevent(p.kq, changes, nil, nil); err != nil {
		return fmt.Errorf("kqueue update fd %d: %w", fd, err)
	}
	return nil
}

func (p *kqueueReactorPoller) Unregister(fd int) error {
	changes := []unix.Kevent_t{
		{Ident: uint64(fd), Filter: unix.EVFILT_READ, Flags: unix.EV_DELETE},
		{Ident: uint64(fd), Filter: unix.EVFILT_WRITE, Flags: unix.EV_DELETE},
	}
	_, _ = unix.Kevent(p.kq, changes, nil, nil)
	delete(p.fdToID, fd)
	return nil
}

func (p *kqueueReactorPoller) Wait(out []ReactorEvent, timeoutMillis int) (int, error) {
	if cap(p.scratch) < len(out) {
		p.scratch = make([]unix.Kevent_t, len(out))
	}
	events := p.scratch[:len(out)]
	timeout := reactorTimeout(timeoutMillis)
	n, err := unix.Kevent(p.kq, nil, events, timeout)
	if err != nil {
		if err == unix.EINTR {
			return 0, nil
		}
		return -1, fmt.Errorf("kqueue wait: %w", err)
	}
	count := 0
	for i := 0; i < n; i++ {
		ev := events[i]
		if ev.Filter == unix.EVFILT_USER && ev.Ident == reactorWakeIdent {
			out[count] = ReactorEvent{Events: ReactorEventWake}
			count++
			continue
		}
		// Recover the transport id from the side-table; drop events for fds
		// already unregistered (a stale kevent racing Unregister), mirroring
		// the Linux poller.
		id, ok := p.fdToID[int(ev.Ident)]
		if !ok {
			continue
		}
		flags := int32(0)
		switch ev.Filter {
		case unix.EVFILT_READ:
			flags |= ReactorEventRead
		case unix.EVFILT_WRITE:
			flags |= ReactorEventWrite
		}
		if ev.Flags&unix.EV_EOF != 0 {
			flags |= ReactorEventHup
		}
		if ev.Flags&unix.EV_ERROR != 0 {
			flags |= ReactorEventError
		}
		out[count] = ReactorEvent{
			ID:     id,
			Events: flags,
			Errno:  int32(ev.Data),
		}
		count++
	}
	return count, nil
}

func reactorTimeout(timeoutMillis int) *unix.Timespec {
	if timeoutMillis < 0 {
		return nil
	}
	if timeoutMillis == 0 {
		return &unix.Timespec{}
	}
	return &unix.Timespec{
		Sec:  int64(timeoutMillis) / 1000,
		Nsec: (int64(timeoutMillis) % 1000) * int64(time.Millisecond),
	}
}
