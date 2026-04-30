//go:build !windows

// Native side of the shared POSIX fd reactor. Each Dart "shard" gets one
// reactorHandle that wraps a platform-specific reactorPoller (kqueue on
// Darwin, epoll on Linux/Android). The Dart isolate owns the lifecycle and
// drives Wait/Wake; this file is a thin, lock-protected registry that exposes
// the poller through the cgo Dune* exports in cmd/dylib.
//
// The flag values and the ReactorEvent struct layout are part of the FFI
// contract — keep them in sync with `lib/src/fd_transport.dart` and the
// matching C typedef in `cmd/dylib/main.go`.

package tailscale

import (
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"unsafe"
)

const (
	ReactorEventRead  = 1 << 0
	ReactorEventWrite = 1 << 1
	ReactorEventHup   = 1 << 2
	ReactorEventError = 1 << 3
	ReactorEventWake  = 1 << 4
)

// ReactorEvent is the dispatch record handed back to the Dart side per
// readiness notification. Layout must match `_NativeReactorEvent` in
// `lib/src/fd_transport.dart` and `DuneReactorEvent` in `cmd/dylib/main.go`.
type ReactorEvent struct {
	ID     int64
	Events int32
	Errno  int32
}

// reactorPoller is the platform abstraction over kqueue/epoll. Implementations
// are not safe for concurrent use; the Dart-owned reactor isolate is the only
// caller, with Wake() being the one exception (used to break a blocked Wait
// when commands arrive on the isolate's command port).
type reactorPoller interface {
	Close() error
	Wake() error
	Register(fd int, id int64, events int) error
	Update(fd int, id int64, events int) error
	Unregister(fd int) error
	Wait(events []ReactorEvent, timeoutMillis int) (int, error)
}

type reactorHandle struct {
	poller reactorPoller
}

var (
	reactorID       int64
	reactorRegistry = map[int64]*reactorHandle{}
	reactorMu       sync.Mutex
)

func ReactorCreate() (int64, error) {
	poller, err := newReactorPoller()
	if err != nil {
		return -1, err
	}
	id := atomic.AddInt64(&reactorID, 1)
	reactorMu.Lock()
	reactorRegistry[id] = &reactorHandle{poller: poller}
	reactorMu.Unlock()
	return id, nil
}

func ReactorClose(id int64) error {
	handle := removeReactor(id)
	if handle == nil {
		return nil
	}
	return handle.poller.Close()
}

func ReactorWake(id int64) error {
	handle := getReactor(id)
	if handle == nil {
		return fmt.Errorf("reactor %d not found", id)
	}
	return handle.poller.Wake()
}

func ReactorRegister(id int64, fd int, transportID int64, events int) error {
	handle := getReactor(id)
	if handle == nil {
		return fmt.Errorf("reactor %d not found", id)
	}
	if err := setReactorNonblock(fd); err != nil {
		return err
	}
	return handle.poller.Register(fd, transportID, events)
}

func ReactorUpdate(id int64, fd int, transportID int64, events int) error {
	handle := getReactor(id)
	if handle == nil {
		return fmt.Errorf("reactor %d not found", id)
	}
	return handle.poller.Update(fd, transportID, events)
}

func ReactorUnregister(id int64, fd int) error {
	handle := getReactor(id)
	if handle == nil {
		return nil
	}
	return handle.poller.Unregister(fd)
}

func ReactorWait(id int64, out unsafe.Pointer, maxEvents int, timeoutMillis int) (int, error) {
	handle := getReactor(id)
	if handle == nil {
		return -1, fmt.Errorf("reactor %d not found", id)
	}
	if out == nil {
		return -1, errors.New("reactor wait output pointer is nil")
	}
	if maxEvents <= 0 {
		return -1, errors.New("reactor wait maxEvents must be positive")
	}

	events := unsafe.Slice((*ReactorEvent)(out), maxEvents)
	return handle.poller.Wait(events, timeoutMillis)
}

func getReactor(id int64) *reactorHandle {
	reactorMu.Lock()
	defer reactorMu.Unlock()
	return reactorRegistry[id]
}

func removeReactor(id int64) *reactorHandle {
	reactorMu.Lock()
	defer reactorMu.Unlock()
	handle := reactorRegistry[id]
	delete(reactorRegistry, id)
	return handle
}
