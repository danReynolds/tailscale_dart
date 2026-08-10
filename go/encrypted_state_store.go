package tailscale

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sync"
	"unicode/utf8"

	"golang.org/x/crypto/nacl/secretbox"
	"tailscale.com/ipn"
)

const (
	encryptedStateFileName     = "tailscaled.state.enc"
	encryptedStateTempFileName = ".tailscaled.state.enc.tmp"
	encryptedStateFormat       = "tailscale-dart-state"
	encryptedStateVersion      = 1
	encryptedStateAlgorithm    = "secretbox-xsalsa20-poly1305"

	encryptedStateKeySize   = 32
	encryptedStateNonceSize = 24

	maxEncryptedStateEnvelopeBytes   = 24 << 20
	maxEncryptedStatePlaintextBytes  = 16 << 20
	maxEncryptedStateCiphertextBytes = maxEncryptedStatePlaintextBytes + secretbox.Overhead
)

var (
	errEncryptedStateClosed         = errors.New("encrypted StateStore is closed")
	errEncryptedStateMissing        = errors.New("encrypted StateStore file is missing")
	errEncryptedStateAlreadyExists  = errors.New("encrypted StateStore file already exists")
	errEncryptedStateInvalidFormat  = errors.New("invalid encrypted StateStore format")
	errEncryptedStateUnsupported    = errors.New("unsupported encrypted StateStore format")
	errEncryptedStateOversized      = errors.New("encrypted StateStore exceeds its size limit")
	errEncryptedStatePathSecurity   = errors.New("encrypted StateStore path security failure")
	errEncryptedStatePersistence    = errors.New("encrypted StateStore persistence failure")
	errEncryptedStateAuthentication = errors.New("encrypted StateStore authentication failed")
)

type encryptedStateStoreLimits struct {
	maxEnvelopeBytes   int
	maxCiphertextBytes int
	maxPlaintextBytes  int
}

var defaultEncryptedStateStoreLimits = encryptedStateStoreLimits{
	maxEnvelopeBytes:   maxEncryptedStateEnvelopeBytes,
	maxCiphertextBytes: maxEncryptedStateCiphertextBytes,
	maxPlaintextBytes:  maxEncryptedStatePlaintextBytes,
}

type encryptedStateWriteStage string

const (
	encryptedStateBeforeWrite    encryptedStateWriteStage = "before-write"
	encryptedStateAfterTempWrite encryptedStateWriteStage = "after-temp-write"
	encryptedStateAfterTempSync  encryptedStateWriteStage = "after-temp-sync"
	encryptedStateBeforeRename   encryptedStateWriteStage = "before-rename"
	encryptedStateAfterRename    encryptedStateWriteStage = "after-rename"
)

type encryptedStateStoreOptions struct {
	limits               encryptedStateStoreLimits
	random               io.Reader
	files                encryptedStateStoreFileOps
	fault                func(encryptedStateWriteStage) error
	validateRootPath     func() error
	syncDirectory        func(string) error
	recordInitialCommit  func()
	reportDurabilityLoss func(error)
}

type encryptedStateStoreFileOps struct {
	openTemp func(string) (*os.File, error)
	chmod    func(*os.File, os.FileMode) error
	stat     func(*os.File) (os.FileInfo, error)
	write    func(*os.File, []byte) (int, error)
	sync     func(*os.File) error
	close    func(*os.File) error
	rename   func(string, string) error
	remove   func(string) error
	lstat    func(string) (os.FileInfo, error)
}

func defaultEncryptedStateStoreFileOps() encryptedStateStoreFileOps {
	return encryptedStateStoreFileOps{
		openTemp: func(path string) (*os.File, error) {
			return os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		},
		chmod:  func(file *os.File, mode os.FileMode) error { return file.Chmod(mode) },
		stat:   func(file *os.File) (os.FileInfo, error) { return file.Stat() },
		write:  func(file *os.File, value []byte) (int, error) { return file.Write(value) },
		sync:   func(file *os.File) error { return file.Sync() },
		close:  func(file *os.File) error { return file.Close() },
		rename: os.Rename,
		remove: os.Remove,
		lstat:  os.Lstat,
	}
}

func defaultEncryptedStateStoreOptions() encryptedStateStoreOptions {
	return encryptedStateStoreOptions{
		limits:              defaultEncryptedStateStoreLimits,
		random:              rand.Reader,
		files:               defaultEncryptedStateStoreFileOps(),
		validateRootPath:    func() error { return nil },
		syncDirectory:       syncStateDirectory,
		recordInitialCommit: func() {},
		reportDurabilityLoss: func(err error) {
			log.Printf("TSNET: encrypted StateStore durability diagnostic: %v", err)
		},
	}
}

