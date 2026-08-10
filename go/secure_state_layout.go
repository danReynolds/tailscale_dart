package tailscale

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

const stateResetMarkerFilename = ".tailscale-state.reset"

var (
	// ErrLocalResetIncomplete means an explicit local-forget transaction has
	// durable intent on disk and must be resumed explicitly before any other
	// persistent operation.
	ErrLocalResetIncomplete = errors.New("local Tailscale state reset is incomplete")

	// ErrUnexpectedStateResidue means the package-owned subtree exists without
	// one recognized StateStore layout. Starting empty would risk replacing an
	// identity whose files are only partially present.
	ErrUnexpectedStateResidue = errors.New("unexpected Tailscale state residue")

	// ErrLegacyStateUnsupported means a pre-launch plaintext SQLite or FileStore
	// layout is present.
	// R4d deliberately requires explicit local forget instead of migration.
	ErrLegacyStateUnsupported = errors.New("legacy plaintext SQLite or FileStore Tailscale state is unsupported")

	// ErrConflictingStateFormats means encrypted and legacy artifacts coexist.
	ErrConflictingStateFormats = errors.New("conflicting Tailscale state formats")

	// ErrAtomicPersistenceFailure means recovery could not prove or durably
	// clean the one recognized pre-rename encrypted-envelope residue.
	ErrAtomicPersistenceFailure = errors.New("atomic Tailscale state persistence failed")

	// Export stable classifications for the strict encrypted-envelope parser.
	ErrEncryptedStateInvalidFormat  = errEncryptedStateInvalidFormat
	ErrEncryptedStateUnsupported    = errEncryptedStateUnsupported
	ErrEncryptedStateOversized      = errEncryptedStateOversized
	ErrEncryptedStatePathSecurity   = errEncryptedStatePathSecurity
	ErrEncryptedStateAuthentication = errEncryptedStateAuthentication
)

// PersistentStateLayout is the keyless result returned while the persistent
// state lease is held. Only these two layouts are allowed to reach Keybay.
type PersistentStateLayout string

const (
	PersistentStateLayoutAbsent    PersistentStateLayout = "absent"
	PersistentStateLayoutEncrypted PersistentStateLayout = "encrypted"
)

var legacyStateFilenames = [...]string{"state.db", "state.db-wal", "state.db-shm"}

const legacyFileStoreFilename = "tailscaled.state"

// inspectPersistentStateLayout enforces the keyless half of the R4d matrix.
// It may remove only the exact, verified pre-rename temp envelope. It never
// creates the package subtree, opens legacy state, or accesses Keybay.
func inspectPersistentStateLayout(baseRoot string) (PersistentStateLayout, error) {
	markerPath := filepath.Join(baseRoot, stateResetMarkerFilename)
	if _, err := os.Lstat(markerPath); err == nil {
		return "", fmt.Errorf("%w: marker %q is present", ErrLocalResetIncomplete, markerPath)
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", fmt.Errorf("%w: inspect reset marker: %v", ErrLocalResetIncomplete, err)
	}

	stateDir := filepath.Join(baseRoot, ownedStateSubdirectory)
	info, err := os.Lstat(stateDir)
	if errors.Is(err, os.ErrNotExist) {
		return PersistentStateLayoutAbsent, nil
	}
	if err != nil {
		return "", fmt.Errorf("%w: inspect package subtree: %v", ErrUnexpectedStateResidue, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return "", fmt.Errorf("%w: package subtree is not a real directory", ErrUnexpectedStateResidue)
	}
	if err := secureEncryptedStateDirectory(stateDir, false); err != nil {
		return "", fmt.Errorf("%w: secure package subtree: %v", ErrUnexpectedStateResidue, err)
	}

	entries, err := os.ReadDir(stateDir)
	if err != nil {
		return "", fmt.Errorf("%w: list package subtree: %v", ErrUnexpectedStateResidue, err)
	}
	if err := removeVerifiedEncryptedStateTemp(stateDir, entries); err != nil {
		return "", err
	}
	if hasDirectoryEntry(entries, encryptedStateTempFileName) {
		entries, err = os.ReadDir(stateDir)
		if err != nil {
			return "", fmt.Errorf("%w: relist package subtree: %v", ErrUnexpectedStateResidue, err)
		}
	}

	var encrypted, legacy, unexpected bool
	for _, entry := range entries {
		switch entry.Name() {
		case encryptedStateFileName:
			encrypted = true
		case legacyStateFilenames[0], legacyStateFilenames[1], legacyStateFilenames[2]:
			legacy = true
		case legacyFileStoreFilename:
			legacy = true
		case "tsnet":
			// The runtime-owned sidecar directory is valid only alongside the
			// encrypted StateStore. Without it, the subtree is residual state.
		default:
			unexpected = true
		}
	}
	if hasDirectoryEntry(entries, "tsnet") {
		tsnetDir := filepath.Join(stateDir, "tsnet")
		if err := secureEncryptedStateDirectory(tsnetDir, false); err != nil {
			return "", fmt.Errorf("%w: secure runtime sidecar directory: %v", ErrUnexpectedStateResidue, err)
		}
		if _, err := os.Lstat(filepath.Join(tsnetDir, legacyFileStoreFilename)); err == nil {
			legacy = true
		} else if !errors.Is(err, os.ErrNotExist) {
			return "", fmt.Errorf("%w: inspect legacy runtime state: %v", ErrUnexpectedStateResidue, err)
		}
	}

	if encrypted && legacy {
		return "", ErrConflictingStateFormats
	}
	if legacy {
		return "", ErrLegacyStateUnsupported
	}
	if !encrypted {
		return "", ErrUnexpectedStateResidue
	}
	if unexpected {
		return "", ErrUnexpectedStateResidue
	}
	if err := inspectEncryptedStateEnvelopeFile(filepath.Join(stateDir, encryptedStateFileName)); err != nil {
		return "", err
	}
	return PersistentStateLayoutEncrypted, nil
}

func hasDirectoryEntry(entries []os.DirEntry, name string) bool {
	for _, entry := range entries {
		if entry.Name() == name {
			return true
		}
	}
	return false
}

func removeVerifiedEncryptedStateTemp(stateDir string, entries []os.DirEntry) error {
	if !hasDirectoryEntry(entries, encryptedStateTempFileName) {
		return nil
	}
	path := filepath.Join(stateDir, encryptedStateTempFileName)
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("%w: inspect temporary envelope: %v", ErrAtomicPersistenceFailure, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("%w: temporary envelope is not a regular file", ErrAtomicPersistenceFailure)
	}
	if err := verifyCurrentUserOwns(info); err != nil {
		return fmt.Errorf("%w: verify temporary envelope owner: %v", ErrAtomicPersistenceFailure, err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		return fmt.Errorf("%w: temporary envelope permissions are %04o, want 0600", ErrAtomicPersistenceFailure, got)
	}
	if err := os.Remove(path); err != nil {
		return fmt.Errorf("%w: remove temporary envelope: %v", ErrAtomicPersistenceFailure, err)
	}
	if err := syncStateDirectory(stateDir); err != nil {
		return fmt.Errorf("%w: sync temporary-envelope removal: %v", ErrAtomicPersistenceFailure, err)
	}
	return nil
}
