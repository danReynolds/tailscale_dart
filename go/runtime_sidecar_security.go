package tailscale

import (
	"fmt"
	"os"
	"path/filepath"
)

// secureRuntimeSidecarTree verifies the filesystem objects that upstream tsnet
// may read or write beneath Server.Dir. It deliberately does not allowlist
// names: upstream may add sidecars, but every descendant must remain a real,
// current-user-owned directory or regular file with private permissions.
func secureRuntimeSidecarTree(root string) error {
	return filepath.WalkDir(root, func(path string, entry os.DirEntry, walkErr error) error {
		relative, relErr := filepath.Rel(root, path)
		if relErr != nil {
			return fmt.Errorf("%w: resolve runtime sidecar path: %v", ErrUnexpectedStateResidue, relErr)
		}
		if walkErr != nil {
			return fmt.Errorf("%w: inspect runtime sidecar %q: %v", ErrUnexpectedStateResidue, relative, walkErr)
		}

		info, err := os.Lstat(path)
		if err != nil {
			return fmt.Errorf("%w: inspect runtime sidecar %q: %v", ErrUnexpectedStateResidue, relative, err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("%w: runtime sidecar %q is a symbolic link", ErrUnexpectedStateResidue, relative)
		}
		switch {
		case info.IsDir():
			if err := secureEncryptedStateDirectory(path, false); err != nil {
				return fmt.Errorf("%w: secure runtime sidecar directory %q: %v", ErrUnexpectedStateResidue, relative, err)
			}
		case info.Mode().IsRegular():
			if err := secureRuntimeSidecarFile(path); err != nil {
				return fmt.Errorf("%w: secure runtime sidecar file %q: %v", ErrUnexpectedStateResidue, relative, err)
			}
		default:
			return fmt.Errorf("%w: runtime sidecar %q is not a directory or regular file", ErrUnexpectedStateResidue, relative)
		}
		return nil
	})
}

func secureRuntimeSidecarFile(path string) error {
	before, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if before.Mode()&os.ModeSymlink != 0 || !before.Mode().IsRegular() {
		return fmt.Errorf("path is not a real regular file")
	}
	if err := verifyCurrentUserOwns(before); err != nil {
		return err
	}

	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return err
	}
	current, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if current.Mode()&os.ModeSymlink != 0 || !current.Mode().IsRegular() ||
		!os.SameFile(before, opened) || !os.SameFile(opened, current) {
		return fmt.Errorf("file identity changed while securing it")
	}
	if err := verifyCurrentUserOwns(opened); err != nil {
		return err
	}
	if err := file.Chmod(0o600); err != nil {
		return err
	}
	final, err := file.Stat()
	if err != nil {
		return err
	}
	current, err = os.Lstat(path)
	if err != nil {
		return err
	}
	if current.Mode()&os.ModeSymlink != 0 || !current.Mode().IsRegular() ||
		!os.SameFile(opened, final) || !os.SameFile(final, current) {
		return fmt.Errorf("file identity changed while securing it")
	}
	if err := verifyCurrentUserOwns(final); err != nil {
		return err
	}
	if got := final.Mode().Perm(); got != 0o600 {
		return fmt.Errorf("permissions are %04o, want 0600", got)
	}
	return nil
}