func (o encryptedStateStoreOptions) validate() error {
	if o.limits.maxEnvelopeBytes <= 0 ||
		o.limits.maxCiphertextBytes < secretbox.Overhead ||
		o.limits.maxPlaintextBytes <= 0 {
		return fmt.Errorf("invalid encrypted StateStore size limits")
	}
	if o.random == nil || o.validateRootPath == nil || o.syncDirectory == nil ||
		o.recordInitialCommit == nil || o.reportDurabilityLoss == nil {
		return fmt.Errorf("invalid encrypted StateStore dependencies")
	}
	if o.files.openTemp == nil || o.files.chmod == nil || o.files.stat == nil ||
		o.files.write == nil || o.files.sync == nil || o.files.close == nil ||
		o.files.rename == nil || o.files.remove == nil || o.files.lstat == nil {
		return fmt.Errorf("invalid encrypted StateStore file operations")
	}
	return nil
}

type encryptedStateEnvelope struct {
	nonce      [encryptedStateNonceSize]byte
	ciphertext []byte
}

type encryptedStateEnvelopeJSON struct {
	Format     string `json:"format"`
	Version    int    `json:"version"`
	Algorithm  string `json:"algorithm"`
	Nonce      []byte `json:"nonce"`
	Ciphertext []byte `json:"ciphertext"`
}

// encryptedStateStore is the whole-map authenticated ipn.StateStore used by
// persistent runtimes.
type encryptedStateStore struct {
	ipn.EncryptedStateStore

	path string
	key  [encryptedStateKeySize]byte

	mu       sync.RWMutex
	cache    map[ipn.StateKey][]byte
	fileInfo os.FileInfo
	closed   bool
	options  encryptedStateStoreOptions
}

var (
	_ ipn.StateStore          = (*encryptedStateStore)(nil)
	_ ipn.EncryptedStateStore = (*encryptedStateStore)(nil)
	_ io.Closer               = (*encryptedStateStore)(nil)
)

// createEncryptedStateStore creates the authenticated empty envelope required
// after a fresh DEK is committed. The caller must hold the exclusive state
// lease; under that precondition this never replaces an existing destination.
func createEncryptedStateStore(path string, key [encryptedStateKeySize]byte) (*encryptedStateStore, error) {
	defer wipeBytes(key[:])
	return createEncryptedStateStoreWithOptions(path, key, defaultEncryptedStateStoreOptions())
}

func createEncryptedStateStoreWithOptions(
	path string,
	key [encryptedStateKeySize]byte,
	options encryptedStateStoreOptions,
) (*encryptedStateStore, error) {
	defer wipeBytes(key[:])
	path, err := validateEncryptedStatePath(path)
	if err != nil {
		return nil, err
	}
	if err := options.validate(); err != nil {
		return nil, err
	}
	dir := filepath.Dir(path)
	_, dirErr := os.Lstat(dir)
	directoryWasAbsent := errors.Is(dirErr, os.ErrNotExist)
	if dirErr != nil && !directoryWasAbsent {
		return nil, fmt.Errorf("%w: inspect directory: %w", errEncryptedStatePathSecurity, dirErr)
	}
	if err := secureEncryptedStateDirectory(dir, true); err != nil {
		wrapped := fmt.Errorf("%w: secure directory: %w", errEncryptedStatePathSecurity, err)
		return nil, cleanupFreshEncryptedStateDirectory(dir, directoryWasAbsent, options.syncDirectory, wrapped)
	}
	if directoryWasAbsent {
		if err := options.syncDirectory(filepath.Dir(dir)); err != nil {
			wrapped := fmt.Errorf("%w: sync parent after creating state directory: %w", errEncryptedStatePersistence, err)
			return nil, cleanupFreshEncryptedStateDirectory(dir, true, options.syncDirectory, wrapped)
		}
	}
	if _, err := os.Lstat(path); err == nil {
		return nil, errEncryptedStateAlreadyExists
	} else if !errors.Is(err, os.ErrNotExist) {
		wrapped := fmt.Errorf("%w: inspect destination: %w", errEncryptedStatePathSecurity, err)
		return nil, cleanupFreshEncryptedStateDirectory(dir, directoryWasAbsent, options.syncDirectory, wrapped)
	}

	store := &encryptedStateStore{
		path:    path,
		key:     key,
		cache:   make(map[ipn.StateKey][]byte),
		options: options,
	}
	diagnostics, err := store.commitCandidateLocked(store.cache)
	if err != nil {
		store.wipeLocked()
		return nil, cleanupFreshEncryptedStateDirectory(dir, directoryWasAbsent, options.syncDirectory, err)
	}
	store.reportDurabilityDiagnostics(diagnostics)
	return store, nil
}

func cleanupFreshEncryptedStateDirectory(
	path string,
	created bool,
	syncDirectory func(string) error,
	primary error,
) error {
	if !created {
		return primary
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return errors.Join(primary, fmt.Errorf("remove uncommitted encrypted StateStore directory: %w", err))
	}
	if err := syncDirectory(filepath.Dir(path)); err != nil {
		return errors.Join(primary, fmt.Errorf("sync removal of uncommitted encrypted StateStore directory: %w", err))
	}
	return primary
}

