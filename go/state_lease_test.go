//go:build android || darwin || ios || linux

package tailscale

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"testing"

	"golang.org/x/sys/unix"
)

func TestStateLeaseCreatesStablePrivateFile(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	lease, err := acquireStateLease(root)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, stateLeaseFilename)
	before, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !before.Mode().IsRegular() {
		t.Fatalf("lease mode = %v, want regular file", before.Mode())
	}
	if got := before.Mode().Perm(); got != 0o600 {
		t.Fatalf("lease permissions = %04o, want 0600", got)
	}
	if err := verifyCurrentUserOwns(before); err != nil {
		t.Fatalf("lease ownership: %v", err)
	}
	if err := lease.Release(); err != nil {
		t.Fatal(err)
	}

	lease, err = acquireStateLease(root)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Release()
	after, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(before, after) {
		t.Fatal("release/reacquire replaced the stable lease inode")
	}
}

func TestStateLeaseProcessAdmissionUsesRootInode(t *testing.T) {
	root := t.TempDir()
	lease, err := acquireStateLease(root)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Release()

	lexicalAlias := filepath.Join(root, "child", "..")
	if err := os.Mkdir(filepath.Join(root, "child"), 0o700); err != nil {
		t.Fatal(err)
	}
	assertStateLeaseBusy(t, lexicalAlias)

	symlinkAlias := filepath.Join(t.TempDir(), "state-alias")
	if err := os.Symlink(root, symlinkAlias); err != nil {
		t.Fatal(err)
	}
	assertStateLeaseBusy(t, symlinkAlias)
}

func TestStateLeaseRejectsRootDifferentFromFrozenIdentity(t *testing.T) {
	expectedRoot := t.TempDir()
	expected, err := os.Stat(expectedRoot)
	if err != nil {
		t.Fatal(err)
	}
	replacementRoot := t.TempDir()
	if _, err := acquireStateLease(
		replacementRoot,
		withExpectedStateLeaseRoot(expected),
	); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("replacement root error = %v, want ErrConfigurationMismatch", err)
	}
	if _, err := os.Lstat(filepath.Join(replacementRoot, stateLeaseFilename)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("identity mismatch created lock infrastructure: %v", err)
	}
}

func TestStateLeasePinsRootAndRejectsReplacementDuringLease(t *testing.T) {
	container := t.TempDir()
	root := filepath.Join(container, "state")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	lease, err := acquireStateLease(root)
	if err != nil {
		t.Fatal(err)
	}

	moved := filepath.Join(container, "state-original")
	if err := os.Rename(root, moved); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	clearStateLeaseAdmissionAfterTest(t, moved)

	if _, err := lease.root.Stat(); err != nil {
		t.Fatalf("pinned root descriptor was closed during lease: %v", err)
	}
	if err := lease.validatePaths(); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("replacement validation error = %v, want ErrConfigurationMismatch", err)
	}
	if err := lease.Release(); !errors.Is(err, ErrConfigurationMismatch) {
		t.Fatalf("Release error = %v, want replacement mismatch", err)
	}
	if _, err := lease.root.Stat(); err == nil {
		t.Fatal("Release left the pinned root descriptor open")
	}
	if _, err := os.Lstat(filepath.Join(root, stateLeaseFilename)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("replacement root gained lease infrastructure: %v", err)
	}
}

func TestStateLeaseRejectsReplacedLockPathDuringLease(t *testing.T) {
	root := t.TempDir()
	clearStateLeaseAdmissionAfterTest(t, root)
	lease, err := acquireStateLease(root)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, stateLeaseFilename)
	if err := os.Rename(path, path+".original"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}

	if err := lease.validatePaths(); err == nil {
		t.Fatal("replacement lock path passed lease validation")
	}
	if err := lease.Release(); err == nil {
		t.Fatal("Release did not surface the replaced lock path")
	}
}

func TestStateLeaseNonblockingAcrossProcesses(t *testing.T) {
	root := t.TempDir()
	command := exec.Command(os.Args[0], "-test.run=^TestStateLeaseExternalHelper$")
	command.Env = append(os.Environ(),
		"TAILSCALE_STATE_LEASE_HELPER=1",
		"TAILSCALE_STATE_LEASE_ROOT="+root,
	)
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdin, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	command.Stderr = &stderr
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = stdin.Close()
		if err := command.Wait(); err != nil {
			t.Fatalf("lease helper: %v: %s", err, stderr.String())
		}
	}()

	scanner := bufio.NewScanner(stdout)
	if !scanner.Scan() || scanner.Text() != "locked" {
		t.Fatalf("lease helper did not lock: line=%q err=%v stderr=%s", scanner.Text(), scanner.Err(), stderr.String())
	}
	assertStateLeaseBusy(t, root)
}

