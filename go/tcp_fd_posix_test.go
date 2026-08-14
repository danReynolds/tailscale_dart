//go:build !windows

package tailscale

import (
	"crypto/tls"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
	"tailscale.com/tsnet"
)

type readyTLSListenServerStub struct {
	domains []string
	ln      net.Listener
	err     error
	calls   int
	network string
	addr    string
}

func (s *readyTLSListenServerStub) CertDomains() []string { return s.domains }

func (s *readyTLSListenServerStub) Listen(network, addr string) (net.Listener, error) {
	s.calls++
	s.network = network
	s.addr = addr
	return s.ln, s.err
}

func TestNewSocketPairConn_PipesBytesBothWays(t *testing.T) {
	dartFd, goConn, err := newSocketPairConn()
	if err != nil {
		t.Fatalf("newSocketPairConn: %v", err)
	}
	defer unix.Close(dartFd)
	defer goConn.Close()

	if _, err := goConn.Write([]byte("from-go")); err != nil {
		t.Fatalf("go write: %v", err)
	}
	got := make([]byte, len("from-go"))
	if _, err := unix.Read(dartFd, got); err != nil {
		t.Fatalf("fd read: %v", err)
	}
	if string(got) != "from-go" {
		t.Fatalf("fd read got %q, want %q", got, "from-go")
	}

	if _, err := unix.Write(dartFd, []byte("from-dart")); err != nil {
		t.Fatalf("fd write: %v", err)
	}
	if err := goConn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	got = make([]byte, len("from-dart"))
	if _, err := io.ReadFull(goConn, got); err != nil {
		t.Fatalf("go read: %v", err)
	}
	if string(got) != "from-dart" {
		t.Fatalf("go read got %q, want %q", got, "from-dart")
	}
}

func TestRuntimeSweepClosesAndClearsTcpListeners(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}

	withLiveServer(t, &tsnet.Server{})
	runtime := currentRuntime()
	if !runtime.fd.tcpListeners.commit(liveGate(t), 999, ln) {
		t.Fatal("live listener registration must be accepted")
	}

	runtime.fd.closeAll()
	runtime.fd.closeAll()

	if got := runtime.fd.tcpListeners.size(); got != 0 {
		t.Fatalf("listener registry length = %d, want 0", got)
	}

	if _, err := ln.Accept(); err == nil {
		t.Fatal("listener was still open after the runtime sweep")
	}
}

func TestListenTLSOnReadyServerRequiresHTTPSBeforeListening(t *testing.T) {
	s := &readyTLSListenServerStub{}
	_, err := listenTLSOnReadyServer(s, nil, "tcp", ":443")
	if err == nil || !strings.Contains(err.Error(), "enable HTTPS") {
		t.Fatalf("listenTLSOnReadyServer error = %v, want HTTPS-disabled error", err)
	}
	if !errors.Is(err, errFeatureUnavailable) {
		t.Fatalf("listenTLSOnReadyServer error = %v, want typed feature-unavailable error", err)
	}
	if code, _ := classifyLocalAPIError(err); code != "featureDisabled" {
		t.Fatalf("listenTLSOnReadyServer code = %q, want featureDisabled", code)
	}
	if s.calls != 0 {
		t.Fatalf("raw Listen calls = %d, want 0", s.calls)
	}
}

func TestValidateTLSListenPlatformMatchesUpstreamCertificateBoundary(t *testing.T) {
	for _, goos := range []string{"android", "ios"} {
		err := validateTLSListenPlatform(goos)
		if err == nil || !strings.Contains(err.Error(), "upstream Tailscale") {
			t.Fatalf("validateTLSListenPlatform(%q) = %v, want upstream mobile rejection", goos, err)
		}
	}
	for _, goos := range []string{"darwin", "linux"} {
		if err := validateTLSListenPlatform(goos); err != nil {
			t.Fatalf("validateTLSListenPlatform(%q) = %v, want supported", goos, err)
		}
	}
}

