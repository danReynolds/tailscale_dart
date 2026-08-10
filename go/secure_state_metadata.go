package tailscale

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"unicode/utf8"

	"tailscale.com/ipn"
)

const (
	// persistentRuntimeConfigStateKey is package-owned metadata stored inside
	// the authenticated StateStore envelope. It is deliberately outside the
	// upstream key namespace and is the only key ignored by logicalEmpty.
	persistentRuntimeConfigStateKey = ipn.StateKey("_tailscale-dart/runtime-config")

	persistentRuntimeConfigVersion = 1
	maxRuntimeConfigMetadataBytes  = 64 << 10
)

var (
	errRuntimeConfigMetadataInvalid = errors.New("invalid persistent runtime configuration metadata")
	errRuntimeConfigMetadataVersion = errors.New("unsupported persistent runtime configuration metadata version")
)

type persistentRuntimeConfigJSON struct {
	Version    int    `json:"version"`
	Hostname   string `json:"hostname"`
	ControlURL string `json:"controlURL"`
	Ephemeral  bool   `json:"ephemeral"`
}

// saveRuntimeConfig retains the immutable configuration needed to reopen a
// persistent identity after a process restart. Ephemeral runtimes never have
// persistent state and therefore cannot write this metadata.
func saveRuntimeConfig(store ipn.StateStore, config runtimeConfig) error {
	if store == nil || config.ephemeral ||
		!utf8.ValidString(config.hostname) || !utf8.ValidString(config.controlURL) ||
		len(config.hostname) > maxRuntimeConfigMetadataBytes ||
		len(config.controlURL) > maxRuntimeConfigMetadataBytes ||
		len(config.hostname) > maxRuntimeConfigMetadataBytes-len(config.controlURL) {
		return runtimeConfigMetadataError("configuration is not persistable")
	}

	payload, err := json.Marshal(persistentRuntimeConfigJSON{
		Version:    persistentRuntimeConfigVersion,
		Hostname:   config.hostname,
		ControlURL: config.controlURL,
		Ephemeral:  false,
	})
	if err != nil {
		return runtimeConfigMetadataError("encode failure")
	}
	defer wipeBytes(payload)
	if len(payload) > maxRuntimeConfigMetadataBytes {
		return runtimeConfigMetadataError("metadata exceeds its size limit")
	}
	return ipn.WriteState(store, persistentRuntimeConfigStateKey, payload)
}

// clearRuntimeConfig removes any tuple proven by an earlier Server.Start
// before a fresh start attempt can mutate upstream state under a new tuple.
// Call the Store directly: ipn.WriteState treats nil and a stored empty value
// as equal, while StateStore's contract requires nil to mean deletion.
func clearRuntimeConfig(store ipn.StateStore) error {
	if store == nil {
		return runtimeConfigMetadataError("store is unavailable")
	}
	return store.WriteState(persistentRuntimeConfigStateKey, nil)
}

// loadRuntimeConfig reads and strictly validates package-owned runtime
// metadata. Absence is reported as ipn.ErrStateNotExist so callers can
// distinguish a missing record from corrupt or unsupported authenticated data.
func loadRuntimeConfig(store ipn.StateStore) (runtimeConfig, error) {
	if store == nil {
		return runtimeConfig{}, runtimeConfigMetadataError("store is unavailable")
	}
	stored, err := store.ReadState(persistentRuntimeConfigStateKey)
	if err != nil {
		return runtimeConfig{}, err
	}
	// StateStore does not promise that ReadState returns caller-owned memory.
	// Parse and wipe a private copy without mutating an implementation's cache.
	payload := bytes.Clone(stored)
	defer wipeBytes(payload)
	return parseRuntimeConfigMetadata(payload)
}