func TestStateLeaseProcessCrashReleasesOSLock(t *testing.T) {
	root := t.TempDir()
	command := exec.Command(os.Args[0], "-test.run=^TestStateLeaseExternalHelper$")
	command.Env = append(os.Environ(),
		"TAILSCALE_STATE_LEASE_HELPER=1",
		"TAILSCALE_STATE_LEASE_ROOT="+root,
	)
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdin, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	command.Stderr = &stderr
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = stdin.Close()
		_ = command.Process.Kill()
	}()

	scanner := bufio.NewScanner(stdout)
	if !scanner.Scan() || scanner.Text() != "locked" {
		t.Fatalf("lease helper did not lock: line=%q err=%v stderr=%s", scanner.Text(), scanner.Err(), stderr.String())
	}
	if err := command.Process.Kill(); err != nil {
		t.Fatalf("kill lease helper: %v", err)
	}
	if err := command.Wait(); err == nil {
		t.Fatal("killed lease helper exited successfully")
	}

	lease, err := acquireStateLease(root)
	if err != nil {
		t.Fatalf("reacquire after process crash: %v (stderr=%s)", err, stderr.String())
	}
	if err := lease.Release(); err != nil {
		t.Fatal(err)
	}
}

func TestStateLeaseExternalHelper(t *testing.T) {
	if os.Getenv("TAILSCALE_STATE_LEASE_HELPER") != "1" {
		return
	}
	lease, err := acquireStateLease(os.Getenv("TAILSCALE_STATE_LEASE_ROOT"))
	if err != nil {
		t.Fatal(err)
	}
	fmt.Fprintln(os.Stdout, "locked")
	_, _ = bufio.NewReader(os.Stdin).ReadByte()
	if err := lease.Release(); err != nil {
		t.Fatal(err)
	}
}

func TestStateLeaseRejectsNonRegularLockPath(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, stateLeaseFilename), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := acquireStateLease(root); err == nil {
		t.Fatal("directory at lease path was accepted")
	}
}

func TestStateLeaseRejectsSymlinkLockPath(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(t.TempDir(), "outside")
	if err := os.WriteFile(target, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(root, stateLeaseFilename)); err != nil {
		t.Fatal(err)
	}
	if _, err := acquireStateLease(root); err == nil {
		t.Fatal("symlink at lease path was accepted")
	}
}

func TestStateLeaseTightensExistingPermissions(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, stateLeaseFilename)
	if err := os.WriteFile(path, nil, 0o666); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o666); err != nil {
		t.Fatal(err)
	}
	lease, err := acquireStateLease(root)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Release()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("lease permissions = %04o, want 0600", got)
	}
}

func TestStateLeaseLockFailureReleasesAdmission(t *testing.T) {
	root := t.TempDir()
	injected := errors.New("lock failed")
	_, err := acquireStateLease(root, withStateLeaseTestHooks(stateLeaseTestHooks{
		lock: func(int) error { return injected },
	}))
	if !errors.Is(err, injected) {
		t.Fatalf("acquire error = %v, want injected lock error", err)
	}
	lease, err := acquireStateLease(root)
	if err != nil {
		t.Fatalf("clean lock failure retained admission: %v", err)
	}
	if err := lease.Release(); err != nil {
		t.Fatal(err)
	}
}

func TestStateLeaseInjectedWouldBlockIsTypedBusy(t *testing.T) {
	root := t.TempDir()
	_, err := acquireStateLease(root, withStateLeaseTestHooks(stateLeaseTestHooks{
		lock: func(int) error { return unix.EWOULDBLOCK },
	}))
	if !errors.Is(err, ErrStateLeaseBusy) {
		t.Fatalf("acquire error = %v, want ErrStateLeaseBusy", err)
	}
}

func TestStateLeaseReleaseIsConcurrentAndIdempotent(t *testing.T) {
	root := t.TempDir()
	var hookMu sync.Mutex
	unlockCalls := 0
	closeCalls := 0
	lease, err := acquireStateLease(root, withStateLeaseTestHooks(stateLeaseTestHooks{
		unlock: func(fd int) error {
			hookMu.Lock()
			unlockCalls++
			hookMu.Unlock()
			return unix.Flock(fd, unix.LOCK_UN)
		},
		close: func(file *os.File) error {
			hookMu.Lock()
			closeCalls++
			hookMu.Unlock()
			return file.Close()
		},
	}))
	if err != nil {
		t.Fatal(err)
	}

	const callers = 16
	var wait sync.WaitGroup
	wait.Add(callers)
	for range callers {
		go func() {
			defer wait.Done()
			if err := lease.Release(); err != nil {
				t.Errorf("Release: %v", err)
			}
		}()
	}
	wait.Wait()
	hookMu.Lock()
	defer hookMu.Unlock()
	if unlockCalls != 1 || closeCalls != 1 {
		t.Fatalf("cleanup calls = unlock %d, close %d; want 1 each", unlockCalls, closeCalls)
	}
}

