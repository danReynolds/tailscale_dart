//go:build tailscale_profile_diag

package tailscale

import (
	"bufio"
	"errors"
	"net"
	"testing"
	"time"
)

func TestProfileDiagnosticProtocol(t *testing.T) {
	for _, direction := range []string{"upload", "download"} {
		t.Run(direction, func(t *testing.T) {
			config := profileSpeedConfig{
				WorkloadID:         "test-v2",
				MeasuredDurationUs: int64(20 * time.Millisecond / time.Microsecond),
				WarmupBytes:        8 * 1024,
				ChunkBytes:         1024,
				MaxInFlightBytes:   4 * 1024,
				IntervalUs:         int64(5 * time.Millisecond / time.Microsecond),
				StreamCount:        1,
			}
			client, server := net.Pipe()
			defer client.Close()
			defer server.Close()
			deadline := time.Now().Add(5 * time.Second)
			_ = client.SetDeadline(deadline)
			_ = server.SetDeadline(deadline)

			peerResult := make(chan error, 1)
			go func() {
				peerResult <- serveProfileDiagnosticTestPeer(server, direction, config)
			}()

			result, err := runProfileClient(client, direction, config)
			if err != nil {
				t.Fatalf("runProfileClient: %v", err)
			}
			if !result.Valid || !result.validAccounting() {
				t.Fatalf("invalid result: %+v", result)
			}
			if result.Direction != direction || result.Config != config {
				t.Fatalf("wrong result identity: %+v", result)
			}
			if err := <-peerResult; err != nil {
				t.Fatalf("peer: %v", err)
			}
		})
	}
}

func TestProfileDiagnosticConfigRejectsProtocolDrift(t *testing.T) {
	config := profileSpeedConfig{
		WorkloadID:         "test-v2",
		MeasuredDurationUs: int64(time.Second / time.Microsecond),
		WarmupBytes:        1024,
		ChunkBytes:         1024,
		MaxInFlightBytes:   4 * 1024,
		IntervalUs:         int64(time.Second / time.Microsecond),
		StreamCount:        2,
	}
	if err := config.validate(); err == nil {
		t.Fatal("multi-stream diagnostic config unexpectedly accepted")
	}
}

func serveProfileDiagnosticTestPeer(
	conn net.Conn,
	direction string,
	config profileSpeedConfig,
) error {
	reader := bufio.NewReaderSize(conn, profileMaxControlBytes+2)
	start, err := expectProfileControl(reader, "start")
	if err != nil {
		return err
	}
	if start.Protocol != 2 ||
		start.Direction != direction ||
		start.Config == nil ||
		*start.Config != config {
		return errors.New("invalid start control")
	}
	if err := writeProfileControl(conn, profileControl{Type: "ready"}); err != nil {
		return err
	}
	if direction == "upload" {
		result, err := runProfileReceiver(conn, reader, direction, config)
		if err != nil {
			return err
		}
		if !result.Valid {
			return errors.New("upload result was invalid")
		}
		return nil
	}
	result, err := runProfileSender(conn, reader, direction, config)
	if err != nil {
		return err
	}
	if !result.Valid {
		return errors.New("download result was invalid")
	}
	return nil
}
