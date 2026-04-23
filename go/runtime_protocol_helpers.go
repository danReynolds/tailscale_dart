package tailscale

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"io"
	"strings"
)

type spikeHelloEnvelope struct {
	Type                string   `json:"type"`
	SessionVersions     []int    `json:"sessionProtocolVersions,omitempty"`
	ClientNonceB64      string   `json:"clientNonceB64,omitempty"`
	ServerNonceB64      string   `json:"serverNonceB64,omitempty"`
	SessionGenerationID string   `json:"sessionGenerationIdB64"`
	CarrierKind         string   `json:"carrierKind"`
	ListenerOwner       string   `json:"listenerOwner"`
	ListenerEndpoint    string   `json:"listenerEndpoint"`
	RequestedCaps       []string `json:"requestedCapabilities,omitempty"`
	AcceptedCaps        []string `json:"acceptedCapabilities,omitempty"`
	SelectedVersion     int      `json:"selectedVersion,omitempty"`
	MacB64              string   `json:"macB64"`
}

func writeLengthPrefixedJSON(w io.Writer, value any) error {
	bytes, err := json.Marshal(value)
	if err != nil {
		return err
	}
	header := make([]byte, 4)
	binary.BigEndian.PutUint32(header, uint32(len(bytes)))
	if _, err := w.Write(header); err != nil {
		return err
	}
	_, err = w.Write(bytes)
	return err
}

func readLengthPrefixedJSON(r io.Reader, out any) error {
	header := make([]byte, 4)
	if _, err := io.ReadFull(r, header); err != nil {
		return err
	}
	length := binary.BigEndian.Uint32(header)
	payload := make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		return err
	}
	return json.Unmarshal(payload, out)
}

func hmacSHA256(key, data []byte) []byte {
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write(data)
	return mac.Sum(nil)
}

func hkdfExtract(salt, ikm []byte) []byte {
	return hmacSHA256(salt, ikm)
}

func hkdfExpand(prk, info []byte, length int) []byte {
	var result []byte
	var previous []byte
	counter := byte(1)
	for len(result) < length {
		mac := hmac.New(sha256.New, prk)
		if len(previous) > 0 {
			_, _ = mac.Write(previous)
		}
		_, _ = mac.Write(info)
		_, _ = mac.Write([]byte{counter})
		previous = mac.Sum(nil)
		result = append(result, previous...)
		counter++
	}
	return result[:length]
}

func canonicalLines(fields map[string]string) []byte {
	order := []string{
		"msg",
		"session_protocol_versions",
		"selected_version",
		"client_nonce_b64",
		"server_nonce_b64",
		"session_generation_id_b64",
		"carrier_kind",
		"listener_owner",
		"listener_endpoint",
		"requested_capabilities",
		"accepted_capabilities",
	}
	lines := make([]string, 0, len(order))
	for _, key := range order {
		value, ok := fields[key]
		if !ok {
			continue
		}
		lines = append(lines, key+"="+value)
	}
	return []byte(strings.Join(lines, "\n"))
}

func appendWithNull(left, right []byte) []byte {
	out := make([]byte, 0, len(left)+1+len(right))
	out = append(out, left...)
	out = append(out, 0)
	out = append(out, right...)
	return out
}