// openEncryptedStateStore opens an existing envelope. A missing file is an
// explicit error because callers invoke this only after obtaining an existing
// DEK; the secure-state matrix classifies that pair as orphaned rather than
// silently starting over.
func openEncryptedStateStore(path string, key [encryptedStateKeySize]byte) (*encryptedStateStore, error) {
	defer wipeBytes(key[:])
	return openEncryptedStateStoreWithOptions(path, key, defaultEncryptedStateStoreOptions())
}

func openEncryptedStateStoreWithOptions(
	path string,
	key [encryptedStateKeySize]byte,
	options encryptedStateStoreOptions,
) (*encryptedStateStore, error) {
	defer wipeBytes(key[:])
	if err := options.validate(); err != nil {
		return nil, err
	}
	path, envelope, info, err := loadEncryptedStateEnvelope(path, options.limits)
	if err != nil {
		return nil, err
	}
	plaintext, ok := secretbox.Open(nil, envelope.ciphertext, &envelope.nonce, &key)
	if !ok {
		return nil, errEncryptedStateAuthentication
	}
	defer wipeBytes(plaintext)
	if len(plaintext) > options.limits.maxPlaintextBytes {
		return nil, fmt.Errorf("%w: authenticated plaintext", errEncryptedStateOversized)
	}
	cache, err := parseEncryptedStateMap(plaintext)
	if err != nil {
		return nil, err
	}
	return &encryptedStateStore{
		path:     path,
		key:      key,
		cache:    cache,
		fileInfo: info,
		options:  options,
	}, nil
}

// inspectEncryptedStateEnvelopeFile validates the complete keyless outer
// envelope without reading custody or creating storage. R4d uses this before a
// Keybay access so malformed/unsupported filesystem state wins deterministically.
func inspectEncryptedStateEnvelopeFile(path string) error {
	_, envelope, _, err := loadEncryptedStateEnvelope(path, defaultEncryptedStateStoreLimits)
	if err != nil {
		return err
	}
	wipeBytes(envelope.ciphertext)
	return nil
}

func loadEncryptedStateEnvelope(
	path string,
	limits encryptedStateStoreLimits,
) (string, encryptedStateEnvelope, os.FileInfo, error) {
	path, err := validateEncryptedStatePath(path)
	if err != nil {
		return "", encryptedStateEnvelope{}, nil, err
	}
	if limits.maxEnvelopeBytes <= 0 ||
		limits.maxCiphertextBytes < secretbox.Overhead ||
		limits.maxPlaintextBytes <= 0 {
		return "", encryptedStateEnvelope{}, nil, fmt.Errorf("invalid encrypted StateStore size limits")
	}
	if err := secureEncryptedStateDirectory(filepath.Dir(path), false); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", encryptedStateEnvelope{}, nil, errEncryptedStateMissing
		}
		return "", encryptedStateEnvelope{}, nil, fmt.Errorf("%w: secure directory: %w", errEncryptedStatePathSecurity, err)
	}
	raw, info, err := readPrivateEncryptedStateFile(path, limits.maxEnvelopeBytes)
	if err != nil {
		if !errors.Is(err, errEncryptedStateMissing) && !errors.Is(err, errEncryptedStateOversized) {
			err = fmt.Errorf("%w: %w", errEncryptedStatePathSecurity, err)
		}
		return "", encryptedStateEnvelope{}, nil, err
	}
	envelope, err := parseEncryptedStateEnvelope(raw, limits)
	if err != nil {
		return "", encryptedStateEnvelope{}, nil, err
	}
	return path, envelope, info, nil
}

func validateEncryptedStatePath(path string) (string, error) {
	if path == "" || !filepath.IsAbs(path) {
		return "", fmt.Errorf("encrypted StateStore path must be absolute")
	}
	path = filepath.Clean(path)
	if filepath.Base(path) != encryptedStateFileName {
		return "", fmt.Errorf("encrypted StateStore path must end in %q", encryptedStateFileName)
	}
	dir := filepath.Dir(path)
	if dir == filepath.Dir(dir) {
		return "", fmt.Errorf("encrypted StateStore cannot use a filesystem root as its directory")
	}
	return path, nil
}

