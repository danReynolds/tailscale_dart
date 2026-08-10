//go:build android || darwin || ios || linux

package tailscale

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

func TestStateResetFilesystemCreatesAndVerifiesExactMarker(t *testing.T) {
	root := stateResetTestRoot(t)
	reset := openStateResetFilesystemForTest(t, root)
	defer reset.Close()

	if err := reset.ensureDurableMarker(); err != nil {
		t.Fatalf("ensure reset marker: %v", err)
	}
	assertStateResetMarker(t, root)

	before, err := os.Lstat(filepath.Join(root, stateResetMarkerFilename))
	if err != nil {
		t.Fatal(err)
	}
	if err := reset.ensureDurableMarker(); err != nil {
		t.Fatalf("verify existing reset marker: %v", err)
	}
	after, err := os.Lstat(filepath.Join(root, stateResetMarkerFilename))
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(before, after) {
		t.Fatal("valid reset marker was unexpectedly replaced")
	}
}

func TestStateResetFilesystemAtomicallyReplacesInvalidMarker(t *testing.T) {
	t.Run("malformed regular file", func(t *testing.T) {
		root := stateResetTestRoot(t)
		path := filepath.Join(root, stateResetMarkerFilename)
		if err := os.WriteFile(path, []byte("not a reset marker"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, 0o644); err != nil {
			t.Fatal(err)
		}
		before, err := os.Lstat(path)
		if err != nil {
			t.Fatal(err)
		}

		reset := openStateResetFilesystemForTest(t, root)
		defer reset.Close()
		if err := reset.ensureDurableMarker(); err != nil {
			t.Fatalf("replace malformed marker: %v", err)
		}
		after, err := os.Lstat(path)
		if err != nil {
			t.Fatal(err)
		}
		if os.SameFile(before, after) {
			t.Fatal("malformed marker inode was reused")
		}
		assertStateResetMarker(t, root)
	})

	t.Run("symlink", func(t *testing.T) {
		root := stateResetTestRoot(t)
		targetDir := t.TempDir()
		target := filepath.Join(targetDir, "outside")
		if err := os.WriteFile(target, []byte("preserve"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, filepath.Join(root, stateResetMarkerFilename)); err != nil {
			t.Fatal(err)
		}

		reset := openStateResetFilesystemForTest(t, root)
		defer reset.Close()
		if err := reset.ensureDurableMarker(); err != nil {
			t.Fatalf("replace symlink marker: %v", err)
		}
		assertStateResetMarker(t, root)
		got, err := os.ReadFile(target)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != "preserve" {
			t.Fatalf("outside symlink target changed: %q", got)
		}
	})
}

func TestStateResetFilesystemRefusesDeletionWithoutDurableMarker(t *testing.T) {
	root := stateResetTestRoot(t)
	stateFile := filepath.Join(root, ownedStateSubdirectory, "identity")
	writeStateResetTestFile(t, stateFile, "preserve")

	reset := openStateResetFilesystemForTest(t, root)
	defer reset.Close()
	if err := reset.completeAfterCustodyDeletion(); err == nil {
		t.Fatal("completion unexpectedly succeeded without a durable marker")
	}
	if got, err := os.ReadFile(stateFile); err != nil || string(got) != "preserve" {
		t.Fatalf("state changed without marker: contents=%q err=%v", got, err)
	}
}

func TestStateResetFilesystemMarkerCommitFailureDoesNotAuthorizeDeletion(t *testing.T) {
	root := stateResetTestRoot(t)
	stateFile := filepath.Join(root, ownedStateSubdirectory, "identity")
	writeStateResetTestFile(t, stateFile, "preserve")

	reset := openStateResetFilesystemForTest(t, root)
	defer reset.Close()
	rootFD := int(reset.root.Fd())
	reset.hooks.fsync = func(fd int) error {
		if fd == rootFD {
			return errors.New("injected marker-directory sync failure")
		}
		return unix.Fsync(fd)
	}
	if err := reset.ensureDurableMarker(); err == nil {
		t.Fatal("marker creation unexpectedly survived its directory sync failure")
	}
	if err := reset.completeAfterCustodyDeletion(); err == nil {
		t.Fatal("failed marker commit unexpectedly authorized state deletion")
	}
	assertStateResetFileContents(t, stateFile, "preserve")
}

func TestStateResetFilesystemMarkerDirectoryFailsClosed(t *testing.T) {
	root := stateResetTestRoot(t)
	stateFile := filepath.Join(root, ownedStateSubdirectory, "identity")
	writeStateResetTestFile(t, stateFile, "preserve")
	if err := os.Mkdir(filepath.Join(root, stateResetMarkerFilename), 0o700); err != nil {
		t.Fatal(err)
	}

	reset := openStateResetFilesystemForTest(t, root)
	defer reset.Close()
	if err := reset.ensureDurableMarker(); err == nil {
		t.Fatal("directory at marker path was unexpectedly accepted")
	}
	assertStateResetFileContents(t, stateFile, "preserve")
	info, err := os.Lstat(filepath.Join(root, stateResetMarkerFilename))
	if err != nil || !info.IsDir() {
		t.Fatalf("marker directory changed: info=%v err=%v", info, err)
	}
}

func TestStateResetFilesystemDeletesOnlyOwnedSubtreeWithoutFollowingSymlinks(t *testing.T) {
	root := stateResetTestRoot(t)
	outside := t.TempDir()
	outsideFile := filepath.Join(outside, "outside-secret")
	writeStateResetTestFile(t, outsideFile, "preserve")

	stateDir := filepath.Join(root, ownedStateSubdirectory)
	writeStateResetTestFile(t, filepath.Join(stateDir, "tsnet", "logs", "log.txt"), "delete")
	writeStateResetTestFile(t, filepath.Join(stateDir, "tailscaled.state.enc"), "delete")
	if err := os.Symlink(outside, filepath.Join(stateDir, "tsnet", "outside-link")); err != nil {
		t.Fatal(err)
	}
	sibling := filepath.Join(root, "host-owned")
	writeStateResetTestFile(t, sibling, "preserve")
	lock := filepath.Join(root, stateLeaseFilename)
	writeStateResetTestFile(t, lock, "preserve")

	reset := openStateResetFilesystemForTest(t, root)
	defer reset.Close()
	if err := reset.ensureDurableMarker(); err != nil {
		t.Fatalf("ensure reset marker: %v", err)
	}
	if err := reset.completeAfterCustodyDeletion(); err != nil {
		t.Fatalf("complete reset: %v", err)
	}

	assertStateResetPathAbsent(t, filepath.Join(root, ownedStateSubdirectory))
	assertStateResetPathAbsent(t, filepath.Join(root, stateResetMarkerFilename))
	assertStateResetFileContents(t, outsideFile, "preserve")
	assertStateResetFileContents(t, sibling, "preserve")
	assertStateResetFileContents(t, lock, "preserve")
}

func TestStateResetFilesystemSafelyUnlinksTerminalSymlink(t *testing.T) {
	root := stateResetTestRoot(t)
	outside := t.TempDir()
	outsideFile := filepath.Join(outside, "identity")
	writeStateResetTestFile(t, outsideFile, "preserve")
	if err := os.Symlink(outside, filepath.Join(root, ownedStateSubdirectory)); err != nil {
		t.Fatal(err)
	}

	reset := openStateResetFilesystemForTest(t, root)
	defer reset.Close()
	if err := reset.ensureDurableMarker(); err != nil {
		t.Fatalf("ensure reset marker: %v", err)
	}
	if err := reset.completeAfterCustodyDeletion(); err != nil {
		t.Fatalf("complete reset: %v", err)
	}

	assertStateResetPathAbsent(t, filepath.Join(root, ownedStateSubdirectory))
	assertStateResetFileContents(t, outsideFile, "preserve")
}

func TestStateResetFilesystemFailureLeavesMarkerAndRetryCompletes(t *testing.T) {
	root := stateResetTestRoot(t)
	writeStateResetTestFile(t, filepath.Join(root, ownedStateSubdirectory, "a", "delete-first"), "delete")
	writeStateResetTestFile(t, filepath.Join(root, ownedStateSubdirectory, "b", "stop"), "delete")
	fault := errors.New("injected unlink failure")
	failed := false
	hooks := defaultStateResetFSHooks()
	hooks.unlinkat = func(parent int, name string, flags int) error {
		if name == "stop" && !failed {
			failed = true
			return fault
		}
		return unix.Unlinkat(parent, name, flags)
	}

	reset := openStateResetFilesystemForTest(t, root, withStateResetFSHooksForTest(hooks))
	defer reset.Close()
	if err := reset.ensureDurableMarker(); err != nil {
		t.Fatalf("ensure reset marker: %v", err)
	}
	err := reset.completeAfterCustodyDeletion()
	if !errors.Is(err, ErrLocalResetIncomplete) || !errors.Is(err, fault) {
		t.Fatalf("completion error = %v, want localResetIncomplete plus injected fault", err)
	}
	assertStateResetMarker(t, root)
	if err := reset.Close(); err != nil {
		t.Fatal(err)
	}

	retry := openStateResetFilesystemForTest(t, root)
	defer retry.Close()
	if err := retry.ensureDurableMarker(); err != nil {
		t.Fatalf("verify retry marker: %v", err)
	}
	if err := retry.completeAfterCustodyDeletion(); err != nil {
		t.Fatalf("retry reset: %v", err)
	}
	assertStateResetPathAbsent(t, filepath.Join(root, ownedStateSubdirectory))
	assertStateResetPathAbsent(t, filepath.Join(root, stateResetMarkerFilename))
}

func TestStateResetFilesystemSyncBoundariesKeepOrRestoreMarker(t *testing.T) {
	tests := []struct {
		name     string
		failSync int
	}{
		{name: "subtree deletion sync", failSync: 1},
		{name: "marker removal sync", failSync: 2},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := stateResetTestRoot(t)
			writeStateResetTestFile(t, filepath.Join(root, ownedStateSubdirectory, "state"), "delete")
			reset := openStateResetFilesystemForTest(t, root)
			if err := reset.ensureDurableMarker(); err != nil {
				t.Fatalf("ensure reset marker: %v", err)
			}

			rootFD := int(reset.root.Fd())
			rootSyncs := 0
			reset.hooks.fsync = func(fd int) error {
				if fd == rootFD {
					rootSyncs++
					if rootSyncs == test.failSync {
						return errors.New("injected root sync failure")
					}
				}
				return unix.Fsync(fd)
			}
			err := reset.completeAfterCustodyDeletion()
			if !errors.Is(err, ErrLocalResetIncomplete) {
				t.Fatalf("completion error = %v, want localResetIncomplete", err)
			}
			assertStateResetMarker(t, root)
			if err := reset.Close(); err != nil {
				t.Fatal(err)
			}

			retry := openStateResetFilesystemForTest(t, root)
			defer retry.Close()
			if err := retry.ensureDurableMarker(); err != nil {
				t.Fatalf("verify retry marker: %v", err)
			}
			if err := retry.completeAfterCustodyDeletion(); err != nil {
				t.Fatalf("retry reset: %v", err)
			}
			assertStateResetPathAbsent(t, filepath.Join(root, ownedStateSubdirectory))
			assertStateResetPathAbsent(t, filepath.Join(root, stateResetMarkerFilename))
		})
	}
}

