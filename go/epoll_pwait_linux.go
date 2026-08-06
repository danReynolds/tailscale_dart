//go:build !windows && (linux || android)

package tailscale

import (
	"unsafe"

	"golang.org/x/sys/unix"
)

// zeroEpollEvent backs the events pointer when Wait is handed a zero-length
// buffer, since &events[0] would panic on an empty slice. Unreachable in
// practice — ReactorWait rejects maxEvents <= 0 before Wait is entered
// (reactor.go:147) — but epoll_pwait is passed a real address either way, which
// is the same shape x/sys (its package-level _zero) and the Go runtime use.
var zeroEpollEvent unix.EpollEvent

// epollPwait is epoll_pwait(2) with a nil signal mask, which is semantically
// identical to epoll_wait(2) but — unlike epoll_wait — is reachable from an
// Android app process.
//
// Android installs a seccomp-bpf filter on every zygote-spawned process. bionic
// never issues epoll_wait itself (its epoll_wait() is a C wrapper over
// epoll_pwait), so on Android x86_64 the legacy call is denied, and a denied
// syscall is SECCOMP_RET_TRAP: SIGSYS, tombstone, process death on the reactor
// isolate's very first poll, before Flutter renders a frame. That is issue #81.
//
// x/sys routes unix.EpollWait to the legacy syscall number on every arch that
// has one (amd64 232, 386 256, arm 252); only arm64, whose syscall table never
// had epoll_wait at all, is redirected to epoll_pwait
// (golang.org/x/sys@v0.46.0/unix/syscall_linux_arm64.go:11) — which is why real
// arm64-v8a devices were unaffected and this went unnoticed. v0.46.0 exports no
// EpollPwait wrapper for Linux (only z/OS), hence the hand-rolled trap.
// SYS_EPOLL_PWAIT is defined for every Linux GOARCH, so this needs no arch
// split, and it is the same call the Go runtime's own netpoller makes.
//
// Syscall6, NOT RawSyscall6: this call blocks — the reactor passes msec = -1
// whenever a transport is registered (lib/src/posix_reactor.dart). Only
// Syscall6 brackets the trap with runtime.entersyscall/exitsyscall, moving the
// P to _Psyscall so the scheduler can hand it to another M and sysmon can
// retake it. RawSyscall6 pins the P for the whole unbounded wait; measured, it
// starves the scheduler and degrades into a silent EINTR spin. x/sys reserves
// the Raw variants for //sysnb (non-blocking) declarations for exactly this
// reason.
//
// Args 5 and 6 are the sigmask pointer and its size. A nil mask means "leave
// the thread's signal mask alone", which is precisely epoll_wait's behavior;
// the kernel reads sigsetsize only when the mask is non-nil, so 0 is correct
// (and is what both x/sys and the runtime pass).
func epollPwait(epfd int, events []unix.EpollEvent, msec int) (int, error) {
	buf := unsafe.Pointer(&zeroEpollEvent)
	if len(events) > 0 {
		buf = unsafe.Pointer(&events[0])
	}
	n, _, errno := unix.Syscall6(
		unix.SYS_EPOLL_PWAIT,
		uintptr(epfd),
		uintptr(buf),
		uintptr(len(events)),
		uintptr(msec),
		0, // sigmask == nil
		0, // sigsetsize, ignored when sigmask is nil
	)
	if errno != 0 {
		// Returned bare rather than wrapped, so Wait's `err == unix.EINTR`
		// identity check keeps matching exactly as it did with unix.EpollWait.
		return -1, errno
	}
	return int(n), nil
}
