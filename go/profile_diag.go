//go:build tailscale_profile_diag

package tailscale

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"sort"
	"strconv"
	"time"
)

const profileMaxControlBytes = 64 * 1024

type profileDiagnosticRequest struct {
	Host      string             `json:"host"`
	Port      int                `json:"port"`
	Direction string             `json:"direction"`
	Config    profileSpeedConfig `json:"config"`
}

type profileSpeedConfig struct {
	WorkloadID         string `json:"workloadId"`
	MeasuredDurationUs int64  `json:"measuredDurationUs"`
	WarmupBytes        int64  `json:"warmupBytes"`
	ChunkBytes         int64  `json:"chunkBytes"`
	MaxInFlightBytes   int64  `json:"maxInFlightBytes"`
	IntervalUs         int64  `json:"intervalUs"`
	StreamCount        int    `json:"streamCount"`
}

func (c profileSpeedConfig) validate() error {
	const mib = int64(1024 * 1024)
	if c.WorkloadID == "" ||
		c.MeasuredDurationUs <= 0 ||
		c.MeasuredDurationUs > int64(30*time.Second/time.Microsecond) ||
		c.WarmupBytes < 0 ||
		c.WarmupBytes > 64*mib ||
		c.ChunkBytes <= 1 ||
		c.ChunkBytes > mib ||
		c.MaxInFlightBytes < c.ChunkBytes ||
		c.MaxInFlightBytes > 4*mib ||
		c.MaxInFlightBytes%c.ChunkBytes != 0 ||
		c.WarmupBytes%c.ChunkBytes != 0 ||
		c.IntervalUs <= 0 ||
		c.IntervalUs > c.MeasuredDurationUs ||
		c.StreamCount != 1 {
		return errors.New("invalid speed-test configuration")
	}
	return nil
}

type profileWriteStats struct {
	SampleCount int   `json:"sampleCount"`
	MinUs       int64 `json:"minUs"`
	P50Us       int64 `json:"p50Us"`
	P95Us       int64 `json:"p95Us"`
	P99Us       int64 `json:"p99Us"`
	MaxUs       int64 `json:"maxUs"`
}