func TestStateResetFilesystemMarkerRemovalFailureIsRetryable(t *testing.T) {
	root := stateResetTestRoot(t)
	writeStateResetTestFile(t, filepath.Join(root, ownedStateSubdirectory, "state"), "delete")
	fault := errors.New("injected marker unlink failure")
	hooks := defaultStateResetFSHooks()
	hooks.unlinkat = func(parent int, name string, flags int) error {
		if name == stateResetMarkerFilename {
			return fault
		}
		return unix.Unlinkat(parent, name, flags)
	}
	reset := openStateResetFilesystemForTest(t, root, withStateResetFSHooksForTest(hooks))
	defer reset.Close()
	if err := reset.ensureDurableMarker(); err != nil {
		t.Fatalf("ensure reset marker: %v", err)
	}
	err := reset.completeAfterCustodyDeletion()
	if !errors.Is(err, ErrLocalResetIncomplete) || !errors.Is(err, fault) {
		t.Fatalf("completion error = %v, want localResetIncomplete plus injected fault", err)
	}
	assertStateResetMarker(t, root)
	assertStateResetPathAbsent(t, filepath.Join(root, ownedStateSubdirectory))
}

func TestStateResetFilesystemRejectsReplacedConfiguredRoot(t *testing.T) {
	container := t.TempDir()
	root := filepath.Join(container, "state-root")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	reset := openStateResetFilesystemForTest(t, root)
	defer reset.Close()
	moved := filepath.Join(container, "moved-root")
	if err := os.Rename(root, moved); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}

	if err := reset.ensureDurableMarker(); err == nil {
		t.Fatal("marker creation unexpectedly accepted a replaced configured root")
	}
	assertStateResetPathAbsent(t, filepath.Join(root, stateResetMarkerFilename))
	assertStateResetPathAbsent(t, filepath.Join(moved, stateResetMarkerFilename))
}

func stateResetTestRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	return root
}

func openStateResetFilesystemForTest(t *testing.T, root string, options ...stateResetFSOption) *stateResetFilesystem {
	t.Helper()
	rootInfo, err := os.Lstat(root)
	if err != nil {
		t.Fatal(err)
	}
	reset, err := openStateResetFilesystem(root, rootInfo, options...)
	if err != nil {
		t.Fatalf("open reset filesystem: %v", err)
	}
	return reset
}

func writeStateResetTestFile(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
}

func assertStateResetMarker(t *testing.T, root string) {
	t.Helper()
	path := filepath.Join(root, stateResetMarkerFilename)
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatalf("stat reset marker: %v", err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		t.Fatalf("reset marker mode = %v, want regular 0600", info.Mode())
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != stateResetMarkerPayload {
		t.Fatalf("reset marker = %q, want %q", contents, stateResetMarkerPayload)
	}
}

func assertStateResetPathAbsent(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("path %q still exists: %v", path, err)
	}
}

func assertStateResetFileContents(t *testing.T, path, want string) {
	t.Helper()
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != want {
		t.Fatalf("file %q = %q, want %q", path, got, want)
	}
}