func secureEncryptedStateDirectory(path string, create bool) error {
	if create {
		if err := os.Mkdir(path, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
			return err
		}
	}

	before, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if before.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("path is a symbolic link")
	}
	if !before.IsDir() {
		return fmt.Errorf("path is not a directory")
	}
	if err := verifyCurrentUserOwns(before); err != nil {
		return err
	}

	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	opened, err := dir.Stat()
	if err != nil {
		return err
	}
	current, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if current.Mode()&os.ModeSymlink != 0 || !current.IsDir() || !os.SameFile(opened, current) {
		return fmt.Errorf("directory identity changed while securing it")
	}
	if err := verifyCurrentUserOwns(opened); err != nil {
		return err
	}
	if err := dir.Chmod(0o700); err != nil {
		return err
	}
	final, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if final.Mode()&os.ModeSymlink != 0 || !final.IsDir() || !os.SameFile(opened, final) {
		return fmt.Errorf("directory identity changed while securing it")
	}
	if err := verifyCurrentUserOwns(final); err != nil {
		return err
	}
	if got := final.Mode().Perm(); got != 0o700 {
		return fmt.Errorf("permissions are %04o, want 0700", got)
	}
	return nil
}

func readPrivateEncryptedStateFile(path string, maxBytes int) ([]byte, os.FileInfo, error) {
	before, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil, errEncryptedStateMissing
	}
	if err != nil {
		return nil, nil, fmt.Errorf("inspect encrypted StateStore file: %w", err)
	}
	if before.Mode()&os.ModeSymlink != 0 {
		return nil, nil, fmt.Errorf("encrypted StateStore file is a symbolic link")
	}
	if !before.Mode().IsRegular() {
		return nil, nil, fmt.Errorf("encrypted StateStore path is not a regular file")
	}
	if err := verifyCurrentUserOwns(before); err != nil {
		return nil, nil, fmt.Errorf("verify encrypted StateStore owner: %w", err)
	}

	file, err := os.Open(path)
	if err != nil {
		return nil, nil, fmt.Errorf("open encrypted StateStore file: %w", err)
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return nil, nil, fmt.Errorf("stat encrypted StateStore file: %w", err)
	}
	current, err := os.Lstat(path)
	if err != nil {
		return nil, nil, fmt.Errorf("revalidate encrypted StateStore file: %w", err)
	}
	if current.Mode()&os.ModeSymlink != 0 || !current.Mode().IsRegular() ||
		!os.SameFile(before, opened) || !os.SameFile(opened, current) {
		return nil, nil, fmt.Errorf("encrypted StateStore file identity changed while opening it")
	}
	if err := file.Chmod(0o600); err != nil {
		return nil, nil, fmt.Errorf("secure encrypted StateStore file: %w", err)
	}
	final, err := file.Stat()
	if err != nil {
		return nil, nil, fmt.Errorf("verify encrypted StateStore file: %w", err)
	}
	current, err = os.Lstat(path)
	if err != nil {
		return nil, nil, fmt.Errorf("revalidate encrypted StateStore file: %w", err)
	}
	if current.Mode()&os.ModeSymlink != 0 || !current.Mode().IsRegular() ||
		!os.SameFile(opened, final) || !os.SameFile(final, current) {
		return nil, nil, fmt.Errorf("encrypted StateStore file identity changed while securing it")
	}
	if err := verifyCurrentUserOwns(final); err != nil {
		return nil, nil, fmt.Errorf("verify encrypted StateStore owner: %w", err)
	}
	if got := final.Mode().Perm(); got != 0o600 {
		return nil, nil, fmt.Errorf("encrypted StateStore permissions are %04o, want 0600", got)
	}
	if final.Size() > int64(maxBytes) {
		return nil, nil, fmt.Errorf("%w: raw envelope", errEncryptedStateOversized)
	}
	raw, err := io.ReadAll(io.LimitReader(file, int64(maxBytes)+1))
	if err != nil {
		return nil, nil, fmt.Errorf("read encrypted StateStore file: %w", err)
	}
	if len(raw) > maxBytes {
		return nil, nil, fmt.Errorf("%w: raw envelope", errEncryptedStateOversized)
	}
	return raw, final, nil
}

