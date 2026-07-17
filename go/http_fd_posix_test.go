//go:build !windows

package tailscale

import (
	"bytes"
	"crypto/tls"
	"encoding/binary"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

// recordingResponseWriter records the order of Write/Flush calls so a test can
// assert the response body is flushed per chunk.
type recordingResponseWriter struct {
	header http.Header
	events []string
}

func (w *recordingResponseWriter) Header() http.Header {
	if w.header == nil {
		w.header = http.Header{}
	}
	return w.header
}

func (w *recordingResponseWriter) Write(b []byte) (int, error) {
	w.events = append(w.events, "write")
	return len(b), nil
}

func (w *recordingResponseWriter) WriteHeader(int) {}

func (w *recordingResponseWriter) Flush() { w.events = append(w.events, "flush") }

// chunkReader yields each chunk from its own Read call, then EOF, so the copy
// loop sees distinct chunks over time (as a streaming Dart handler would send).
type chunkReader struct {
	chunks [][]byte
	i      int
}

func (r *chunkReader) Read(p []byte) (int, error) {
	if r.i >= len(r.chunks) {
		return 0, io.EOF
	}
	n := copy(p, r.chunks[r.i])
	r.i++
	return n, nil
}

// TestFlushDartHTTPBody_FlushesEachChunk is the M6 regression: a streaming Dart
// response must be flushed after every chunk, or small events (SSE/long-poll)
// stall in net/http's buffer until it fills or the handler returns.
func TestFlushDartHTTPBody_FlushesEachChunk(t *testing.T) {
	r := &chunkReader{chunks: [][]byte{[]byte("aa"), []byte("bb"), []byte("cc")}}
	w := &recordingResponseWriter{}
	if err := flushDartHTTPBody(w, r); err != nil {
		t.Fatalf("flushDartHTTPBody: %v", err)
	}
	want := []string{"write", "flush", "write", "flush", "write", "flush"}
	if !reflect.DeepEqual(w.events, want) {
		t.Fatalf("events = %v, want %v (each chunk must be flushed)", w.events, want)
	}
}

func TestTailnetHTTPClientUsesTailscaleTLSVerifier(t *testing.T) {
	baseTLS := &tls.Config{ServerName: "example.test"}
	baseTransport := &http.Transport{TLSClientConfig: baseTLS}
	client := tailnetHTTPClient(&http.Client{Transport: baseTransport})

	transport, ok := client.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("transport type = %T, want *http.Transport", client.Transport)
	}
	if transport == baseTransport {
		t.Fatal("tailnetHTTPClient reused the caller's transport")
	}
	if baseTransport.TLSClientConfig != baseTLS {
		t.Fatal("tailnetHTTPClient replaced the caller's TLS config")
	}
	if transport.TLSClientConfig == nil {
		t.Fatal("TLSClientConfig was not configured")
	}
	if transport.TLSClientConfig == baseTLS {
		t.Fatal("tailnetHTTPClient reused the caller's TLS config")
	}
	if transport.TLSClientConfig.ServerName != baseTLS.ServerName {
		t.Fatalf(
			"ServerName = %q, want %q",
			transport.TLSClientConfig.ServerName,
			baseTLS.ServerName,
		)
	}
	if !transport.TLSClientConfig.InsecureSkipVerify {
		t.Fatal("TLSClientConfig does not use tailscale tlsdial verification")
	}
	if transport.TLSClientConfig.VerifyConnection == nil {
		t.Fatal("TLSClientConfig is missing tailscale tlsdial verification hook")
	}
}

func TestHTTPResponseHeadRejectsOversizedReadEnvelope(t *testing.T) {
	var prefix [4]byte
	binary.BigEndian.PutUint32(prefix[:], uint32(httpMaxHeadBytes+1))

	_, err := readHTTPResponseHead(bytes.NewReader(prefix[:]))
	if err == nil {
		t.Fatal("readHTTPResponseHead accepted an oversized envelope")
	}
	if !strings.Contains(err.Error(), "invalid HTTP response head length") {
		t.Fatalf("error = %q, want invalid length", err)
	}
}

func TestHTTPResponseHeadRejectsOversizedWriteEnvelope(t *testing.T) {
	err := writeHTTPResponseHead(&bytes.Buffer{}, httpResponseHead{
		StatusCode: http.StatusOK,
		Headers: map[string][]string{
			"x-pad": {strings.Repeat("a", httpMaxHeadBytes)},
		},
	})
	if err == nil {
		t.Fatal("writeHTTPResponseHead accepted an oversized envelope")
	}
	if !strings.Contains(err.Error(), "HTTP response head too large") {
		t.Fatalf("error = %q, want oversized head", err)
	}
}

func TestHTTPBindingServerUsesBoundedTimeouts(t *testing.T) {
	server := newHTTPBindingServer(&httpBindingState{})

	if server.ReadHeaderTimeout != 10*time.Second {
		t.Fatalf("ReadHeaderTimeout = %s, want 10s", server.ReadHeaderTimeout)
	}
	if server.IdleTimeout != 120*time.Second {
		t.Fatalf("IdleTimeout = %s, want 120s", server.IdleTimeout)
	}
}