func parseRuntimeConfigMetadata(payload []byte) (runtimeConfig, error) {
	if len(payload) == 0 || len(payload) > maxRuntimeConfigMetadataBytes || !utf8.Valid(payload) {
		return runtimeConfig{}, runtimeConfigMetadataError("invalid encoding or size")
	}

	decoder := json.NewDecoder(bytes.NewReader(payload))
	token, err := decoder.Token()
	if err != nil {
		return runtimeConfig{}, runtimeConfigMetadataError("malformed object")
	}
	if delimiter, ok := token.(json.Delim); !ok || delimiter != '{' {
		return runtimeConfig{}, runtimeConfigMetadataError("metadata must be an object")
	}

	seen := make(map[string]bool, 4)
	var wire persistentRuntimeConfigJSON
	for decoder.More() {
		fieldToken, err := decoder.Token()
		if err != nil {
			return runtimeConfig{}, runtimeConfigMetadataError("malformed field")
		}
		field, ok := fieldToken.(string)
		if !ok {
			return runtimeConfig{}, runtimeConfigMetadataError("invalid field name")
		}
		if seen[field] {
			return runtimeConfig{}, runtimeConfigMetadataError("duplicate field")
		}
		seen[field] = true

		switch field {
		case "version":
			wire.Version, err = decodeJSONInteger(decoder)
		case "hostname":
			wire.Hostname, err = decodeJSONString(decoder)
		case "controlURL":
			wire.ControlURL, err = decodeJSONString(decoder)
		case "ephemeral":
			wire.Ephemeral, err = decodeJSONBoolean(decoder)
		default:
			return runtimeConfig{}, runtimeConfigMetadataError("unknown field")
		}
		if err != nil {
			return runtimeConfig{}, runtimeConfigMetadataError("invalid field type")
		}
	}
	if _, err := decoder.Token(); err != nil {
		return runtimeConfig{}, runtimeConfigMetadataError("malformed object")
	}
	if err := requireJSONEOF(decoder); err != nil {
		return runtimeConfig{}, runtimeConfigMetadataError("trailing data")
	}
	for _, field := range [...]string{"version", "hostname", "controlURL", "ephemeral"} {
		if !seen[field] {
			return runtimeConfig{}, runtimeConfigMetadataError("missing field")
		}
	}
	if wire.Version != persistentRuntimeConfigVersion {
		return runtimeConfig{}, errRuntimeConfigMetadataVersion
	}
	if wire.Ephemeral {
		return runtimeConfig{}, runtimeConfigMetadataError("ephemeral metadata is forbidden")
	}
	if !utf8.ValidString(wire.Hostname) || !utf8.ValidString(wire.ControlURL) {
		return runtimeConfig{}, runtimeConfigMetadataError("invalid string encoding")
	}

	return runtimeConfig{
		hostname:   wire.Hostname,
		controlURL: wire.ControlURL,
		ephemeral:  false,
	}, nil
}

func decodeJSONBoolean(decoder *json.Decoder) (bool, error) {
	var raw json.RawMessage
	if err := decoder.Decode(&raw); err != nil {
		return false, err
	}
	trimmed := bytes.TrimSpace(raw)
	if !bytes.Equal(trimmed, []byte("true")) && !bytes.Equal(trimmed, []byte("false")) {
		return false, fmt.Errorf("JSON value is not a boolean")
	}
	return bytes.Equal(trimmed, []byte("true")), nil
}

func runtimeConfigMetadataError(detail string) error {
	return fmt.Errorf("%w: %s", errRuntimeConfigMetadataInvalid, detail)
}

// logicalEmpty reports whether the authenticated envelope contains no
// upstream Tailscale state. Exactly the package-owned runtime metadata key is
// ignored; similarly named and future upstream keys remain authoritative.
func (s *encryptedStateStore) logicalEmpty() (bool, error) {
	if s == nil {
		return false, errEncryptedStateClosed
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.closed {
		return false, errEncryptedStateClosed
	}
	for key := range s.cache {
		if key != persistentRuntimeConfigStateKey {
			return false, nil
		}
	}
	return true, nil
}