func profileWriteStatsFromSamples(samples []int64) (profileWriteStats, error) {
	if len(samples) == 0 {
		return profileWriteStats{}, errors.New("write-completion samples are empty")
	}
	sorted := append([]int64(nil), samples...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	percentile := func(value float64) int64 {
		index := int(math.Ceil(float64(len(sorted))*value)) - 1
		if index < 0 {
			index = 0
		}
		if index >= len(sorted) {
			index = len(sorted) - 1
		}
		return sorted[index]
	}
	return profileWriteStats{
		SampleCount: len(sorted),
		MinUs:       sorted[0],
		P50Us:       percentile(0.50),
		P95Us:       percentile(0.95),
		P99Us:       percentile(0.99),
		MaxUs:       sorted[len(sorted)-1],
	}, nil
}

func (s profileWriteStats) valid() bool {
	return s.SampleCount > 0 &&
		s.MinUs >= 0 &&
		s.MinUs <= s.P50Us &&
		s.P50Us <= s.P95Us &&
		s.P95Us <= s.P99Us &&
		s.P99Us <= s.MaxUs
}

type profileInterval struct {
	StartUs      int64   `json:"startUs"`
	EndUs        int64   `json:"endUs"`
	Bytes        int64   `json:"bytes"`
	MiBPerSecond float64 `json:"mibPerSecond"`
}

type profileResult struct {
	Schema            int                `json:"schema"`
	Config            profileSpeedConfig `json:"config"`
	Direction         string             `json:"direction"`
	SenderBytes       int64              `json:"senderBytes"`
	ReceiverBytes     int64              `json:"receiverBytes"`
	SenderElapsedUs   int64              `json:"senderElapsedUs"`
	ReceiverElapsedUs int64              `json:"receiverElapsedUs"`
	MiBPerSecond      float64            `json:"mibPerSecond"`
	WriteCompletion   profileWriteStats  `json:"writeCompletion"`
	Valid             bool               `json:"valid"`
	Intervals         []profileInterval  `json:"intervals"`
}

func (r profileResult) validAccounting() bool {
	if r.Schema != 2 ||
		r.SenderBytes <= 0 ||
		r.SenderBytes != r.ReceiverBytes ||
		r.SenderElapsedUs < r.Config.MeasuredDurationUs ||
		r.ReceiverElapsedUs <= 0 ||
		!r.WriteCompletion.valid() ||
		r.SenderBytes%r.Config.ChunkBytes != 0 ||
		int64(r.WriteCompletion.SampleCount) != r.SenderBytes/r.Config.ChunkBytes ||
		len(r.Intervals) == 0 {
		return false
	}
	var expectedStart, total int64
	for _, interval := range r.Intervals {
		if interval.StartUs != expectedStart ||
			interval.EndUs <= interval.StartUs ||
			interval.EndUs > r.ReceiverElapsedUs ||
			interval.Bytes <= 0 {
			return false
		}
		expectedStart = interval.EndUs
		total += interval.Bytes
	}
	return expectedStart == r.ReceiverElapsedUs && total == r.ReceiverBytes
}

type profileControl struct {
	Type            string              `json:"type"`
	Message         string              `json:"message,omitempty"`
	Protocol        int                 `json:"protocol,omitempty"`
	Direction       string              `json:"direction,omitempty"`
	Config          *profileSpeedConfig `json:"config,omitempty"`
	SenderBytes     int64               `json:"senderBytes,omitempty"`
	SenderElapsedUs int64               `json:"senderElapsedUs,omitempty"`
	WriteCompletion *profileWriteStats  `json:"writeCompletion,omitempty"`
	Result          *profileResult      `json:"result,omitempty"`
}

type profileSentMeasurement struct {
	Bytes           int64
	ElapsedUs       int64
	WriteCompletion profileWriteStats
}

// DebugProfileTsnet runs the profiling protocol directly on upstream
// tsnet.Conn. The symbol that reaches Dart is build-tagged into the smoke app
// only; normal package consumers neither compile nor export this diagnostic.
func DebugProfileTsnet(payloadJSON string, timeout time.Duration) ([]byte, error) {
	var request profileDiagnosticRequest
	if err := json.Unmarshal([]byte(payloadJSON), &request); err != nil {
		return nil, fmt.Errorf("decode native tsnet profile request: %w", err)
	}
	if request.Host == "" {
		return nil, errors.New("native tsnet profile host is required")
	}
	if request.Port < 1 || request.Port > 65535 {
		return nil, fmt.Errorf("invalid native tsnet profile port %d", request.Port)
	}
	if request.Direction != "upload" && request.Direction != "download" {
		return nil, fmt.Errorf("invalid native tsnet profile direction %q", request.Direction)
	}
	if err := request.Config.validate(); err != nil {
		return nil, err
	}

	gate, ok := acquireNodeGate()
	if !ok {
		return nil, fmt.Errorf("%w: DebugProfileTsnet called before Start", ErrRuntimeStale)
	}
	ctx, cancel := boundedCallCtxFrom(gate.runtime.ctx, timeout)
	defer cancel()
	if err := gate.awaitDataPlaneReady(ctx); err != nil {
		return nil, fmt.Errorf("native tsnet profile data plane: %w", err)
	}
	conn, err := gate.s.Dial(
		ctx,
		"tcp",
		net.JoinHostPort(request.Host, strconv.Itoa(request.Port)),
	)
	err = gate.runtime.resultError(err)
	if err != nil {
		if conn != nil {
			_ = conn.Close()
		}
		return nil, fmt.Errorf("native tsnet profile dial: %w", err)
	}
	defer conn.Close()
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}

	result, err := runProfileClient(conn, request.Direction, request.Config)
	if err != nil {
		return nil, gate.runtime.resultError(fmt.Errorf("native tsnet profile: %w", err))
	}
	if err := gate.runtime.resultError(nil); err != nil {
		return nil, err
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return nil, fmt.Errorf("encode native tsnet profile result: %w", err)
	}
	return encoded, nil
}

func runProfileClient(
	conn net.Conn,
	direction string,
	config profileSpeedConfig,
) (profileResult, error) {
	reader := bufio.NewReaderSize(conn, profileMaxControlBytes+2)
	if err := writeProfileControl(conn, profileControl{
		Type:      "start",
		Protocol:  2,
		Direction: direction,
		Config:    &config,
	}); err != nil {
		return profileResult{}, err
	}
	if _, err := expectProfileControl(reader, "ready"); err != nil {
		return profileResult{}, err
	}
	if direction == "upload" {
		return runProfileSender(conn, reader, direction, config)
	}
	return runProfileReceiver(conn, reader, direction, config)
}

