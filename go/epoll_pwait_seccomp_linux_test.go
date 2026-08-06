//go:build linux && amd64

package tailscale

import (
	"runtime"
	"testing"
	"unsafe"

	"golang.org/x/sys/unix"
)

// TestReactorSurvivesEpollWaitDenial is the regression guard for issue #81.
//
// Android's seccomp filter denies the legacy epoll_wait syscall for app
// processes, and a denial is SECCOMP_RET_TRAP: SIGSYS, and the process dies on
// the reactor's first poll. The bug was invisible to every tool we run —
// unix.EpollWait is perfectly well-typed, so no compiler, vet pass, or test on
// a Linux host (where epoll_wait is permitted) can notice it, and CI executes
// no Android at all.
//
// This reproduces Android's policy on an ordinary linux/amd64 runner by
// installing the same denial as a seccomp-bpf filter, but with
// SECCOMP_RET_ERRNO instead of SECCOMP_RET_TRAP so a regression is an
// assertable error rather than a dead test binary. If the reactor ever goes
// back to issuing epoll_wait, Wait returns EPERM here and this fails; issuing
// epoll_pwait (which Android permits, and which x/sys already used on arm64)
// passes.
//
// amd64-only by build tag: SYS_EPOLL_WAIT does not exist on arm64, and CI runs
// ubuntu-latest/amd64.
func TestReactorSurvivesEpollWaitDenial(t *testing.T) {
	// The filter is installed on this thread and cannot be removed, so pin the
	// goroutine to it and never unlock: the Go runtime destroys a locked thread
	// when its goroutine exits, so the poisoned thread dies with the test
	// rather than being recycled into the pool. Threads cloned from it inherit
	// the filter, which is harmless — the runtime's own netpoller already uses
	// epoll_pwait.
	runtime.LockOSThread()

	if err := denyEpollWait(); err != nil {
		t.Skipf("cannot install seccomp filter (needs a kernel with CONFIG_SECCOMP_FILTER and an unrestricted container): %v", err)
	}

	p, err := newReactorPoller()
	if err != nil {
		t.Fatalf("newReactorPoller after epoll_wait denial: %v", err)
	}
	defer func() { _ = p.Close() }()

	// A short timeout with nothing registered: epoll_pwait blocks, expires and
	// reports zero events. Reaching epoll_wait instead traps the filter and
	// comes back EPERM, which Wait surfaces as an error.
	out := make([]ReactorEvent, 8)
	n, err := p.Wait(out, 20)
	if err != nil {
		if err == unix.EPERM {
			t.Fatalf("reactor issued the denied epoll_wait syscall — issue #81 has regressed; see epoll_pwait_linux.go")
		}
		t.Fatalf("Wait under epoll_wait denial: %v", err)
	}
	if n != 0 {
		t.Fatalf("Wait returned %d events, want 0 (nothing was registered)", n)
	}

	// Wake must survive too: it rides the same poller, and a regression that
	// reintroduced epoll_wait on the wake path would otherwise go unseen.
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
// No arch guard is needed: this file is amd64-only, so seccomp_data.arch is
// always AUDIT_ARCH_X86_64 and the syscall numbering is fixed.
//
// PR_SET_NO_NEW_PRIVS is a prerequisite for PR_SET_SECCOMP without CAP_SYS_ADMIN.
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
