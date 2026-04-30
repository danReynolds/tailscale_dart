//go:build !windows && darwin

package tailscale

import (
	"fmt"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// EVFILT_USER ident reserved for the self-wake. EVFILT_USER lives in a
// distinct ident namespace from EVFILT_READ/EVFILT_WRITE (which key off fds),
// so this value cannot collide with a real transport.
const reactorWakeIdent = 1

// kqueueReactorPoller multiplexes one shard's fds via kqueue on macOS/iOS.
//
// Wake-up uses EVFILT_USER + NOTE_TRIGGER (no fd burned). Transport ids ride
// in the kevent's Udata field, which is pointer-width and accepts the full
// int64 round-trip without the side-table the Linux poller needs.
type kqueueReactorPoller struct {
	kq     int
	closed bool
}

func newReactorPoller() (reactorPoller, error) {
	kq, err := unix.Kqueue()
	if err != nil {
		return nil, fmt.Errorf("kqueue: %w", err)
	}
	p := &kqueueReactorPoller{kq: kq}
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
	return p.Update(fd, id, events)
}

func (p *kqueueReactorPoller) Update(fd int, id int64, events int) error {
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
		Udata:  (*byte)(unsafePointerFromInt64(id)),
	})
	changes = append(changes, unix.Kevent_t{
		Ident:  uint64(fd),
		Filter: unix.EVFILT_WRITE,
		Flags:  writeFlags,
		Udata:  (*byte)(unsafePointerFromInt64(id)),
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
	return nil
}

func (p *kqueueReactorPoller) Wait(out []ReactorEvent, timeoutMillis int) (int, error) {
	events := make([]unix.Kevent_t, len(out))
	timeout := reactorTimeout(timeoutMillis)
	n, err := unix.Kevent(p.kq, nil, events, timeout)
	if err != nil {
		if err == unix.EINTR {
			return 0, nil
		}
		return -1, fmt.Errorf("kqueue wait: %w", err)
	}
	for i := 0; i < n; i++ {
		ev := events[i]
		if ev.Filter == unix.EVFILT_USER && ev.Ident == reactorWakeIdent {
			out[i] = ReactorEvent{Events: ReactorEventWake}
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
		out[i] = ReactorEvent{
			ID:     int64FromUnsafePointer(unsafe.Pointer(ev.Udata)),
			Events: flags,
			Errno:  int32(ev.Data),
		}
	}
	return n, nil
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
