package tailscale

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"tailscale.com/envknob"
)

func TestRawDiscoCompatibilityUpdatesUpstreamKnob(t *testing.T) {
	previous, hadPrevious := os.LookupEnv(rawDiscoEnv)
	knob := envknob.RegisterBool(rawDiscoEnv)
	t.Cleanup(func() {
		if hadPrevious {
			envknob.Setenv(rawDiscoEnv, previous)
			return
		}
		envknob.Setenv(rawDiscoEnv, "")
		_ = os.Unsetenv(rawDiscoEnv)
	})

	envknob.Setenv(rawDiscoEnv, "")
	if knob() {
		t.Fatal("upstream's registered raw-disco knob is enabled while absent")
	}
	envknob.Setenv(rawDiscoEnv, "true")
	if !knob() {
		t.Fatal("test setup did not enable upstream's registered raw-disco knob")
	}
	setRawDiscoCompatibility()
	if knob() {
		t.Fatal("compatibility setting did not disable upstream's registered raw-disco knob")
	}
}

// This source contract intentionally fails on an upstream implementation
// change: removing the process-global compatibility pin requires confirming
// that the pinned Tailscale version still gates raw sockets behind an opt-in.
func TestUpstreamRawDiscoRemainsOptIn(t *testing.T) {
	cmd := exec.Command("go", "list", "-m", "-f={{.Dir}}", "tailscale.com")
	moduleDir, err := cmd.Output()
	if err != nil {
		t.Fatalf("locate upstream Tailscale module: %v", err)
	}
	source, err := os.ReadFile(filepath.Join(
		strings.TrimSpace(string(moduleDir)),
		"wgengine",
		"magicsock",
		"magicsock_linux.go",
	))
	if err != nil {
		t.Fatalf("read upstream raw-disco implementation: %v", err)
	}
	compact := strings.Join(strings.Fields(string(source)), " ")
	if !strings.Contains(
		compact,
		`envknobEnableRawDisco = envknob.RegisterBool("TS_ENABLE_RAW_DISCO")`,
	) {
		t.Fatal("upstream no longer registers raw disco as the expected boolean opt-in")
	}

	methodAt := strings.Index(compact, "func (c *Conn) listenRawDisco")
	if methodAt < 0 {
		t.Fatal("upstream listenRawDisco implementation not found")
	}
	method := compact[methodAt:]
	guardAt := strings.Index(method, "if !envknobEnableRawDisco()")
	socketAt := strings.Index(method, "socket.Socket(")
	unsupportedAt := strings.Index(method, "errors.ErrUnsupported")
	if guardAt < 0 ||
		socketAt < 0 ||
		unsupportedAt < guardAt ||
		unsupportedAt > socketAt ||
		guardAt > socketAt {
		t.Fatal("upstream raw-socket creation is no longer preceded by the expected opt-in guard")
	}
}