func parseEncryptedStateEnvelope(raw []byte, limits encryptedStateStoreLimits) (encryptedStateEnvelope, error) {
	if len(raw) > limits.maxEnvelopeBytes {
		return encryptedStateEnvelope{}, fmt.Errorf("%w: raw envelope", errEncryptedStateOversized)
	}
	if !utf8.Valid(raw) {
		return encryptedStateEnvelope{}, fmt.Errorf("%w: outer JSON is not valid UTF-8", errEncryptedStateInvalidFormat)
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	token, err := decoder.Token()
	if err != nil {
		return encryptedStateEnvelope{}, fmt.Errorf("%w: malformed outer JSON", errEncryptedStateInvalidFormat)
	}
	if delimiter, ok := token.(json.Delim); !ok || delimiter != '{' {
		return encryptedStateEnvelope{}, fmt.Errorf("%w: outer value must be an object", errEncryptedStateInvalidFormat)
	}

	seen := make(map[string]bool, 5)
	var format, algorithm, nonceText, ciphertextText string
	var version int
	for decoder.More() {
		fieldToken, err := decoder.Token()
		if err != nil {
			return encryptedStateEnvelope{}, fmt.Errorf("%w: malformed outer field", errEncryptedStateInvalidFormat)
		}
		field, ok := fieldToken.(string)
		if !ok {
			return encryptedStateEnvelope{}, fmt.Errorf("%w: outer field name must be a string", errEncryptedStateInvalidFormat)
		}
		if seen[field] {
			return encryptedStateEnvelope{}, fmt.Errorf("%w: duplicate outer field", errEncryptedStateInvalidFormat)
		}
		seen[field] = true
		switch field {
		case "format":
			format, err = decodeJSONString(decoder)
		case "version":
			version, err = decodeJSONInteger(decoder)
		case "algorithm":
			algorithm, err = decodeJSONString(decoder)
		case "nonce":
			nonceText, err = decodeJSONString(decoder)
		case "ciphertext":
			ciphertextText, err = decodeJSONString(decoder)
		default:
			return encryptedStateEnvelope{}, fmt.Errorf("%w: unknown outer field", errEncryptedStateInvalidFormat)
		}
		if err != nil {
			return encryptedStateEnvelope{}, fmt.Errorf("%w: invalid outer field type", errEncryptedStateInvalidFormat)
		}
	}
	if _, err := decoder.Token(); err != nil {
		return encryptedStateEnvelope{}, fmt.Errorf("%w: malformed outer object", errEncryptedStateInvalidFormat)
	}
	if err := requireJSONEOF(decoder); err != nil {
		return encryptedStateEnvelope{}, fmt.Errorf("%w: trailing outer JSON data", errEncryptedStateInvalidFormat)
	}
	for _, field := range [...]string{"format", "version", "algorithm", "nonce", "ciphertext"} {
		if !seen[field] {
			return encryptedStateEnvelope{}, fmt.Errorf("%w: missing outer field", errEncryptedStateInvalidFormat)
		}
	}
	if format != encryptedStateFormat || version != encryptedStateVersion || algorithm != encryptedStateAlgorithm {
		return encryptedStateEnvelope{}, fmt.Errorf("%w: envelope dispatch tuple", errEncryptedStateUnsupported)
	}

	nonceBytes, err := decodeCanonicalBase64(nonceText)
	if err != nil || len(nonceBytes) != encryptedStateNonceSize {
		return encryptedStateEnvelope{}, fmt.Errorf("%w: invalid nonce", errEncryptedStateInvalidFormat)
	}
	ciphertext, err := decodeCanonicalBase64(ciphertextText)
	if err != nil || len(ciphertext) < secretbox.Overhead {
		return encryptedStateEnvelope{}, fmt.Errorf("%w: invalid ciphertext", errEncryptedStateInvalidFormat)
	}
	if len(ciphertext) > limits.maxCiphertextBytes {
		wipeBytes(ciphertext)
		return encryptedStateEnvelope{}, fmt.Errorf("%w: decoded ciphertext", errEncryptedStateOversized)
	}
	var nonce [encryptedStateNonceSize]byte
	copy(nonce[:], nonceBytes)
	return encryptedStateEnvelope{nonce: nonce, ciphertext: ciphertext}, nil
}

func parseEncryptedStateMap(plaintext []byte) (map[ipn.StateKey][]byte, error) {
	if !utf8.Valid(plaintext) {
		return nil, fmt.Errorf("%w: authenticated state map is not valid UTF-8", errEncryptedStateInvalidFormat)
	}
	decoder := json.NewDecoder(bytes.NewReader(plaintext))
	token, err := decoder.Token()
	if err != nil {
		return nil, fmt.Errorf("%w: malformed authenticated state map", errEncryptedStateInvalidFormat)
	}
	if delimiter, ok := token.(json.Delim); !ok || delimiter != '{' {
		return nil, fmt.Errorf("%w: authenticated state must be an object", errEncryptedStateInvalidFormat)
	}

	state := make(map[ipn.StateKey][]byte)
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			wipeStateMap(state)
			return nil, fmt.Errorf("%w: malformed authenticated state key", errEncryptedStateInvalidFormat)
		}
		key, ok := keyToken.(string)
		if !ok || !utf8.ValidString(key) {
			wipeStateMap(state)
			return nil, fmt.Errorf("%w: invalid authenticated state key", errEncryptedStateInvalidFormat)
		}
		stateKey := ipn.StateKey(key)
		if _, duplicate := state[stateKey]; duplicate {
			wipeStateMap(state)
			return nil, fmt.Errorf("%w: duplicate authenticated state key", errEncryptedStateInvalidFormat)
		}
		value, err := decodeCanonicalBase64JSON(decoder)
		if err != nil {
			wipeStateMap(state)
			return nil, fmt.Errorf("%w: authenticated state value must be canonical non-null bytes", errEncryptedStateInvalidFormat)
		}
		if value == nil {
			value = []byte{}
		}
		state[stateKey] = value
	}
	if _, err := decoder.Token(); err != nil {
		wipeStateMap(state)
		return nil, fmt.Errorf("%w: malformed authenticated state map", errEncryptedStateInvalidFormat)
	}
	if err := requireJSONEOF(decoder); err != nil {
		wipeStateMap(state)
		return nil, fmt.Errorf("%w: trailing authenticated state data", errEncryptedStateInvalidFormat)
	}
	return state, nil
}

