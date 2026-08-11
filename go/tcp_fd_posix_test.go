//go:build !windows

package tailscale

import (
	"crypto/tls"
	"errors"
	"io"
	"net"
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