func TestStateLeaseReleaseClosesLockBeforeRootAndJoinsErrors(t *testing.T) {
	root := t.TempDir()
	clearStateLeaseAdmissionAfterTest(t, root)
	lockCloseFailure := errors.New("lock close failed")
	rootCloseFailure := errors.New("root close failed")
	var events []string
	lease, err := acquireStateLease(root, withStateLeaseTestHooks(stateLeaseTestHooks{
		close: func(file *os.File) error {
			events = append(events, "lock")
			return errors.Join(file.Close(), lockCloseFailure)
		},
		closeRoot: func(file *os.File) error {
			events = append(events, "root")
			return errors.Join(file.Close(), rootCloseFailure)
		},
	}))
	if err != nil {
		t.Fatal(err)
	}
	if err := lease.Release(); !errors.Is(err, lockCloseFailure) || !errors.Is(err, rootCloseFailure) {
		t.Fatalf("Release error = %v, want both close failures", err)
	}
	if got, want := fmt.Sprint(events), "[lock root]"; got != want {
		t.Fatalf("close order = %s, want %s", got, want)
	}
}

func TestStateLeaseUnlockFailurePoisonsAdmission(t *testing.T) {
	root := t.TempDir()
	clearStateLeaseAdmissionAfterTest(t, root)
	injected := errors.New("unlock failed")
	lease, err := acquireStateLease(root, withStateLeaseTestHooks(stateLeaseTestHooks{
		unlock: func(fd int) error {
			if err := unix.Flock(fd, unix.LOCK_UN); err != nil {
				return err
			}
			return injected
		},
	}))
	if err != nil {
		t.Fatal(err)
	}
	if err := lease.Release(); !errors.Is(err, injected) {
		t.Fatalf("Release error = %v, want injected unlock error", err)
	}
	assertStateLeasePoisoned(t, root)
}

func TestStateLeaseCloseFailurePoisonsAdmission(t *testing.T) {
	root := t.TempDir()
	clearStateLeaseAdmissionAfterTest(t, root)
	injected := errors.New("close failed")
	lease, err := acquireStateLease(root, withStateLeaseTestHooks(stateLeaseTestHooks{
		close: func(file *os.File) error {
			if err := file.Close(); err != nil {
				return err
			}
			return injected
		},
	}))
	if err != nil {
		t.Fatal(err)
	}
	if err := lease.Release(); !errors.Is(err, injected) {
		t.Fatalf("Release error = %v, want injected close error", err)
	}
	assertStateLeasePoisoned(t, root)
}

func TestStateLeaseAcquisitionCloseFailurePoisonsAdmission(t *testing.T) {
	root := t.TempDir()
	clearStateLeaseAdmissionAfterTest(t, root)
	lockFailure := errors.New("lock failed")
	closeFailure := errors.New("close failed")
	_, err := acquireStateLease(root, withStateLeaseTestHooks(stateLeaseTestHooks{
		lock: func(int) error { return lockFailure },
		close: func(file *os.File) error {
			if err := file.Close(); err != nil {
				return err
			}
			return closeFailure
		},
	}))
	if !errors.Is(err, lockFailure) || !errors.Is(err, closeFailure) {
		t.Fatalf("acquire error = %v, want lock and close failures", err)
	}
	if !errors.Is(err, ErrRuntimeCleanupFailed) {
		t.Fatalf("acquire error = %v, want ErrRuntimeCleanupFailed", err)
	}
	assertStateLeasePoisoned(t, root)
}

func assertStateLeaseBusy(t *testing.T, root string) {
	t.Helper()
	_, err := acquireStateLease(root)
	if !errors.Is(err, ErrStateLeaseBusy) {
		t.Fatalf("acquireStateLease(%q) error = %v, want ErrStateLeaseBusy", root, err)
	}
}

func assertStateLeasePoisoned(t *testing.T, root string) {
	t.Helper()
	_, err := acquireStateLease(root)
	if !errors.Is(err, errStateLeasePoisoned) {
		t.Fatalf("acquireStateLease(%q) error = %v, want poisoned admission", root, err)
	}
}

// Poison is intentionally process-lifetime state in production. Tests that
// inject cleanup uncertainty must remove only their own admission afterward;
// otherwise a deleted TempDir inode can be reused by a later Linux test and
// make that unrelated root appear poisoned.
func clearStateLeaseAdmissionAfterTest(t *testing.T, root string) {
	t.Helper()
	info, err := os.Stat(root)
	if err != nil {
		t.Fatal(err)
	}
	rootID, err := stateLeaseIdentity(info)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		stateLeaseAdmissions.Lock()
		delete(stateLeaseAdmissions.byRoot, rootID)
		stateLeaseAdmissions.Unlock()
	})
}

func TestStateLeaseIdentityUsesDeviceAndInode(t *testing.T) {
	info, err := os.Stat(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	id, err := stateLeaseIdentity(info)
	if err != nil {
		t.Fatal(err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		t.Fatal("stat metadata unavailable")
	}
	if id.device != uint64(stat.Dev) || id.inode != uint64(stat.Ino) {
		t.Fatalf("identity = %+v, want device=%d inode=%d", id, stat.Dev, stat.Ino)
	}
}
