package tailscale

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestValidateEphemeralPersistentOccupancyAllowsAbsentAndEmpty(t *testing.T) {
	root := t.TempDir()
	if err := validateEphemeralPersistentOccupancy(root); err != nil {
		t.Fatalf("absent package subtree: %v", err)
	}

	stateDir := filepath.Join(root, ownedStateSubdirectory)
	if err := os.Mkdir(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := validateEphemeralPersistentOccupancy(root); err != nil {
		t.Fatalf("empty package subtree: %v", err)
	}
}

func TestValidateEphemeralPersistentOccupancyRejectsResetAndResidue(t *testing.T) {
	t.Run("reset marker takes precedence", func(t *testing.T) {
		root := t.TempDir()
		stateDir := filepath.Join(root, ownedStateSubdirectory)
		if err := os.Mkdir(stateDir, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(stateDir, encryptedStateFileName), []byte("opaque"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, stateResetMarkerFilename), nil, 0o600); err != nil {
			t.Fatal(err)
		}
		err := validateEphemeralPersistentOccupancy(root)
		if !errors.Is(err, ErrLocalResetIncomplete) {
			t.Fatalf("error = %v, want ErrLocalResetIncomplete", err)
		}
	})

	t.Run("any directory entry is occupied", func(t *testing.T) {
		root := t.TempDir()
		stateDir := filepath.Join(root, ownedStateSubdirectory)
		if err := os.Mkdir(stateDir, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(stateDir, "unrecognized-residue"), nil, 0o600); err != nil {
			t.Fatal(err)
		}
		err := validateEphemeralPersistentOccupancy(root)
		if !errors.Is(err, ErrEphemeralPersistentStateOccupied) {
			t.Fatalf("error = %v, want ErrEphemeralPersistentStateOccupied", err)
		}
	})

	t.Run("symlinked package subtree", func(t *testing.T) {
		root := t.TempDir()
		target := t.TempDir()
		if err := os.Symlink(target, filepath.Join(root, ownedStateSubdirectory)); err != nil {
			t.Fatal(err)
		}
		err := validateEphemeralPersistentOccupancy(root)
		if !errors.Is(err, ErrEphemeralPersistentStateOccupied) {
			t.Fatalf("error = %v, want ErrEphemeralPersistentStateOccupied", err)
		}
	})
}

func TestCreateEphemeralStateScratchOwnsLiveLeaseAndCleansBeforeUnlock(t *testing.T) {
	parent := t.TempDir()
	scratch, err := createEphemeralStateScratchIn(parent)
	if err != nil {
		t.Fatalf("create scratch: %v", err)
	}
	path := scratch.directory()
	if filepath.Dir(path) != parent || !strings.HasPrefix(filepath.Base(path), ephemeralStateScratchPrefix) {
		t.Fatalf("scratch path %q is outside %q or lacks prefix %q", path, parent, ephemeralStateScratchPrefix)
	}
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !info.IsDir() || info.Mode().Perm() != 0o700 {
		t.Fatalf("scratch mode = %v, want directory 0700", info.Mode())
	}
	if err := verifyCurrentUserOwns(info); err != nil {
		t.Fatalf("scratch owner: %v", err)
	}

	contender, err := acquireStateLease(path)
	if contender != nil {
		_ = contender.Release()
		t.Fatal("second live lease unexpectedly succeeded")
	}
	if !errors.Is(err, ErrStateLeaseBusy) {
		t.Fatalf("second live lease error = %v, want ErrStateLeaseBusy", err)
	}

	removedBeforeUnlock := false
	originalUnlock := scratch.lease.options.unlock
	scratch.lease.options.unlock = func(fd int) error {
		_, statErr := os.Lstat(path)
		removedBeforeUnlock = errors.Is(statErr, os.ErrNotExist)
		return originalUnlock(fd)
	}
	if err := scratch.Close(); err != nil {
		t.Fatalf("close scratch: %v", err)
	}
	if !removedBeforeUnlock {
		t.Fatal("scratch directory was not removed before its live lease unlocked")
	}
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("scratch still exists after close: %v", err)
	}
	if err := scratch.Close(); err != nil {
		t.Fatalf("idempotent close: %v", err)
	}
}

func TestEphemeralStateScratchCloseRefusesReplacement(t *testing.T) {
	parent := t.TempDir()
	scratch, err := createEphemeralStateScratchIn(parent)
	if err != nil {
		t.Fatalf("create scratch: %v", err)
	}
	path := scratch.directory()
	moved := path + "-original"
	if err := os.Rename(path, moved); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	sentinel := filepath.Join(path, "do-not-delete")
	if err := os.WriteFile(sentinel, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(path)
		_ = os.RemoveAll(moved)
	})

	if err := scratch.Close(); err == nil || !strings.Contains(err.Error(), "path was replaced") {
		t.Fatalf("Close error = %v, want replacement refusal", err)
	}
	if _, err := os.Lstat(sentinel); err != nil {
		t.Fatalf("replacement was touched: %v", err)
	}
}

