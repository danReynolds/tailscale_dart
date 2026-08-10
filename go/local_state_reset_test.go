//go:build android || darwin || ios || linux

package tailscale

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"tailscale.com/tsnet"
)

func TestLocalReset_DurableMarkerPrecedesConfirmedDeletion(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	root := filepath.Dir(stateDir)
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(stateDir, encryptedStateFileName)
	if err := os.WriteFile(statePath, []byte("opaque state"), 0o600); err != nil {
		t.Fatal(err)
	}
	sibling := filepath.Join(root, "host-owned.txt")
	if err := os.WriteFile(sibling, []byte("preserve"), 0o600); err != nil {
		t.Fatal(err)
	}

	const token = 15001
	result, err := BeginLocalReset(token)
	if err != nil {
		t.Fatal(err)
	}
	if result.Token != token || result.Stopped {
		t.Fatalf("BeginLocalReset = %+v", result)
	}
	assertExactStateResetMarker(t, root)
	if _, err := os.Lstat(statePath); err != nil {
		t.Fatalf("state changed before custody confirmation: %v", err)
	}
	if _, err := acquireStateLease(root); !errors.Is(err, ErrStateLeaseBusy) {
		t.Fatalf("reset did not retain lease before finish: %v", err)
	}

	if err := FinishLocalReset(token, true); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(stateDir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("package state remains after reset: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(root, stateResetMarkerFilename)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("reset marker remains after commit: %v", err)
	}
	got, err := os.ReadFile(sibling)
	if err != nil || string(got) != "preserve" {
		t.Fatalf("host sibling = %q, %v", got, err)
	}
}

func TestLocalReset_UnconfirmedCustodyLeavesRetryableMarker(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	root := filepath.Dir(stateDir)
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(stateDir, encryptedStateFileName)
	if err := os.WriteFile(statePath, []byte("opaque state"), 0o600); err != nil {
		t.Fatal(err)
	}

	const firstToken = 15002
	if _, err := BeginLocalReset(firstToken); err != nil {
		t.Fatal(err)
	}
	if err := FinishLocalReset(firstToken, false); !errors.Is(err, ErrLocalResetIncomplete) {
		t.Fatalf("FinishLocalReset error = %v, want ErrLocalResetIncomplete", err)
	}
	assertExactStateResetMarker(t, root)
	if _, err := os.Lstat(statePath); err != nil {
		t.Fatalf("unconfirmed reset removed state: %v", err)
	}

	const retryToken = 15003
	if _, err := BeginLocalReset(retryToken); err != nil {
		t.Fatalf("retry BeginLocalReset: %v", err)
	}
	if err := FinishLocalReset(retryToken, true); err != nil {
		t.Fatalf("retry FinishLocalReset: %v", err)
	}
}

func TestLocalReset_TransfersActiveRuntimeLeaseWithoutGap(t *testing.T) {
	stateDir := configureFreshStateRootForTest(t)
	root := filepath.Dir(stateDir)
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	expectedRoot, err := os.Stat(root)
	if err != nil {
		t.Fatal(err)
	}
	lease, err := acquireStateLease(root, withExpectedStateLeaseRoot(expectedRoot))
	if err != nil {
		t.Fatal(err)
	}

	runtime := newNodeRuntime(nodeEpoch.Load(), 15004, runtimeConfig{})
	runtime.stateLease = lease
	runtime.server = &tsnet.Server{}
	runtime.closeServer = func(*tsnet.Server) error {
		other, acquireErr := acquireStateLease(root, withExpectedStateLeaseRoot(expectedRoot))
		if other != nil {
			_ = other.Release()
		}
		if !errors.Is(acquireErr, ErrStateLeaseBusy) {
			return errors.New("state lease became acquirable during runtime close")
		}
		return nil
	}
	runtime.finishPreparation()
	runtimes.mu.Lock()
	runtimes.current = runtime
	runtimes.mu.Unlock()

	const resetToken = 15005
	result, err := BeginLocalReset(resetToken)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Stopped || currentRuntime() != nil {
		t.Fatalf("active reset result = %+v, current = %v", result, currentRuntime())
	}
	if runtime.stateLease != nil {
		t.Fatal("detached runtime retained the transferred lease")
	}
	if _, err := acquireStateLease(root); !errors.Is(err, ErrStateLeaseBusy) {
		t.Fatalf("reset did not retain transferred lease: %v", err)
	}
	if err := FinishLocalReset(resetToken, true); err != nil {
		t.Fatal(err)
	}

	reacquired, err := acquireStateLease(root)
	if err != nil {
		t.Fatalf("lease unavailable after reset completion: %v", err)
	}
	if err := reacquired.Release(); err != nil {
		t.Fatal(err)
	}
}

func assertExactStateResetMarker(t *testing.T, root string) {
	t.Helper()
	path := filepath.Join(root, stateResetMarkerFilename)
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != stateResetMarkerPayload {
		t.Fatalf("reset marker = %q", contents)
	}
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		t.Fatalf("reset marker mode = %v", info.Mode())
	}
}