func runProfileSender(
	conn net.Conn,
	reader *bufio.Reader,
	direction string,
	config profileSpeedConfig,
) (profileResult, error) {
	if err := sendProfileWarmup(conn, config); err != nil {
		return profileResult{}, err
	}
	if _, err := expectProfileControl(reader, "warmupAck"); err != nil {
		return profileResult{}, err
	}
	sent, err := sendProfileMeasurement(conn, config)
	if err != nil {
		return profileResult{}, err
	}
	control, err := expectProfileControl(reader, "result")
	if err != nil {
		return profileResult{}, err
	}
	if control.Result == nil {
		return profileResult{}, errors.New("missing speed-test result")
	}
	result := *control.Result
	if result.Direction != direction ||
		result.Config != config ||
		result.SenderBytes != sent.Bytes ||
		result.SenderElapsedUs != sent.ElapsedUs ||
		result.WriteCompletion != sent.WriteCompletion ||
		!result.Valid ||
		!result.validAccounting() {
		return profileResult{}, errors.New("peer returned mismatched result")
	}
	if err := writeProfileControl(conn, profileControl{Type: "finalAck"}); err != nil {
		return profileResult{}, err
	}
	return result, nil
}

func runProfileReceiver(
	conn net.Conn,
	reader *bufio.Reader,
	direction string,
	config profileSpeedConfig,
) (profileResult, error) {
	if err := discardProfileBytes(reader, config.WarmupBytes); err != nil {
		return profileResult{}, err
	}
	if err := writeProfileControl(conn, profileControl{Type: "warmupAck"}); err != nil {
		return profileResult{}, err
	}
	result, err := receiveProfileMeasurement(reader, direction, config)
	if err != nil {
		return profileResult{}, err
	}
	if err := writeProfileControl(conn, profileControl{
		Type:   "result",
		Result: &result,
	}); err != nil {
		return profileResult{}, err
	}
	if _, err := expectProfileControl(reader, "finalAck"); err != nil {
		return profileResult{}, err
	}
	return result, nil
}

func sendProfileWarmup(conn net.Conn, config profileSpeedConfig) error {
	chunk := make([]byte, int(config.ChunkBytes))
	writesPerBatch := int(config.MaxInFlightBytes / config.ChunkBytes)
	for sent := int64(0); sent < config.WarmupBytes; {
		count := writesPerBatch
		remaining := int((config.WarmupBytes - sent) / config.ChunkBytes)
		if remaining < count {
			count = remaining
		}
		if _, err := writeProfileBatch(conn, chunk, count, false); err != nil {
			return err
		}
		sent += int64(count) * config.ChunkBytes
	}
	return nil
}

func sendProfileMeasurement(
	conn net.Conn,
	config profileSpeedConfig,
) (profileSentMeasurement, error) {
	chunk := make([]byte, int(config.ChunkBytes))
	writesPerBatch := int(config.MaxInFlightBytes / config.ChunkBytes)
	started := time.Now()
	completionUs := make([]int64, 0, writesPerBatch*8)
	var sentBytes int64
	for {
		samples, err := writeProfileBatch(conn, chunk, writesPerBatch, true)
		if err != nil {
			return profileSentMeasurement{}, err
		}
		completionUs = append(completionUs, samples...)
		sentBytes += int64(writesPerBatch) * config.ChunkBytes
		if time.Since(started).Microseconds() >= config.MeasuredDurationUs {
			break
		}
	}
	elapsedUs := time.Since(started).Microseconds()
	stats, err := profileWriteStatsFromSamples(completionUs)
	if err != nil {
		return profileSentMeasurement{}, err
	}
	marker := make([]byte, int(config.ChunkBytes))
	marker[0] = 1
	if err := writeProfileFull(conn, marker); err != nil {
		return profileSentMeasurement{}, err
	}
	if err := writeProfileControl(conn, profileControl{
		Type:            "measurement",
		SenderBytes:     sentBytes,
		SenderElapsedUs: elapsedUs,
		WriteCompletion: &stats,
	}); err != nil {
		return profileSentMeasurement{}, err
	}
	return profileSentMeasurement{
		Bytes:           sentBytes,
		ElapsedUs:       elapsedUs,
		WriteCompletion: stats,
	}, nil
}

type profileWriteSample struct {
	elapsedUs int64
	err       error
}

func writeProfileBatch(
	conn net.Conn,
	chunk []byte,
	count int,
	recordCompletion bool,
) ([]int64, error) {
	results := make(chan profileWriteSample, count)
	for i := 0; i < count; i++ {
		go func() {
			started := time.Now()
			err := writeProfileFull(conn, chunk)
			results <- profileWriteSample{
				elapsedUs: time.Since(started).Microseconds(),
				err:       err,
			}
		}()
	}
	samples := make([]int64, 0, count)
	var firstErr error
	for i := 0; i < count; i++ {
		result := <-results
		if result.err != nil && firstErr == nil {
			firstErr = result.err
		}
		if recordCompletion {
			samples = append(samples, result.elapsedUs)
		}
	}
	return samples, firstErr
}