func decodeJSONString(decoder *json.Decoder) (string, error) {
	var raw json.RawMessage
	if err := decoder.Decode(&raw); err != nil {
		return "", err
	}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) < 2 || trimmed[0] != '"' {
		return "", fmt.Errorf("JSON value is not a string")
	}
	var value string
	if err := json.Unmarshal(trimmed, &value); err != nil {
		return "", err
	}
	return value, nil
}

func decodeJSONInteger(decoder *json.Decoder) (int, error) {
	var raw json.RawMessage
	if err := decoder.Decode(&raw); err != nil {
		return 0, err
	}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || (trimmed[0] != '-' && (trimmed[0] < '0' || trimmed[0] > '9')) {
		return 0, fmt.Errorf("JSON value is not an integer")
	}
	var value int
	if err := json.Unmarshal(trimmed, &value); err != nil {
		return 0, err
	}
	return value, nil
}

func requireJSONEOF(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return fmt.Errorf("unexpected extra JSON value")
		}
		return err
	}
	return nil
}

func decodeCanonicalBase64(value string) ([]byte, error) {
	decoded, err := base64.StdEncoding.Strict().DecodeString(value)
	if err != nil {
		return nil, err
	}
	if base64.StdEncoding.EncodeToString(decoded) != value {
		wipeBytes(decoded)
		return nil, fmt.Errorf("non-canonical base64")
	}
	return decoded, nil
}

// decodeCanonicalBase64JSON avoids materializing authenticated StateStore
// values as immutable Go strings. Canonical base64 never needs JSON escapes,
// so the raw quoted token can be decoded directly into wipeable byte slices.
func decodeCanonicalBase64JSON(decoder *json.Decoder) ([]byte, error) {
	var raw json.RawMessage
	if err := decoder.Decode(&raw); err != nil {
		return nil, err
	}
	defer wipeBytes(raw)
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) < 2 || trimmed[0] != '"' || trimmed[len(trimmed)-1] != '"' {
		return nil, fmt.Errorf("JSON value is not a string")
	}
	encoded := trimmed[1 : len(trimmed)-1]
	decoded := make([]byte, base64.StdEncoding.DecodedLen(len(encoded)))
	count, err := base64.StdEncoding.Strict().Decode(decoded, encoded)
	if err != nil {
		wipeBytes(decoded)
		return nil, err
	}
	decoded = decoded[:count]
	canonical := make([]byte, base64.StdEncoding.EncodedLen(len(decoded)))
	base64.StdEncoding.Encode(canonical, decoded)
	isCanonical := bytes.Equal(encoded, canonical)
	wipeBytes(canonical)
	if !isCanonical {
		wipeBytes(decoded)
		return nil, fmt.Errorf("non-canonical base64")
	}
	if decoded == nil {
		decoded = []byte{}
	}
	return decoded, nil
}

func marshalEncryptedStateEnvelope(nonce [encryptedStateNonceSize]byte, ciphertext []byte) ([]byte, error) {
	return json.Marshal(encryptedStateEnvelopeJSON{
		Format:     encryptedStateFormat,
		Version:    encryptedStateVersion,
		Algorithm:  encryptedStateAlgorithm,
		Nonce:      nonce[:],
		Ciphertext: ciphertext,
	})
}

// ReadState implements ipn.StateStore.
func (s *encryptedStateStore) ReadState(id ipn.StateKey) ([]byte, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.closed {
		return nil, errEncryptedStateClosed
	}
	value, ok := s.cache[id]
	if !ok {
		return nil, ipn.ErrStateNotExist
	}
	return cloneStateBytes(value), nil
}

