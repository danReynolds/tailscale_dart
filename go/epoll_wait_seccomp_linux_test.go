//go:build linux && amd64

package tailscale

import (
	"os"
	"runtime"
	"testing"
	"unsafe"

	"golang.org/x/sys/unix"
)

// TestReactorSurvivesEpollWaitDenial is the regression guard for issue #81.
//
// Android's seccomp filter denies the legacy epoll_wait syscall for app
// processes. The denial is SECCOMP_RET_TRAP, so the process dies with SIGSYS
// on the reactor's first poll. x/sys v0.47.0 avoids the denied syscall by
// mapping unix.EpollWait to SYS_EPOLL_PWAIT on Linux and Android.
//
// This test reproduces Android's policy on an ordinary linux/amd64 runner by
// installing the same denial as a seccomp-bpf filter, but with
// SECCOMP_RET_ERRNO instead of SECCOMP_RET_TRAP so a regression is an
// assertable error rather than a dead test binary. If the reactor or its x/sys
// dependency ever returns to issuing epoll_wait, Wait returns EPERM here;
// issuing epoll_pwait passes.
//
// The test is amd64-only because SYS_EPOLL_WAIT does not exist on arm64 and
// GitHub's ubuntu-latest runners are amd64.
func TestReactorSurvivesEpollWaitDenial(t *testing.T) {
	// The filter is installed on this thread and cannot be removed, so pin the
	// goroutine to it and never unlock. The Go runtime destroys a locked thread
	// when its goroutine exits, so the filtered thread is not recycled into the
	// pool. Threads cloned from it inherit the filter, which is harmless because
	// the runtime's own netpoller already uses epoll_pwait.
	runtime.LockOSThread()

	if err := denyEpollWait(); err != nil {
		if os.Getenv("CI") != "" {
			t.Fatalf("CI cannot install the seccomp regression filter: %v", err)
		}
		t.Skipf("cannot install seccomp filter (needs CONFIG_SECCOMP_FILTER and an unrestricted container): %v", err)
	}

	p, err := newReactorPoller()
	if err != nil {
		t.Fatalf("newReactorPoller after epoll_wait denial: %v", err)
	}
	defer func() { _ = p.Close() }()

	// A short timeout with nothing registered must expire with zero events.
	// Reaching epoll_wait instead is rejected by the filter and surfaces EPERM.
	out := make([]ReactorEvent, 8)
	n, err := p.Wait(out, 20)
	if err != nil {
		if err == unix.EPERM {
			t.Fatalf("reactor issued denied epoll_wait; keep x/sys at v0.47.0 or newer")
		}
		t.Fatalf("Wait under epoll_wait denial: %v", err)
	}
	if n != 0 {
		t.Fatalf("Wait returned %d events, want 0 (nothing was registered)", n)
	}

	// Wake rides the same poller and must survive the filter too.
	if err := p.Wake(); err != nil {
		t.Fatalf("Wake under epoll_wait denial: %v", err)
	}
	if _, err := p.Wait(out, 20); err != nil {
		t.Fatalf("Wait after Wake under epoll_wait denial: %v", err)
	}
}

// denyEpollWait installs a seccomp-bpf filter on the calling thread that fails
// SYS_EPOLL_WAIT with EPERM and allows everything else.
//
// The classic-BPF program is four instructions over struct seccomp_data, whose
// first field (nr, the syscall number) is at offset 0:
//
//	ld  [0]                   ; seccomp_data.nr
//	jeq SYS_EPOLL_WAIT, 0, 1  ; fall through on match, else skip one
//	ret SECCOMP_RET_ERRNO|EPERM
//	ret SECCOMP_RET_ALLOW
//
// No architecture guard is needed: this file is amd64-only, so the syscall
// numbering is fixed. PR_SET_NO_NEW_PRIVS is a prerequisite for
// PR_SET_SECCOMP without CAP_SYS_ADMIN.
func denyEpollWait() error {
	const (
		bpfLdAbsW = 0x20 // BPF_LD | BPF_W | BPF_ABS
		bpfJeqK   = 0x15 // BPF_JMP | BPF_JEQ | BPF_K
		bpfRetK   = 0x06 // BPF_RET | BPF_K
	)
	filter := []unix.SockFilter{
		{Code: bpfLdAbsW, K: 0},
		{Code: bpfJeqK, Jt: 0, Jf: 1, K: uint32(unix.SYS_EPOLL_WAIT)},
		{Code: bpfRetK, K: uint32(unix.SECCOMP_RET_ERRNO | uint32(unix.EPERM))},
		{Code: bpfRetK, K: uint32(unix.SECCOMP_RET_ALLOW)},
	}
	prog := unix.SockFprog{
		Len:    uint16(len(filter)),
		Filter: &filter[0],
	}
	if err := unix.Prctl(unix.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0); err != nil {
		return err
	}
	return unix.Prctl(
		unix.PR_SET_SECCOMP,
		uintptr(unix.SECCOMP_MODE_FILTER),
		uintptr(unsafe.Pointer(&prog)),
		0, 0,
	)
}
