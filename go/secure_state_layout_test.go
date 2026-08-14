//go:build android || darwin || ios || linux

package tailscale

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func encryptedLayoutForTest(t *testing.T, root string) {
	t.Helper()
	var key [encryptedStateKeySize]byte
	copy(key[:], testPreparedDEK())
	store, err := createEncryptedStateStore(
		filepath.Join(root, ownedStateSubdirectory, encryptedStateFileName),
		key,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestInspectPersistentStateLayoutAbsentIsNonCreating(t *testing.T) {
	root := t.TempDir()
	layout, err := inspectPersistentStateLayout(root)
	if err != nil || layout != PersistentStateLayoutAbsent {
		t.Fatalf("layout = %q, err = %v", layout, err)
	}
	if _, err := os.Lstat(filepath.Join(root, ownedStateSubdirectory)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("absent probe created package subtree: %v", err)
	}
}

func TestInspectPersistentStateLayoutResetMarkerWins(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, stateResetMarkerFilename), []byte("not-even-valid"), 0o644); err != nil {
		t.Fatal(err)
	}
	stateDir := filepath.Join(root, ownedStateSubdirectory)
	if err := os.Mkdir(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, "state.db"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := inspectPersistentStateLayout(root); !errors.Is(err, ErrLocalResetIncomplete) {
		t.Fatalf("error = %v, want ErrLocalResetIncomplete", err)
	}
}

func TestInspectPersistentStateLayoutRejectsLegacyConflictAndResidue(t *testing.T) {
	tests := []struct {
		name  string
		files []string
		want  error
	}{
		{name: "legacy", files: []string{"state.db"}, want: ErrLegacyStateUnsupported},
		{name: "legacy wal", files: []string{"state.db-wal"}, want: ErrLegacyStateUnsupported},
		{name: "legacy filestore", files: []string{legacyFileStoreFilename}, want: ErrLegacyStateUnsupported},
		{name: "residue", files: []string{"unknown"}, want: ErrUnexpectedStateResidue},
		{name: "empty directory", want: ErrUnexpectedStateResidue},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			stateDir := filepath.Join(root, ownedStateSubdirectory)
			if err := os.Mkdir(stateDir, 0o700); err != nil {
				t.Fatal(err)
			}
			for _, name := range test.files {
				if err := os.WriteFile(filepath.Join(stateDir, name), nil, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := inspectPersistentStateLayout(root); !errors.Is(err, test.want) {
				t.Fatalf("error = %v, want %v", err, test.want)
			}
		})
	}

	root := t.TempDir()
	encryptedLayoutForTest(t, root)
	if err := os.WriteFile(filepath.Join(root, ownedStateSubdirectory, "state.db-shm"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := inspectPersistentStateLayout(root); !errors.Is(err, ErrConflictingStateFormats) {
		t.Fatalf("conflict error = %v, want ErrConflictingStateFormats", err)
	}
}

func TestInspectPersistentStateLayoutAcceptsCanonicalEncryptedRoot(t *testing.T) {
	root := t.TempDir()
	encryptedLayoutForTest(t, root)
	if err := os.Mkdir(filepath.Join(root, ownedStateSubdirectory, "tsnet"), 0o700); err != nil {
		t.Fatal(err)
	}
	layout, err := inspectPersistentStateLayout(root)
	if err != nil || layout != PersistentStateLayoutEncrypted {
		t.Fatalf("layout = %q, err = %v", layout, err)
	}
}

func TestInspectPersistentStateLayoutRejectsNestedLegacyFileStore(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, ownedStateSubdirectory)
	tsnetDir := filepath.Join(stateDir, "tsnet")
	if err := os.MkdirAll(tsnetDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tsnetDir, legacyFileStoreFilename), []byte("legacy"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := inspectPersistentStateLayout(root); !errors.Is(err, ErrLegacyStateUnsupported) {
		t.Fatalf("error = %v, want ErrLegacyStateUnsupported", err)
	}

	encryptedLayoutForTest(t, root)
	if _, err := inspectPersistentStateLayout(root); !errors.Is(err, ErrConflictingStateFormats) {
		t.Fatalf("conflict error = %v, want ErrConflictingStateFormats", err)
	}
}

func TestInspectPersistentStateLayoutRejectsUnsafeRuntimeSidecar(t *testing.T) {
	root := t.TempDir()
	encryptedLayoutForTest(t, root)
	stateDir := filepath.Join(root, ownedStateSubdirectory)
	if err := os.Symlink(t.TempDir(), filepath.Join(stateDir, "tsnet")); err != nil {
		t.Fatal(err)
	}
	if _, err := inspectPersistentStateLayout(root); !errors.Is(err, ErrUnexpectedStateResidue) {
		t.Fatalf("error = %v, want ErrUnexpectedStateResidue", err)
	}
}

func TestInspectPersistentStateLayoutRejectsNestedRuntimeSymlink(t *testing.T) {
	root := t.TempDir()
	encryptedLayoutForTest(t, root)
	runtimeDir := filepath.Join(root, ownedStateSubdirectory, "tsnet")
	if err := os.Mkdir(runtimeDir, 0o700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(t.TempDir(), "outside")
	if err := os.WriteFile(target, []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(runtimeDir, "tailscaled.log.conf")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	if _, err := inspectPersistentStateLayout(root); !errors.Is(err, ErrUnexpectedStateResidue) {
		t.Fatalf("error = %v, want ErrUnexpectedStateResidue", err)
	}
}

func TestInspectPersistentStateLayoutRejectsMalformedEnvelopeBeforeCustody(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, ownedStateSubdirectory)
	if err := os.Mkdir(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, encryptedStateFileName), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := inspectPersistentStateLayout(root); !errors.Is(err, ErrEncryptedStateInvalidFormat) {
		t.Fatalf("error = %v, want invalid encrypted format", err)
	}
}

func TestInspectPersistentStateLayoutCleansOnlyVerifiedTempEnvelope(t *testing.T) {
	root := t.TempDir()
	encryptedLayoutForTest(t, root)
	stateDir := filepath.Join(root, ownedStateSubdirectory)
	tempPath := filepath.Join(stateDir, encryptedStateTempFileName)
	if err := os.WriteFile(tempPath, []byte("uncommitted"), 0o600); err != nil {
		t.Fatal(err)
	}
	if layout, err := inspectPersistentStateLayout(root); err != nil || layout != PersistentStateLayoutEncrypted {
		t.Fatalf("layout = %q, err = %v", layout, err)
	}
	if _, err := os.Lstat(tempPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("verified temp envelope remains: %v", err)
	}

	if err := os.WriteFile(tempPath, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(tempPath, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := inspectPersistentStateLayout(root); !errors.Is(err, ErrAtomicPersistenceFailure) {
		t.Fatalf("broad temp error = %v, want ErrAtomicPersistenceFailure", err)
	}
	if _, err := os.Lstat(tempPath); err != nil {
		t.Fatalf("unsafe temp was removed: %v", err)
	}
}

func TestInspectPersistentStateLayoutRejectsSymlinkedSubtree(t *testing.T) {
	root := t.TempDir()
	target := t.TempDir()
	if err := os.Symlink(target, filepath.Join(root, ownedStateSubdirectory)); err != nil {
		t.Fatal(err)
	}
	if _, err := inspectPersistentStateLayout(root); !errors.Is(err, ErrUnexpectedStateResidue) {
		t.Fatalf("error = %v, want ErrUnexpectedStateResidue", err)
	}
}
