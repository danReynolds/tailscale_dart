//go:build android || darwin || ios || linux

package tailscale

import (
	"os"
	"syscall"
	"testing"
)

type ownerTestFileInfo struct {
	os.FileInfo
	stat *syscall.Stat_t
}

func (info ownerTestFileInfo) Sys() any { return info.stat }

func TestVerifyCurrentUserOwns(t *testing.T) {
	path := t.TempDir()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := verifyCurrentUserOwns(info); err != nil {
		t.Fatalf("current-user ownership rejected: %v", err)
	}
	wrongOwner := &syscall.Stat_t{Uid: uint32(os.Geteuid()) + 1}
	if err := verifyCurrentUserOwns(ownerTestFileInfo{FileInfo: info, stat: wrongOwner}); err == nil {
		t.Fatal("different-user ownership was accepted")
	}
}
