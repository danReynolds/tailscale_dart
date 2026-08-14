//go:build android || darwin || ios || linux

package tailscale

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestSecureRuntimeSidecarTreeTightensPrivateModes(t *testing.T) {
	root := filepath.Join(t.TempDir(), "tsnet")
	nested := filepath.Join(root, "certs")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, 0o755); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(nested, "node.crt")
	if err := os.WriteFile(file, []byte("public certificate"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := secureRuntimeSidecarTree(root); err != nil {
		t.Fatalf("secureRuntimeSidecarTree: %v", err)
	}
	for _, dir := range []string{root, nested} {
		info, err := os.Stat(dir)
		if err != nil {
			t.Fatal(err)
		}
		if got := info.Mode().Perm(); got != 0o700 {
			t.Fatalf("directory %q permissions = %04o, want 0700", dir, got)
		}
	}
	info, err := os.Stat(file)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("file permissions = %04o, want 0600", got)
	}
}

func TestSecureRuntimeSidecarTreeRejectsSymlinkWithoutTouchingTarget(t *testing.T) {
	root := filepath.Join(t.TempDir(), "tsnet")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(t.TempDir(), "outside")
	if err := os.WriteFile(target, []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(root, "tailscaled.log.conf")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	err := secureRuntimeSidecarTree(root)
	if !errors.Is(err, ErrUnexpectedStateResidue) {
		t.Fatalf("error = %v, want ErrUnexpectedStateResidue", err)
	}
	contents, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != "keep" {
		t.Fatalf("symlink target contents = %q, want untouched", contents)
	}
	info, err := os.Stat(target)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o644 {
		t.Fatalf("symlink target permissions = %04o, want untouched 0644", got)
	}
}

func TestSecureRuntimeSidecarTreeRejectsNonRegularFile(t *testing.T) {
	root := filepath.Join(t.TempDir(), "tsnet")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", filepath.Join(root, "unexpected.sock"))
	if err != nil {
		t.Skipf("Unix sockets unavailable: %v", err)
	}
	defer listener.Close()

	if err := secureRuntimeSidecarTree(root); !errors.Is(err, ErrUnexpectedStateResidue) {
		t.Fatalf("error = %v, want ErrUnexpectedStateResidue", err)
	}
}