func TestListenTLSOnReadyServerWrapsRawListenerWithoutUp(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()

	s := &readyTLSListenServerStub{
		domains: []string{"node.example.ts.net"},
		ln:      raw,
	}
	getCertificate := func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
		return nil, errors.New("not exercised")
	}
	got, err := listenTLSOnReadyServer(s, getCertificate, "tcp", ":443")
	if err != nil {
		t.Fatalf("listenTLSOnReadyServer: %v", err)
	}
	defer got.Close()

	if s.calls != 1 || s.network != "tcp" || s.addr != ":443" {
		t.Fatalf("raw Listen = calls:%d network:%q addr:%q", s.calls, s.network, s.addr)
	}
	if got == raw {
		t.Fatal("TLS listen returned the raw listener without a TLS wrapper")
	}
}

func TestSecureRuntimeCertificateGetterValidatesCreatedSidecars(t *testing.T) {
	runtimeDir := filepath.Join(t.TempDir(), "tsnet")
	if err := os.Mkdir(runtimeDir, 0o700); err != nil {
		t.Fatal(err)
	}
	getter := secureRuntimeCertificateGetter(
		runtimeDir,
		func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
			certDir := filepath.Join(runtimeDir, "certs")
			if err := os.Mkdir(certDir, 0o755); err != nil {
				return nil, err
			}
			if err := os.WriteFile(filepath.Join(certDir, "node.key"), []byte("secret"), 0o644); err != nil {
				return nil, err
			}
			return &tls.Certificate{}, nil
		},
	)

	if _, err := getter(nil); err != nil {
		t.Fatalf("secure certificate getter: %v", err)
	}
	for _, path := range []string{filepath.Join(runtimeDir, "certs"), filepath.Join(runtimeDir, "certs", "node.key")} {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		want := os.FileMode(0o600)
		if info.IsDir() {
			want = 0o700
		}
		if got := info.Mode().Perm(); got != want {
			t.Fatalf("%q permissions = %04o, want %04o", path, got, want)
		}
	}
}

func TestSecureRuntimeCertificateGetterWaitsForSuccessfulRetrieval(t *testing.T) {
	runtimeDir := filepath.Join(t.TempDir(), "tsnet")
	if err := os.Mkdir(runtimeDir, 0o700); err != nil {
		t.Fatal(err)
	}
	retrievalErr := errors.New("certificate unavailable")
	calls := 0
	getter := secureRuntimeCertificateGetter(
		runtimeDir,
		func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
			calls++
			if calls == 1 {
				return nil, retrievalErr
			}
			if err := os.WriteFile(filepath.Join(runtimeDir, "node.key"), []byte("secret"), 0o644); err != nil {
				return nil, err
			}
			return &tls.Certificate{}, nil
		},
	)

	if _, err := getter(nil); !errors.Is(err, retrievalErr) {
		t.Fatalf("first retrieval error = %v, want %v", err, retrievalErr)
	}
	if _, err := getter(nil); err != nil {
		t.Fatalf("second retrieval: %v", err)
	}
	info, err := os.Stat(filepath.Join(runtimeDir, "node.key"))
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("file permissions = %04o, want 0600", got)
	}
}

func TestSecureRuntimeCertificateGetterRejectsCreatedSymlink(t *testing.T) {
	runtimeDir := filepath.Join(t.TempDir(), "tsnet")
	if err := os.Mkdir(runtimeDir, 0o700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(t.TempDir(), "outside")
	if err := os.WriteFile(target, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	getter := secureRuntimeCertificateGetter(
		runtimeDir,
		func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
			if err := os.Symlink(target, filepath.Join(runtimeDir, "node.key")); err != nil {
				return nil, err
			}
			return &tls.Certificate{}, nil
		},
	)

	certificate, err := getter(nil)
	if certificate != nil || !errors.Is(err, ErrUnexpectedStateResidue) {
		t.Fatalf("certificate = %v, error = %v; want nil and ErrUnexpectedStateResidue", certificate, err)
	}
}