func TestSweepStaleEphemeralStateScratchUsesAgeOwnershipModeAndLiveLease(t *testing.T) {
	parent := t.TempDir()
	now := time.Now().Truncate(time.Second)
	minimumAge := 2 * time.Hour
	old := now.Add(-3 * time.Hour)

	makeDirectory := func(name string, mode os.FileMode, modified time.Time) string {
		t.Helper()
		path := filepath.Join(parent, name)
		if err := os.Mkdir(path, mode); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(path, "runtime.log"), []byte("residue"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, mode); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(path, modified, modified); err != nil {
			t.Fatal(err)
		}
		return path
	}

	stale := makeDirectory(ephemeralStateScratchPrefix+"stale", 0o700, old)
	young := makeDirectory(ephemeralStateScratchPrefix+"young", 0o700, now)
	broad := makeDirectory(ephemeralStateScratchPrefix+"broad", 0o755, old)
	unprefixed := makeDirectory("unrelated-ephemeral", 0o700, old)
	exactPrefix := makeDirectory(ephemeralStateScratchPrefix, 0o700, old)

	live := makeDirectory(ephemeralStateScratchPrefix+"live", 0o700, old)
	liveInfo, err := os.Lstat(live)
	if err != nil {
		t.Fatal(err)
	}
	liveLease, err := acquireStateLease(live, withExpectedStateLeaseRoot(liveInfo))
	if err != nil {
		t.Fatalf("acquire live candidate lease: %v", err)
	}
	t.Cleanup(func() { _ = liveLease.Release() })
	// Creating the lock updates the directory mtime; restore the old timestamp
	// so the nonblocking lock, not age, is what protects this candidate.
	if err := os.Chtimes(live, old, old); err != nil {
		t.Fatal(err)
	}

	target := t.TempDir()
	symlink := filepath.Join(parent, ephemeralStateScratchPrefix+"symlink")
	if err := os.Symlink(target, symlink); err != nil {
		t.Fatal(err)
	}

	removed, err := sweepStaleEphemeralStateScratchIn(parent, now, minimumAge)
	if err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if removed != 1 {
		t.Fatalf("removed = %d, want 1", removed)
	}
	if _, err := os.Lstat(stale); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("eligible stale scratch remains: %v", err)
	}
	for name, path := range map[string]string{
		"young":        young,
		"broad":        broad,
		"unprefixed":   unprefixed,
		"exact prefix": exactPrefix,
		"live":         live,
		"symlink":      symlink,
	} {
		if _, err := os.Lstat(path); err != nil {
			t.Errorf("%s candidate was removed: %v", name, err)
		}
	}
	if _, err := os.Lstat(target); err != nil {
		t.Fatalf("symlink target was touched: %v", err)
	}
}

func TestEphemeralScratchParentPrefersConfiguredValue(t *testing.T) {
	runtimes.mu.Lock()
	previous := runtimes.scratchParent
	runtimes.mu.Unlock()
	t.Cleanup(func() {
		runtimes.mu.Lock()
		runtimes.scratchParent = previous
		runtimes.mu.Unlock()
	})
	runtimes.mu.Lock()
	runtimes.scratchParent = ""
	runtimes.mu.Unlock()

	if got := ephemeralScratchParent(); got != os.TempDir() {
		t.Fatalf("unconfigured parent = %q, want os.TempDir() %q", got, os.TempDir())
	}
	SetEphemeralScratchParent("   ")
	if got := ephemeralScratchParent(); got != os.TempDir() {
		t.Fatalf("blank parent must be ignored; got %q", got)
	}

	configured := t.TempDir()
	SetEphemeralScratchParent(configured)
	if got := ephemeralScratchParent(); got != configured {
		t.Fatalf("configured parent = %q, want %q", got, configured)
	}
	SetEphemeralScratchParent(t.TempDir())
	if got := ephemeralScratchParent(); got != configured {
		t.Fatalf("scratch parent must be set-once; got %q, want %q", got, configured)
	}

	scratch, err := createEphemeralStateScratch()
	if err != nil {
		t.Fatalf("createEphemeralStateScratch: %v", err)
	}
	t.Cleanup(func() { _ = scratch.Close() })
	if dir := scratch.directory(); !strings.HasPrefix(dir, configured+string(os.PathSeparator)) {
		t.Fatalf("scratch %q must live under the configured parent %q", dir, configured)
	}
}