// WriteState implements ipn.StateStore. A nil write deletes; a non-nil empty
// write persists an exact empty value and remains distinct from absence.
func (s *encryptedStateStore) WriteState(id ipn.StateKey, value []byte) error {
	if !utf8.ValidString(string(id)) {
		return fmt.Errorf("invalid StateStore key encoding")
	}
	if len(value) > s.options.limits.maxPlaintextBytes {
		return errEncryptedStateOversized
	}

	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return errEncryptedStateClosed
	}
	// Even an otherwise-no-op write is a StateStore lifecycle boundary. Do not
	// let an unchanged cached value hide that the configured root was replaced
	// after preparation but before runtime adoption/start.
	if err := s.validatePersistenceRoot(); err != nil {
		s.mu.Unlock()
		return err
	}
	current, present := s.cache[id]
	if value == nil && !present {
		s.mu.Unlock()
		return nil
	}
	if value != nil && present && bytes.Equal(current, value) {
		s.mu.Unlock()
		return nil
	}

	candidate := cloneStateMap(s.cache)
	if value == nil {
		wipeBytes(candidate[id])
		delete(candidate, id)
	} else {
		candidate[id] = cloneStateBytes(value)
	}
	diagnostics, err := s.commitCandidateLocked(candidate)
	if err != nil {
		wipeStateMap(candidate)
		s.mu.Unlock()
		return err
	}
	s.mu.Unlock()
	s.reportDurabilityDiagnostics(diagnostics)
	return nil
}

func (s *encryptedStateStore) commitCandidateLocked(candidate map[ipn.StateKey][]byte) ([]error, error) {
	plaintext, err := json.Marshal(candidate)
	if err != nil {
		return nil, fmt.Errorf("marshal encrypted StateStore map: %w", err)
	}
	if len(plaintext) > s.options.limits.maxPlaintextBytes {
		wipeBytes(plaintext)
		return nil, fmt.Errorf("%w: plaintext map", errEncryptedStateOversized)
	}
	var nonce [encryptedStateNonceSize]byte
	if _, err := io.ReadFull(s.options.random, nonce[:]); err != nil {
		wipeBytes(plaintext)
		return nil, fmt.Errorf("%w: generate nonce: %w", errEncryptedStatePersistence, err)
	}
	ciphertext := secretbox.Seal(nil, plaintext, &nonce, &s.key)
	wipeBytes(plaintext)
	if len(ciphertext) > s.options.limits.maxCiphertextBytes {
		wipeBytes(ciphertext)
		return nil, fmt.Errorf("%w: ciphertext", errEncryptedStateOversized)
	}
	envelope, err := marshalEncryptedStateEnvelope(nonce, ciphertext)
	wipeBytes(ciphertext)
	if err != nil {
		return nil, fmt.Errorf("%w: marshal envelope: %w", errEncryptedStatePersistence, err)
	}
	if len(envelope) > s.options.limits.maxEnvelopeBytes {
		return nil, fmt.Errorf("%w: envelope", errEncryptedStateOversized)
	}
	diagnostics, err := s.persistEnvelopeLocked(envelope, candidate)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errEncryptedStatePersistence, err)
	}
	return diagnostics, nil
}

func (s *encryptedStateStore) persistEnvelopeLocked(
	envelope []byte,
	candidate map[ipn.StateKey][]byte,
) (diagnostics []error, resultErr error) {
	if err := s.validatePersistenceRoot(); err != nil {
		return nil, err
	}
	committed := false
	defer func() {
		if err := s.validatePersistenceRoot(); err != nil {
			if committed {
				diagnostics = append(diagnostics, fmt.Errorf("after encrypted StateStore persistence: %w", err))
			} else {
				resultErr = errors.Join(resultErr, err)
			}
		}
	}()
	if err := s.runFault(encryptedStateBeforeWrite); err != nil {
		return nil, err
	}
	if err := s.validateDestination(); err != nil {
		return nil, err
	}

	dir := filepath.Dir(s.path)
	tempPath := filepath.Join(dir, encryptedStateTempFileName)
	temp, err := s.options.files.openTemp(tempPath)
	if err != nil {
		return nil, fmt.Errorf("create encrypted StateStore temporary file: %w", err)
	}
	tempClosed := false
	defer func() {
		if !tempClosed {
			_ = temp.Close()
		}
		if tempPath != "" {
			if err := s.options.files.remove(tempPath); err != nil {
				cleanupErr := fmt.Errorf("remove encrypted StateStore temporary file: %w", err)
				resultErr = errors.Join(resultErr, cleanupErr)
			}
		}
	}()
	if err := s.options.files.chmod(temp, 0o600); err != nil {
		return nil, fmt.Errorf("secure encrypted StateStore temporary file: %w", err)
	}
	tempInfo, err := s.options.files.stat(temp)
	if err != nil {
		return nil, fmt.Errorf("stat encrypted StateStore temporary file: %w", err)
	}
	if !tempInfo.Mode().IsRegular() || tempInfo.Mode().Perm() != 0o600 {
		return nil, fmt.Errorf("encrypted StateStore temporary file is not owner-only regular storage")
	}
	if err := verifyCurrentUserOwns(tempInfo); err != nil {
		return nil, fmt.Errorf("verify encrypted StateStore temporary owner: %w", err)
	}
	if n, err := s.options.files.write(temp, envelope); err != nil {
		return nil, fmt.Errorf("write encrypted StateStore temporary file: %w", err)
	} else if n != len(envelope) {
		return nil, fmt.Errorf("write encrypted StateStore temporary file: %w", io.ErrShortWrite)
	}
	if err := s.runFault(encryptedStateAfterTempWrite); err != nil {
		return nil, err
	}
	if err := s.options.files.sync(temp); err != nil {
		return nil, fmt.Errorf("sync encrypted StateStore temporary file: %w", err)
	}
	if err := s.runFault(encryptedStateAfterTempSync); err != nil {
		return nil, err
	}
	if err := s.options.files.close(temp); err != nil {
		return nil, fmt.Errorf("close encrypted StateStore temporary file: %w", err)
	}
	tempClosed = true
	if err := s.runFault(encryptedStateBeforeRename); err != nil {
		return nil, err
	}
	if err := s.validatePersistenceRoot(); err != nil {
		return nil, err
	}
	if err := s.validateDestination(); err != nil {
		return nil, err
	}
	if err := s.options.files.rename(tempPath, s.path); err != nil {
		return nil, fmt.Errorf("commit encrypted StateStore file: %w", err)
	}
	committed = true

	// Rename is the commit point. Publish the new cache immediately; every
	// subsequent problem is a durability diagnostic, never a returned failure
	// that could imply the old cache still owns reality.
	tempPath = ""
	oldCache := s.cache
	isInitialCommit := s.fileInfo == nil
	s.cache = candidate
	s.fileInfo = tempInfo
	if isInitialCommit {
		s.options.recordInitialCommit()
	}
	wipeStateMap(oldCache)

	if err := s.runFault(encryptedStateAfterRename); err != nil {
		diagnostics = append(diagnostics, fmt.Errorf("after encrypted StateStore rename: %w", err))
	}
	if err := s.options.syncDirectory(dir); err != nil {
		diagnostics = append(diagnostics, fmt.Errorf("sync encrypted StateStore directory: %w", err))
	}
	return diagnostics, nil
}