func receiveProfileMeasurement(
	reader *bufio.Reader,
	direction string,
	config profileSpeedConfig,
) (profileResult, error) {
	frame := make([]byte, int(config.ChunkBytes))
	started := time.Now()
	var totalBytes, intervalBytes, intervalStartUs int64
	intervals := make([]profileInterval, 0, 8)
	for {
		if _, err := io.ReadFull(reader, frame); err != nil {
			return profileResult{}, err
		}
		if frame[0] != 0 && frame[0] != 1 {
			return profileResult{}, errors.New("invalid measurement chunk")
		}
		if frame[0] == 1 {
			for _, value := range frame[1:] {
				if value != 0 {
					return profileResult{}, errors.New("invalid measurement marker")
				}
			}
			break
		}
		totalBytes += config.ChunkBytes
		intervalBytes += config.ChunkBytes
		nowUs := time.Since(started).Microseconds()
		if nowUs-intervalStartUs >= config.IntervalUs {
			intervals = append(intervals, newProfileInterval(
				intervalStartUs,
				nowUs,
				intervalBytes,
			))
			intervalStartUs = nowUs
			intervalBytes = 0
		}
	}
	receiverElapsedUs := time.Since(started).Microseconds()
	control, err := expectProfileControl(reader, "measurement")
	if err != nil {
		return profileResult{}, err
	}
	if intervalBytes > 0 {
		intervals = append(intervals, newProfileInterval(
			intervalStartUs,
			receiverElapsedUs,
			intervalBytes,
		))
	} else if len(intervals) > 0 && intervals[len(intervals)-1].EndUs < receiverElapsedUs {
		last := &intervals[len(intervals)-1]
		last.EndUs = receiverElapsedUs
		last.MiBPerSecond = profileMiBPerSecond(last.Bytes, last.EndUs-last.StartUs)
	}
	if control.WriteCompletion == nil {
		return profileResult{}, errors.New("missing write-completion statistics")
	}
	result := profileResult{
		Schema:            2,
		Config:            config,
		Direction:         direction,
		SenderBytes:       control.SenderBytes,
		ReceiverBytes:     totalBytes,
		SenderElapsedUs:   control.SenderElapsedUs,
		ReceiverElapsedUs: receiverElapsedUs,
		MiBPerSecond:      profileMiBPerSecond(totalBytes, receiverElapsedUs),
		WriteCompletion:   *control.WriteCompletion,
		Intervals:         intervals,
	}
	result.Valid = result.validAccounting()
	if !result.Valid {
		return profileResult{}, errors.New("invalid measurement accounting")
	}
	return result, nil
}

func newProfileInterval(startUs, endUs, bytes int64) profileInterval {
	return profileInterval{
		StartUs:      startUs,
		EndUs:        endUs,
		Bytes:        bytes,
		MiBPerSecond: profileMiBPerSecond(bytes, endUs-startUs),
	}
}

func profileMiBPerSecond(bytes, elapsedUs int64) float64 {
	if elapsedUs <= 0 {
		return 0
	}
	return (float64(bytes) / (1024 * 1024)) /
		(float64(elapsedUs) / float64(time.Second/time.Microsecond))
}

func discardProfileBytes(reader *bufio.Reader, bytes int64) error {
	_, err := io.CopyN(io.Discard, reader, bytes)
	return err
}

func expectProfileControl(
	reader *bufio.Reader,
	want string,
) (profileControl, error) {
	line, err := reader.ReadSlice('\n')
	if errors.Is(err, bufio.ErrBufferFull) || len(line) > profileMaxControlBytes+1 {
		return profileControl{}, errors.New("control message is too large")
	}
	if err != nil {
		return profileControl{}, err
	}
	line = line[:len(line)-1]
	var control profileControl
	if err := json.Unmarshal(line, &control); err != nil {
		return profileControl{}, fmt.Errorf("invalid control message: %w", err)
	}
	if control.Type == "error" {
		if control.Message == "" {
			control.Message = "unknown"
		}
		return profileControl{}, fmt.Errorf("remote error: %s", control.Message)
	}
	if control.Type != want {
		return profileControl{}, fmt.Errorf("expected %s control message", want)
	}
	return control, nil
}

func writeProfileControl(conn net.Conn, control profileControl) error {
	encoded, err := json.Marshal(control)
	if err != nil {
		return err
	}
	if len(encoded) > profileMaxControlBytes {
		return errors.New("control message is too large")
	}
	encoded = append(encoded, '\n')
	return writeProfileFull(conn, encoded)
}

func writeProfileFull(writer io.Writer, bytes []byte) error {
	for len(bytes) > 0 {
		written, err := writer.Write(bytes)
		if err != nil {
			return err
		}
		if written <= 0 {
			return io.ErrShortWrite
		}
		bytes = bytes[written:]
	}
	return nil
}