func (s *encryptedStateStore) validatePersistenceRoot() error {
	if err := s.options.validateRootPath(); err != nil {
		return fmt.Errorf("%w: validate persistent state root: %w", errEncryptedStatePathSecurity, err)
	}
	return nil
}

func (s *encryptedStateStore) validateDestination() error {
	info, err := s.options.files.lstat(s.path)
	if s.fileInfo == nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err == nil {
			return errEncryptedStateAlreadyExists
		}
		return fmt.Errorf("%w: inspect destination: %w", errEncryptedStatePathSecurity, err)
	}
	if err != nil {
		return fmt.Errorf("%w: inspect destination: %w", errEncryptedStatePathSecurity, err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("%w: destination is not a regular file", errEncryptedStatePathSecurity)
	}
	if !os.SameFile(s.fileInfo, info) {
		return fmt.Errorf("%w: destination was replaced", errEncryptedStatePathSecurity)
	}
	if err := verifyCurrentUserOwns(info); err != nil {
		return fmt.Errorf("%w: verify destination owner: %w", errEncryptedStatePathSecurity, err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		return fmt.Errorf("%w: destination permissions are %04o, want 0600", errEncryptedStatePathSecurity, got)
	}
	return nil
}

func (s *encryptedStateStore) runFault(stage encryptedStateWriteStage) error {
	if s.options.fault == nil {
		return nil
	}
	if err := s.options.fault(stage); err != nil {
		return fmt.Errorf("encrypted StateStore fault at %s: %w", stage, err)
	}
	return nil
}

func (s *encryptedStateStore) reportDurabilityDiagnostics(diagnostics []error) {
	for _, err := range diagnostics {
		s.options.reportDurabilityLoss(err)
	}
}

func syncStateDirectory(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	if err := dir.Sync(); err != nil {
		_ = dir.Close()
		return err
	}
	return dir.Close()
}

func cloneStateBytes(value []byte) []byte {
	if value == nil {
		return nil
	}
	cloned := make([]byte, len(value))
	copy(cloned, value)
	return cloned
}

func cloneStateMap(state map[ipn.StateKey][]byte) map[ipn.StateKey][]byte {
	cloned := make(map[ipn.StateKey][]byte, len(state))
	for key, value := range state {
		cloned[key] = cloneStateBytes(value)
	}
	return cloned
}

func wipeBytes(value []byte) {
	clear(value)
}

func wipeStateMap(state map[ipn.StateKey][]byte) {
	for key, value := range state {
		wipeBytes(value)
		delete(state, key)
	}
}

// Close wipes the mutable cache and the store-owned DEK best-effort. The
// caller must close tsnet.Server first so upstream cannot race a late access.
func (s *encryptedStateStore) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil
	}
	s.wipeLocked()
	return nil
}

func (s *encryptedStateStore) wipeLocked() {
	wipeStateMap(s.cache)
	s.cache = nil
	wipeBytes(s.key[:])
	s.fileInfo = nil
	s.closed = true
}
