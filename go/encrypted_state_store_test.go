package tailscale

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"golang.org/x/crypto/nacl/secretbox"
	"tailscale.com/ipn"
)

func encryptedStoreTestPath(t *testing.T) string {
	t.Helper()
	return filepath.Join(t.TempDir(), "tailscale", encryptedStateFileName)
}

func encryptedStoreTestKey(seed byte) [encryptedStateKeySize]byte {
	var key [encryptedStateKeySize]byte
	for i := range key {
		key[i] = seed + byte(i)
	}
	return key
}

func mustCreateEncryptedStore(t *testing.T, path string, key [encryptedStateKeySize]byte) *encryptedStateStore {
	t.Helper()
	store, err := createEncryptedStateStore(path, key)
	if err != nil {
		t.Fatalf("createEncryptedStateStore: %v", err)
	}
	return store
}

func mustReadFile(t *testing.T, path string) []byte {
	t.Helper()
	value, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", filepath.Base(path), err)
	}
	return value
}

func sealTestEnvelope(t *testing.T, plaintext []byte, key [encryptedStateKeySize]byte, nonceByte byte) []byte {
	t.Helper()
	var nonce [encryptedStateNonceSize]byte
	for i := range nonce {
		nonce[i] = nonceByte
	}
	ciphertext := secretbox.Seal(nil, plaintext, &nonce, &key)
	raw, err := marshalEncryptedStateEnvelope(nonce, ciphertext)
	if err != nil {
		t.Fatalf("marshal test envelope: %v", err)
	}
	return raw
}

func writeTestEnvelope(t *testing.T, path string, raw []byte) {
	t.Helper()
	if err := os.Mkdir(filepath.Dir(path), 0o700); err != nil && !errors.Is(err, os.ErrExist) {
		t.Fatalf("create test state directory: %v", err)
	}
	if err := os.Chmod(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("secure test state directory: %v", err)
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatalf("write test envelope: %v", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatalf("secure test envelope: %v", err)
	}
}

func TestEncryptedStateStoreContract(t *testing.T) {
	path := encryptedStoreTestPath(t)
	key := encryptedStoreTestKey(1)
	store := mustCreateEncryptedStore(t, path, key)

	if _, err := store.ReadState("missing"); !errors.Is(err, ipn.ErrStateNotExist) {
		t.Fatalf("missing ReadState error = %v, want ipn.ErrStateNotExist", err)
	}

	input := []byte("input-alias-marker")
	if err := store.WriteState("aliased", input); err != nil {
		t.Fatalf("WriteState: %v", err)
	}
	input[0] = 'X'
	got, err := store.ReadState("aliased")
	if err != nil {
		t.Fatalf("ReadState: %v", err)
	}
	if string(got) != "input-alias-marker" {
		t.Fatalf("caller input mutated cached state: %q", got)
	}
	got[0] = 'Y'
	gotAgain, err := store.ReadState("aliased")
	if err != nil || string(gotAgain) != "input-alias-marker" {
		t.Fatalf("caller output mutated cached state: value=%q err=%v", gotAgain, err)
	}

	if err := store.WriteState("empty", []byte{}); err != nil {
		t.Fatalf("write exact empty value: %v", err)
	}
	empty, err := store.ReadState("empty")
	if err != nil || empty == nil || len(empty) != 0 {
		t.Fatalf("empty value = %#v, err=%v; want non-nil empty", empty, err)
	}
	if err := store.WriteState("empty", nil); err != nil {
		t.Fatalf("delete exact empty value: %v", err)
	}
	if err := store.WriteState("never-present", nil); err != nil {
		t.Fatalf("delete missing value: %v", err)
	}

	if err := store.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if err := store.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
	if store.cache != nil {
		t.Fatal("Close retained the plaintext cache")
	}
	if store.key != ([encryptedStateKeySize]byte{}) {
		t.Fatal("Close retained the Store-owned DEK")
	}
	if _, err := store.ReadState("aliased"); !errors.Is(err, errEncryptedStateClosed) {
		t.Fatalf("ReadState after Close = %v, want closed error", err)
	}
	if err := store.WriteState("aliased", []byte("new")); !errors.Is(err, errEncryptedStateClosed) {
		t.Fatalf("WriteState after Close = %v, want closed error", err)
	}

	reopened, err := openEncryptedStateStore(path, key)
	if err != nil {
		t.Fatalf("openEncryptedStateStore: %v", err)
	}
	defer reopened.Close()
	if got, err := reopened.ReadState("aliased"); err != nil || string(got) != "input-alias-marker" {
		t.Fatalf("reopened value = %q, err=%v", got, err)
	}
	if _, err := reopened.ReadState("empty"); !errors.Is(err, ipn.ErrStateNotExist) {
		t.Fatalf("deleted empty value after reopen = %v, want missing", err)
	}
}

type sequentialNonceReader struct {
	mu    sync.Mutex
	next  byte
	bytes int
	err   error
}

func (r *sequentialNonceReader) Read(target []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.err != nil {
		return 0, r.err
	}
	for i := range target {
		r.next++
		target[i] = r.next
	}
	r.bytes += len(target)
	return len(target), nil
}

func (r *sequentialNonceReader) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.bytes
}

func TestEncryptedStateStoreNoOpDoesNotRewrite(t *testing.T) {
	path := encryptedStoreTestPath(t)
	key := encryptedStoreTestKey(2)
	random := new(sequentialNonceReader)
	options := defaultEncryptedStateStoreOptions()
	options.random = random
	store, err := createEncryptedStateStoreWithOptions(path, key, options)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.WriteState("same", []byte("value")); err != nil {
		t.Fatal(err)
	}

	beforeRaw := mustReadFile(t, path)
	beforeInfo, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	beforeRandom := random.count()
	if err := store.WriteState("same", []byte("value")); err != nil {
		t.Fatal(err)
	}
	if err := store.WriteState("missing", nil); err != nil {
		t.Fatal(err)
	}
	afterInfo, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if random.count() != beforeRandom {
		t.Fatalf("no-op consumed nonce bytes: before=%d after=%d", beforeRandom, random.count())
	}
	if !bytes.Equal(beforeRaw, mustReadFile(t, path)) {
		t.Fatal("no-op rewrote encrypted bytes")
	}
	if !os.SameFile(beforeInfo, afterInfo) {
		t.Fatal("no-op replaced the encrypted file")
	}
}

func TestEncryptedStateStoreExactEmptySurvivesReopen(t *testing.T) {
	path := encryptedStoreTestPath(t)
	key := encryptedStoreTestKey(19)
	store := mustCreateEncryptedStore(t, path, key)
	if err := store.WriteState("empty", []byte{}); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := openEncryptedStateStore(path, key)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	value, err := reopened.ReadState("empty")
	if err != nil || value == nil || len(value) != 0 {
		t.Fatalf("reopened exact empty value = %#v, err=%v", value, err)
	}
}

func TestEncryptedStateStoreNoncePerAttempt(t *testing.T) {
	path := encryptedStoreTestPath(t)
	key := encryptedStoreTestKey(3)
	random := new(sequentialNonceReader)
	failBeforeWrite := false
	options := defaultEncryptedStateStoreOptions()
	options.random = random
	options.fault = func(stage encryptedStateWriteStage) error {
		if failBeforeWrite && stage == encryptedStateBeforeWrite {
			return errors.New("injected pre-write failure")
		}
		return nil
	}
	store, err := createEncryptedStateStoreWithOptions(path, key, options)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.WriteState("key", []byte("one")); err != nil {
		t.Fatal(err)
	}
	first, err := parseEncryptedStateEnvelope(mustReadFile(t, path), defaultEncryptedStateStoreLimits)
	if err != nil {
		t.Fatal(err)
	}
	beforeFailedAttempt := random.count()
	failBeforeWrite = true
	if err := store.WriteState("key", []byte("two")); !errors.Is(err, errEncryptedStatePersistence) {
		t.Fatalf("failed write error = %v, want persistence error", err)
	}
	if got := random.count() - beforeFailedAttempt; got != encryptedStateNonceSize {
		t.Fatalf("failed write consumed %d nonce bytes, want %d", got, encryptedStateNonceSize)
	}
	failBeforeWrite = false
	if err := store.WriteState("key", []byte("two")); err != nil {
		t.Fatal(err)
	}
	second, err := parseEncryptedStateEnvelope(mustReadFile(t, path), defaultEncryptedStateStoreLimits)
	if err != nil {
		t.Fatal(err)
	}
	if first.nonce == second.nonce || bytes.Equal(first.ciphertext, second.ciphertext) {
		t.Fatal("distinct successful writes reused nonce or ciphertext")
	}
}

func TestEncryptedStateEnvelopeStrictOuterParsing(t *testing.T) {
	key := encryptedStoreTestKey(4)
	valid := sealTestEnvelope(t, []byte(`{}`), key, 9)
	var parsed encryptedStateEnvelopeJSON
	if err := json.Unmarshal(valid, &parsed); err != nil {
		t.Fatal(err)
	}
	nonce := base64.StdEncoding.EncodeToString(parsed.Nonce)
	ciphertext := base64.StdEncoding.EncodeToString(parsed.Ciphertext)
	validFields := fmt.Sprintf(
		`"format":"%s","version":1,"algorithm":"%s","nonce":"%s","ciphertext":"%s"`,
		encryptedStateFormat,
		encryptedStateAlgorithm,
		nonce,
		ciphertext,
	)

	tests := []struct {
		name string
		raw  []byte
		kind error
	}{
		{"null", []byte(`null`), errEncryptedStateInvalidFormat},
		{"array", []byte(`[]`), errEncryptedStateInvalidFormat},
		{"missing fields", []byte(`{}`), errEncryptedStateInvalidFormat},
		{"duplicate field", []byte(`{"format":"tailscale-dart-state",` + validFields + `}`), errEncryptedStateInvalidFormat},
		{"unknown field", []byte(`{` + validFields + `,"extra":true}`), errEncryptedStateInvalidFormat},
		{"wrong case", []byte(`{"Format":"tailscale-dart-state","version":1,"algorithm":"secretbox-xsalsa20-poly1305","nonce":"` + nonce + `","ciphertext":"` + ciphertext + `"}`), errEncryptedStateInvalidFormat},
		{"version string", []byte(`{"format":"tailscale-dart-state","version":"1","algorithm":"secretbox-xsalsa20-poly1305","nonce":"` + nonce + `","ciphertext":"` + ciphertext + `"}`), errEncryptedStateInvalidFormat},
		{"version float", []byte(`{"format":"tailscale-dart-state","version":1.0,"algorithm":"secretbox-xsalsa20-poly1305","nonce":"` + nonce + `","ciphertext":"` + ciphertext + `"}`), errEncryptedStateInvalidFormat},
		{"version exponent", []byte(`{"format":"tailscale-dart-state","version":1e0,"algorithm":"secretbox-xsalsa20-poly1305","nonce":"` + nonce + `","ciphertext":"` + ciphertext + `"}`), errEncryptedStateInvalidFormat},
		{"wrong version", []byte(`{"format":"tailscale-dart-state","version":2,"algorithm":"secretbox-xsalsa20-poly1305","nonce":"` + nonce + `","ciphertext":"` + ciphertext + `"}`), errEncryptedStateUnsupported},
		{"wrong algorithm", []byte(`{"format":"tailscale-dart-state","version":1,"algorithm":"plaintext","nonce":"` + nonce + `","ciphertext":"` + ciphertext + `"}`), errEncryptedStateUnsupported},
		{"nonce wrong type", []byte(`{"format":"tailscale-dart-state","version":1,"algorithm":"secretbox-xsalsa20-poly1305","nonce":24,"ciphertext":"` + ciphertext + `"}`), errEncryptedStateInvalidFormat},
		{"nonce invalid base64", []byte(`{"format":"tailscale-dart-state","version":1,"algorithm":"secretbox-xsalsa20-poly1305","nonce":"!!!","ciphertext":"` + ciphertext + `"}`), errEncryptedStateInvalidFormat},
		{"nonce wrong length", []byte(`{"format":"tailscale-dart-state","version":1,"algorithm":"secretbox-xsalsa20-poly1305","nonce":"` + base64.StdEncoding.EncodeToString(make([]byte, 23)) + `","ciphertext":"` + ciphertext + `"}`), errEncryptedStateInvalidFormat},
		{"base64 with newline", []byte(`{"format":"tailscale-dart-state","version":1,"algorithm":"secretbox-xsalsa20-poly1305","nonce":"` + nonce[:8] + `\n` + nonce[8:] + `","ciphertext":"` + ciphertext + `"}`), errEncryptedStateInvalidFormat},
		{"short ciphertext", []byte(`{"format":"tailscale-dart-state","version":1,"algorithm":"secretbox-xsalsa20-poly1305","nonce":"` + nonce + `","ciphertext":""}`), errEncryptedStateInvalidFormat},
		{"trailing value", append(append([]byte{}, valid...), []byte(`{}`)...), errEncryptedStateInvalidFormat},
		{"invalid UTF-8", []byte{'{', 0xff, '}'}, errEncryptedStateInvalidFormat},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := parseEncryptedStateEnvelope(test.raw, defaultEncryptedStateStoreLimits)
			if !errors.Is(err, test.kind) {
				t.Fatalf("error = %v, want kind %v", err, test.kind)
			}
		})
	}

	if _, err := parseEncryptedStateEnvelope(valid, defaultEncryptedStateStoreLimits); err != nil {
		t.Fatalf("valid envelope rejected: %v", err)
	}
	exact := defaultEncryptedStateStoreLimits
	exact.maxEnvelopeBytes = len(valid)
	if _, err := parseEncryptedStateEnvelope(valid, exact); err != nil {
		t.Fatalf("exact envelope bound rejected: %v", err)
	}
	exact.maxEnvelopeBytes--
	if _, err := parseEncryptedStateEnvelope(valid, exact); !errors.Is(err, errEncryptedStateOversized) {
		t.Fatalf("over-bound envelope error = %v, want oversized", err)
	}
	exact = defaultEncryptedStateStoreLimits
	exact.maxCiphertextBytes = len(parsed.Ciphertext)
	if _, err := parseEncryptedStateEnvelope(valid, exact); err != nil {
		t.Fatalf("exact ciphertext bound rejected: %v", err)
	}
	exact.maxCiphertextBytes--
	if _, err := parseEncryptedStateEnvelope(valid, exact); !errors.Is(err, errEncryptedStateOversized) {
		t.Fatalf("over-bound ciphertext error = %v, want oversized", err)
	}
}

func TestEncryptedStateEnvelopeStrictAuthenticatedMap(t *testing.T) {
	key := encryptedStoreTestKey(5)
	tests := []struct {
		name      string
		plaintext []byte
	}{
		{"null map", []byte(`null`)},
		{"array map", []byte(`[]`)},
		{"duplicate key", []byte(`{"a":"YQ==","a":"Yg=="}`)},
		{"escaped duplicate key", []byte(`{"a":"YQ==","\u0061":"Yg=="}`)},
		{"null value", []byte(`{"a":null}`)},
		{"number value", []byte(`{"a":1}`)},
		{"boolean value", []byte(`{"a":true}`)},
		{"array value", []byte(`{"a":[]}`)},
		{"object value", []byte(`{"a":{}}`)},
		{"invalid base64", []byte(`{"a":"!!!"}`)},
		{"noncanonical base64", []byte(`{"a":"YQ=\n="}`)},
		{"escaped base64", []byte(`{"a":"\u0059Q=="}`)},
		{"trailing value", []byte(`{"a":"YQ=="}{}`)},
		{"invalid UTF-8", []byte{'{', '"', 0xff, '"', ':', '"', '"', '}'}},
	}
	for index, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			path := encryptedStoreTestPath(t)
			writeTestEnvelope(t, path, sealTestEnvelope(t, test.plaintext, key, byte(index+1)))
			if _, err := openEncryptedStateStore(path, key); !errors.Is(err, errEncryptedStateInvalidFormat) {
				t.Fatalf("open error = %v, want invalid format", err)
			}
		})
	}

	path := encryptedStoreTestPath(t)
	const futureKey = ipn.StateKey("future/☃/state")
	writeTestEnvelope(t, path, sealTestEnvelope(t, []byte(`{"future/☃/state":"AAE="}`), key, 80))
	store, err := openEncryptedStateStore(path, key)
	if err != nil {
		t.Fatalf("arbitrary future StateKey rejected: %v", err)
	}
	defer store.Close()
	if got, err := store.ReadState(futureKey); err != nil || !bytes.Equal(got, []byte{0, 1}) {
		t.Fatalf("future key value = %v, err=%v", got, err)
	}
}

func TestEncryptedStateStoreAuthenticationTamperAndReplay(t *testing.T) {
	path := encryptedStoreTestPath(t)
	key := encryptedStoreTestKey(6)
	store := mustCreateEncryptedStore(t, path, key)
	if err := store.WriteState("replay", []byte("old-state")); err != nil {
		t.Fatal(err)
	}
	oldEnvelope := mustReadFile(t, path)
	if err := store.WriteState("replay", []byte("new-state")); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}

	wrongKey := encryptedStoreTestKey(90)
	if _, err := openEncryptedStateStore(path, wrongKey); !errors.Is(err, errEncryptedStateAuthentication) {
		t.Fatalf("wrong-key error = %v, want authentication failure", err)
	}

	currentEnvelope := mustReadFile(t, path)
	var outer encryptedStateEnvelopeJSON
	if err := json.Unmarshal(currentEnvelope, &outer); err != nil {
		t.Fatal(err)
	}
	outer.Ciphertext[len(outer.Ciphertext)-1] ^= 0x01
	tampered, err := json.Marshal(outer)
	if err != nil {
		t.Fatal(err)
	}
	writeTestEnvelope(t, path, tampered)
	if _, err := openEncryptedStateStore(path, key); !errors.Is(err, errEncryptedStateAuthentication) {
		t.Fatalf("tamper error = %v, want authentication failure", err)
	}

	// V1 intentionally has no anti-rollback counter. Replaying an older valid
	// envelope under the stable DEK succeeds and exposes that older logical map.
	writeTestEnvelope(t, path, oldEnvelope)
	replayed, err := openEncryptedStateStore(path, key)
	if err != nil {
		t.Fatalf("valid replay rejected: %v", err)
	}
	defer replayed.Close()
	if got, err := replayed.ReadState("replay"); err != nil || string(got) != "old-state" {
		t.Fatalf("replayed state = %q, err=%v", got, err)
	}
}

func TestEncryptedStateStoreSecretboxKnownVector(t *testing.T) {
	var key [32]byte
	var nonce [24]byte
	message := make([]byte, 64)
	for i := range key {
		key[i] = 1
	}
	for i := range nonce {
		nonce[i] = 2
	}
	for i := range message {
		message[i] = 3
	}
	want, err := hex.DecodeString("8442bc313f4626f1359e3b50122b6ce6fe66ddfe7d39d14e637eb4fd5b45beadab55198df6ab5368439792a23c87db70acb6156dc5ef957ac04f6276cf6093b84be77ff0849cc33e34b7254d5a8f65ad")
	if err != nil {
		t.Fatal(err)
	}
	if got := secretbox.Seal(nil, message, &nonce, &key); !bytes.Equal(got, want) {
		t.Fatalf("secretbox vector mismatch: got %x, want %x", got, want)
	}
}

func TestEncryptedStateStoreSizeBoundaries(t *testing.T) {
	key := encryptedStoreTestKey(7)
	path := encryptedStoreTestPath(t)
	options := defaultEncryptedStateStoreOptions()
	options.limits.maxPlaintextBytes = len(`{}`)
	options.limits.maxCiphertextBytes = len(`{}`) + secretbox.Overhead
	store, err := createEncryptedStateStoreWithOptions(path, key, options)
	if err != nil {
		t.Fatalf("exact plaintext/ciphertext bounds rejected: %v", err)
	}
	store.Close()

	tooSmallPath := encryptedStoreTestPath(t)
	options.limits.maxPlaintextBytes = len(`{}`) - 1
	if _, err := createEncryptedStateStoreWithOptions(tooSmallPath, key, options); !errors.Is(err, errEncryptedStateOversized) {
		t.Fatalf("over-bound create error = %v, want oversized", err)
	}

	plaintext := []byte(`{"a":"YQ=="}`)
	raw := sealTestEnvelope(t, plaintext, key, 40)
	openPath := encryptedStoreTestPath(t)
	writeTestEnvelope(t, openPath, raw)
	options = defaultEncryptedStateStoreOptions()
	options.limits.maxPlaintextBytes = len(plaintext)
	if opened, err := openEncryptedStateStoreWithOptions(openPath, key, options); err != nil {
		t.Fatalf("exact authenticated plaintext bound rejected: %v", err)
	} else {
		opened.Close()
	}
	options.limits.maxPlaintextBytes--
	if _, err := openEncryptedStateStoreWithOptions(openPath, key, options); !errors.Is(err, errEncryptedStateOversized) {
		t.Fatalf("over-bound authenticated plaintext error = %v, want oversized", err)
	}
}

func TestEncryptedStateStoreFileSecurity(t *testing.T) {
	key := encryptedStoreTestKey(8)
	path := encryptedStoreTestPath(t)
	store := mustCreateEncryptedStore(t, path, key)
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	if got := mustMode(t, filepath.Dir(path)); got != 0o700 {
		t.Fatalf("state directory mode = %04o, want 0700", got)
	}
	if got := mustMode(t, path); got != 0o600 {
		t.Fatalf("state file mode = %04o, want 0600", got)
	}
	if err := os.Chmod(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	reopened, err := openEncryptedStateStore(path, key)
	if err != nil {
		t.Fatalf("tighten and reopen: %v", err)
	}
	reopened.Close()
	if got := mustMode(t, filepath.Dir(path)); got != 0o700 {
		t.Fatalf("tightened state directory mode = %04o, want 0700", got)
	}
	if got := mustMode(t, path); got != 0o600 {
		t.Fatalf("tightened state file mode = %04o, want 0600", got)
	}

	t.Run("missing open creates nothing", func(t *testing.T) {
		root := t.TempDir()
		missingDir := filepath.Join(root, "tailscale")
		missing := filepath.Join(missingDir, encryptedStateFileName)
		if _, err := openEncryptedStateStore(missing, key); !errors.Is(err, errEncryptedStateMissing) {
			t.Fatalf("missing open error = %v, want missing", err)
		}
		if _, err := os.Lstat(missingDir); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("missing open created directory: %v", err)
		}
	})

	t.Run("existing destination is not replaced", func(t *testing.T) {
		existing := encryptedStoreTestPath(t)
		writeTestEnvelope(t, existing, []byte("do-not-replace"))
		if _, err := createEncryptedStateStore(existing, key); !errors.Is(err, errEncryptedStateAlreadyExists) {
			t.Fatalf("create-existing error = %v, want already exists", err)
		}
		if got := string(mustReadFile(t, existing)); got != "do-not-replace" {
			t.Fatalf("existing destination changed: %q", got)
		}
	})

	t.Run("file symlink target is untouched", func(t *testing.T) {
		root := t.TempDir()
		dir := filepath.Join(root, "tailscale")
		if err := os.Mkdir(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		target := filepath.Join(root, "target")
		const marker = "symlink-target-must-survive"
		if err := os.WriteFile(target, []byte(marker), 0o600); err != nil {
			t.Fatal(err)
		}
		link := filepath.Join(dir, encryptedStateFileName)
		if err := os.Symlink(target, link); err != nil {
			t.Skipf("symlinks unavailable: %v", err)
		}
		if _, err := openEncryptedStateStore(link, key); !errors.Is(err, errEncryptedStatePathSecurity) {
			t.Fatalf("symlink open error = %v, want path security", err)
		}
		if got := string(mustReadFile(t, target)); got != marker {
			t.Fatalf("symlink target changed: %q", got)
		}
	})

	t.Run("directory symlink is rejected", func(t *testing.T) {
		root := t.TempDir()
		realDir := filepath.Join(root, "real")
		if err := os.Mkdir(realDir, 0o700); err != nil {
			t.Fatal(err)
		}
		linkDir := filepath.Join(root, "tailscale")
		if err := os.Symlink(realDir, linkDir); err != nil {
			t.Skipf("symlinks unavailable: %v", err)
		}
		linkPath := filepath.Join(linkDir, encryptedStateFileName)
		if _, err := createEncryptedStateStore(linkPath, key); !errors.Is(err, errEncryptedStatePathSecurity) {
			t.Fatalf("symlink directory error = %v, want path security", err)
		}
	})

	t.Run("wrong file type is rejected", func(t *testing.T) {
		wrong := encryptedStoreTestPath(t)
		if err := os.MkdirAll(wrong, 0o700); err != nil {
			t.Fatal(err)
		}
		if _, err := openEncryptedStateStore(wrong, key); !errors.Is(err, errEncryptedStatePathSecurity) {
			t.Fatalf("directory-as-file error = %v, want path security", err)
		}
	})

	t.Run("zero-byte file is not treated as fresh", func(t *testing.T) {
		emptyPath := encryptedStoreTestPath(t)
		writeTestEnvelope(t, emptyPath, nil)
		if _, err := openEncryptedStateStore(emptyPath, key); !errors.Is(err, errEncryptedStateInvalidFormat) {
			t.Fatalf("zero-byte open error = %v, want invalid format", err)
		}
	})

	for _, invalid := range []string{"relative/path", filepath.Join(string(filepath.Separator), encryptedStateFileName)} {
		if _, err := createEncryptedStateStore(invalid, key); err == nil {
			t.Fatalf("invalid path %q was accepted", invalid)
		}
	}
}

func TestEncryptedStateStoreFreshDirectoryDurability(t *testing.T) {
	t.Run("syncs parent before committing envelope", func(t *testing.T) {
		path := encryptedStoreTestPath(t)
		var synced []string
		options := defaultEncryptedStateStoreOptions()
		options.syncDirectory = func(path string) error {
			synced = append(synced, path)
			return syncStateDirectory(path)
		}
		store, err := createEncryptedStateStoreWithOptions(path, encryptedStoreTestKey(20), options)
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		want := []string{filepath.Dir(filepath.Dir(path)), filepath.Dir(path)}
		if len(synced) != len(want) || synced[0] != want[0] || synced[1] != want[1] {
			t.Fatalf("directory sync order = %v, want %v", synced, want)
		}
	})

	t.Run("parent sync failure durably cleans fresh directory", func(t *testing.T) {
		path := encryptedStoreTestPath(t)
		injected := errors.New("parent sync failed")
		calls := 0
		options := defaultEncryptedStateStoreOptions()
		options.syncDirectory = func(string) error {
			calls++
			if calls == 1 {
				return injected
			}
			return nil
		}
		if _, err := createEncryptedStateStoreWithOptions(path, encryptedStoreTestKey(21), options); !errors.Is(err, injected) {
			t.Fatalf("parent sync failure = %v, want injected cause", err)
		}
		if calls != 2 {
			t.Fatalf("sync calls = %d, want failed create plus cleanup sync", calls)
		}
		if _, err := os.Lstat(filepath.Dir(path)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("parent sync failure left fresh state directory: %v", err)
		}
	})
}

func TestEncryptedStateStoreCreateDoesNotClobberLateDestination(t *testing.T) {
	path := encryptedStoreTestPath(t)
	const marker = "late-destination-must-survive"
	options := defaultEncryptedStateStoreOptions()
	options.fault = func(stage encryptedStateWriteStage) error {
		if stage != encryptedStateBeforeRename {
			return nil
		}
		return os.WriteFile(path, []byte(marker), 0o600)
	}
	_, err := createEncryptedStateStoreWithOptions(path, encryptedStoreTestKey(22), options)
	if !errors.Is(err, errEncryptedStatePersistence) || !errors.Is(err, errEncryptedStateAlreadyExists) {
		t.Fatalf("late-destination error = %v, want persistence and already-exists causes", err)
	}
	if got := string(mustReadFile(t, path)); got != marker {
		t.Fatalf("late destination was clobbered: %q", got)
	}
}

func mustMode(t *testing.T, path string) os.FileMode {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info.Mode().Perm()
}

func TestEncryptedStateStoreAtomicFailures(t *testing.T) {
	injected := errors.New("injected persistence failure")
	tests := []struct {
		name   string
		mutate func(*encryptedStateStoreOptions)
	}{
		{"before write", func(options *encryptedStateStoreOptions) {
			options.fault = func(stage encryptedStateWriteStage) error {
				if stage == encryptedStateBeforeWrite {
					return injected
				}
				return nil
			}
		}},
		{"temp create", func(options *encryptedStateStoreOptions) {
			options.files.openTemp = func(string) (*os.File, error) { return nil, injected }
		}},
		{"temp chmod", func(options *encryptedStateStoreOptions) {
			options.files.chmod = func(*os.File, os.FileMode) error { return injected }
		}},
		{"temp stat", func(options *encryptedStateStoreOptions) {
			options.files.stat = func(*os.File) (os.FileInfo, error) { return nil, injected }
		}},
		{"temp write", func(options *encryptedStateStoreOptions) {
			options.files.write = func(*os.File, []byte) (int, error) { return 0, injected }
		}},
		{"short write", func(options *encryptedStateStoreOptions) {
			options.files.write = func(file *os.File, value []byte) (int, error) {
				return file.Write(value[:len(value)/2])
			}
		}},
		{"after temp write", func(options *encryptedStateStoreOptions) {
			options.fault = func(stage encryptedStateWriteStage) error {
				if stage == encryptedStateAfterTempWrite {
					return injected
				}
				return nil
			}
		}},
		{"temp sync", func(options *encryptedStateStoreOptions) {
			options.files.sync = func(*os.File) error { return injected }
		}},
		{"after temp sync", func(options *encryptedStateStoreOptions) {
			options.fault = func(stage encryptedStateWriteStage) error {
				if stage == encryptedStateAfterTempSync {
					return injected
				}
				return nil
			}
		}},
		{"temp close", func(options *encryptedStateStoreOptions) {
			options.files.close = func(file *os.File) error {
				_ = file.Close()
				return injected
			}
		}},
		{"before rename", func(options *encryptedStateStoreOptions) {
			options.fault = func(stage encryptedStateWriteStage) error {
				if stage == encryptedStateBeforeRename {
					return injected
				}
				return nil
			}
		}},
		{"rename", func(options *encryptedStateStoreOptions) {
			options.files.rename = func(string, string) error { return injected }
		}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			path := encryptedStoreTestPath(t)
			key := encryptedStoreTestKey(10)
			store := mustCreateEncryptedStore(t, path, key)
			defer store.Close()
			if err := store.WriteState("atomic", []byte("old")); err != nil {
				t.Fatal(err)
			}
			oldRaw := mustReadFile(t, path)
			options := defaultEncryptedStateStoreOptions()
			test.mutate(&options)
			store.options = options
			if err := store.WriteState("atomic", []byte("new")); !errors.Is(err, errEncryptedStatePersistence) {
				t.Fatalf("WriteState error = %v, want persistence failure", err)
			}
			if got, err := store.ReadState("atomic"); err != nil || string(got) != "old" {
				t.Fatalf("cache after returned error = %q, err=%v; want old", got, err)
			}
			if !bytes.Equal(oldRaw, mustReadFile(t, path)) {
				t.Fatal("returned pre-rename error changed authoritative disk state")
			}
			if _, err := os.Lstat(filepath.Join(filepath.Dir(path), encryptedStateTempFileName)); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("returned error left temporary file: %v", err)
			}
			verified, err := openEncryptedStateStore(path, key)
			if err != nil {
				t.Fatalf("reopen old disk state: %v", err)
			}
			defer verified.Close()
			if got, err := verified.ReadState("atomic"); err != nil || string(got) != "old" {
				t.Fatalf("disk after returned error = %q, err=%v; want old", got, err)
			}
		})
	}
}

func TestEncryptedStateStoreCrashBoundaries(t *testing.T) {
	tests := []struct {
		stage   encryptedStateWriteStage
		wantNew bool
		wantTmp bool
	}{
		{encryptedStateBeforeWrite, false, false},
		{encryptedStateAfterTempWrite, false, true},
		{encryptedStateAfterTempSync, false, true},
		{encryptedStateBeforeRename, false, true},
		{encryptedStateAfterRename, true, false},
	}
	for _, test := range tests {
		t.Run(string(test.stage), func(t *testing.T) {
			path := encryptedStoreTestPath(t)
			key := encryptedStoreTestKey(23)
			store := mustCreateEncryptedStore(t, path, key)
			if err := store.WriteState("crash", []byte("old")); err != nil {
				t.Fatal(err)
			}
			oldEnvelope := mustReadFile(t, path)
			if err := store.Close(); err != nil {
				t.Fatal(err)
			}

			command := exec.Command(os.Args[0], "-test.run=^TestEncryptedStateStoreCrashHelper$")
			command.Env = append(
				os.Environ(),
				"TAILSCALE_ENCRYPTED_STORE_CRASH_HELPER=1",
				"TAILSCALE_ENCRYPTED_STORE_CRASH_PATH="+path,
				"TAILSCALE_ENCRYPTED_STORE_CRASH_STAGE="+string(test.stage),
			)
			output, err := command.CombinedOutput()
			var exitError *exec.ExitError
			if !errors.As(err, &exitError) || exitError.ExitCode() != 77 {
				t.Fatalf("crash helper error = %v, output=%s; want exit 77", err, output)
			}

			if test.wantNew == bytes.Equal(oldEnvelope, mustReadFile(t, path)) {
				t.Fatalf("disk authority after crash at %s: wantNew=%v", test.stage, test.wantNew)
			}
			tempPath := filepath.Join(filepath.Dir(path), encryptedStateTempFileName)
			_, tempErr := os.Lstat(tempPath)
			if test.wantTmp && tempErr != nil {
				t.Fatalf("crash at %s did not leave recognizable temp: %v", test.stage, tempErr)
			}
			if !test.wantTmp && !errors.Is(tempErr, os.ErrNotExist) {
				t.Fatalf("crash at %s left unexpected temp: %v", test.stage, tempErr)
			}
			if test.wantTmp {
				if err := os.Remove(tempPath); err != nil {
					t.Fatalf("remove crash-test temp: %v", err)
				}
			}

			reopened, err := openEncryptedStateStore(path, key)
			if err != nil {
				t.Fatalf("reopen after crash at %s: %v", test.stage, err)
			}
			defer reopened.Close()
			want := "old"
			if test.wantNew {
				want = "new"
			}
			if got, err := reopened.ReadState("crash"); err != nil || string(got) != want {
				t.Fatalf("state after crash at %s = %q, err=%v; want %q", test.stage, got, err, want)
			}
		})
	}
}

func TestEncryptedStateStoreCrashHelper(t *testing.T) {
	if os.Getenv("TAILSCALE_ENCRYPTED_STORE_CRASH_HELPER") != "1" {
		return
	}
	path := os.Getenv("TAILSCALE_ENCRYPTED_STORE_CRASH_PATH")
	target := encryptedStateWriteStage(os.Getenv("TAILSCALE_ENCRYPTED_STORE_CRASH_STAGE"))
	options := defaultEncryptedStateStoreOptions()
	options.fault = func(stage encryptedStateWriteStage) error {
		if stage == target {
			os.Exit(77)
		}
		return nil
	}
	store, err := openEncryptedStateStoreWithOptions(path, encryptedStoreTestKey(23), options)
	if err != nil {
		t.Fatalf("crash helper open: %v", err)
	}
	if err := store.WriteState("crash", []byte("new")); err != nil {
		t.Fatalf("crash helper write: %v", err)
	}
	t.Fatal("crash helper reached the end without exiting")
}

func TestEncryptedStateStorePostRenameDiagnosticsKeepNewAuthority(t *testing.T) {
	path := encryptedStoreTestPath(t)
	key := encryptedStoreTestKey(11)
	var diagnostics []error
	commits := 0
	options := defaultEncryptedStateStoreOptions()
	options.recordInitialCommit = func() { commits++ }
	options.reportDurabilityLoss = func(err error) { diagnostics = append(diagnostics, err) }
	failAfterRename := false
	options.fault = func(stage encryptedStateWriteStage) error {
		if failAfterRename && stage == encryptedStateAfterRename {
			return errors.New("worker vanished after rename")
		}
		return nil
	}
	failDirectorySync := false
	options.syncDirectory = func(path string) error {
		if failDirectorySync {
			return errors.New("directory sync unavailable")
		}
		return syncStateDirectory(path)
	}
	store, err := createEncryptedStateStoreWithOptions(path, key, options)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if commits != 1 {
		t.Fatalf("create commit callbacks = %d, want 1", commits)
	}
	failAfterRename = true
	failDirectorySync = true
	if err := store.WriteState("atomic", []byte("new")); err != nil {
		t.Fatalf("post-rename diagnostic became returned failure: %v", err)
	}
	if commits != 1 {
		t.Fatalf("ordinary mutation re-fired initial commit callback: %d", commits)
	}
	if len(diagnostics) != 2 {
		t.Fatalf("durability diagnostics = %d, want 2: %v", len(diagnostics), diagnostics)
	}
	if got, err := store.ReadState("atomic"); err != nil || string(got) != "new" {
		t.Fatalf("cache after rename = %q, err=%v; want new", got, err)
	}
	verified, err := openEncryptedStateStore(path, key)
	if err != nil {
		t.Fatal(err)
	}
	defer verified.Close()
	if got, err := verified.ReadState("atomic"); err != nil || string(got) != "new" {
		t.Fatalf("disk after rename = %q, err=%v; want new", got, err)
	}
}

func TestEncryptedStateStoreReportsTempCleanupFailure(t *testing.T) {
	path := encryptedStoreTestPath(t)
	key := encryptedStoreTestKey(18)
	store := mustCreateEncryptedStore(t, path, key)
	defer store.Close()
	if err := store.WriteState("atomic", []byte("old")); err != nil {
		t.Fatal(err)
	}
	writeFailure := errors.New("injected write failure")
	cleanupFailure := errors.New("injected cleanup failure")
	options := defaultEncryptedStateStoreOptions()
	options.files.write = func(*os.File, []byte) (int, error) { return 0, writeFailure }
	options.files.remove = func(string) error { return cleanupFailure }
	store.options = options
	err := store.WriteState("atomic", []byte("new"))
	if !errors.Is(err, errEncryptedStatePersistence) ||
		!errors.Is(err, writeFailure) ||
		!errors.Is(err, cleanupFailure) {
		t.Fatalf("cleanup failure error = %v, want persistence, write, and cleanup causes", err)
	}
	if got, readErr := store.ReadState("atomic"); readErr != nil || string(got) != "old" {
		t.Fatalf("cache after cleanup failure = %q, err=%v; want old", got, readErr)
	}
	if _, statErr := os.Lstat(filepath.Join(filepath.Dir(path), encryptedStateTempFileName)); statErr != nil {
		t.Fatalf("injected cleanup failure did not leave its test residue: %v", statErr)
	}
}

func TestEncryptedStateStoreRecognizableTempResidueFailsClosed(t *testing.T) {
	path := encryptedStoreTestPath(t)
	key := encryptedStoreTestKey(12)
	store := mustCreateEncryptedStore(t, path, key)
	defer store.Close()
	if err := store.WriteState("key", []byte("old")); err != nil {
		t.Fatal(err)
	}
	oldRaw := mustReadFile(t, path)
	tempPath := filepath.Join(filepath.Dir(path), encryptedStateTempFileName)
	if err := os.WriteFile(tempPath, []byte("interrupted-uncommitted-ciphertext"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := store.WriteState("key", []byte("new")); !errors.Is(err, errEncryptedStatePersistence) {
		t.Fatalf("write with residue error = %v, want persistence failure", err)
	}
	if !bytes.Equal(oldRaw, mustReadFile(t, path)) {
		t.Fatal("pre-existing temp residue changed committed envelope")
	}
	if got := string(mustReadFile(t, tempPath)); got != "interrupted-uncommitted-ciphertext" {
		t.Fatalf("temp residue was overwritten: %q", got)
	}
}

func TestEncryptedStateStoreDoesNotExposePlaintext(t *testing.T) {
	path := encryptedStoreTestPath(t)
	key := encryptedStoreTestKey(13)
	store := mustCreateEncryptedStore(t, path, key)
	defer store.Close()
	const stateKey = ipn.StateKey("distinctive-private-state-key-marker")
	const value = "distinctive-private-state-value-marker"
	if err := store.WriteState(stateKey, []byte(value)); err != nil {
		t.Fatal(err)
	}
	raw := mustReadFile(t, path)
	for _, secret := range []string{string(stateKey), value} {
		if bytes.Contains(raw, []byte(secret)) {
			t.Fatalf("encrypted envelope contains plaintext marker %q", secret)
		}
	}
	store.options.fault = func(encryptedStateWriteStage) error { return errors.New("safe failure") }
	err := store.WriteState(stateKey, []byte("replacement-secret"))
	for _, secret := range []string{string(stateKey), value, "replacement-secret"} {
		if strings.Contains(fmt.Sprint(err), secret) {
			t.Fatalf("error exposed plaintext marker %q: %v", secret, err)
		}
	}
}

func TestEncryptedStateStoreConcurrentReadWrite(t *testing.T) {
	path := encryptedStoreTestPath(t)
	store := mustCreateEncryptedStore(t, path, encryptedStoreTestKey(14))
	defer store.Close()
	if err := store.WriteState("shared", []byte("initial")); err != nil {
		t.Fatal(err)
	}

	var wait sync.WaitGroup
	errorsFound := make(chan error, 16)
	for worker := 0; worker < 8; worker++ {
		wait.Add(1)
		go func(worker int) {
			defer wait.Done()
			for iteration := 0; iteration < 8; iteration++ {
				value := []byte(fmt.Sprintf("worker-%d-iteration-%d", worker, iteration))
				if err := store.WriteState("shared", value); err != nil {
					errorsFound <- err
					return
				}
				if _, err := store.ReadState("shared"); err != nil {
					errorsFound <- err
					return
				}
			}
		}(worker)
	}
	wait.Wait()
	close(errorsFound)
	for err := range errorsFound {
		t.Errorf("concurrent operation failed: %v", err)
	}
}

func TestInspectEncryptedStateEnvelopeFileIsKeylessAndNonCreating(t *testing.T) {
	path := encryptedStoreTestPath(t)
	if err := inspectEncryptedStateEnvelopeFile(path); !errors.Is(err, errEncryptedStateMissing) {
		t.Fatalf("missing inspect error = %v, want missing", err)
	}
	if _, err := os.Lstat(filepath.Dir(path)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("keyless inspect created state directory: %v", err)
	}
	key := encryptedStoreTestKey(15)
	store := mustCreateEncryptedStore(t, path, key)
	store.Close()
	if err := inspectEncryptedStateEnvelopeFile(path); err != nil {
		t.Fatalf("valid keyless inspection: %v", err)
	}
	writeTestEnvelope(t, path, []byte(`{"format":"tailscale-dart-state"}`))
	if err := inspectEncryptedStateEnvelopeFile(path); !errors.Is(err, errEncryptedStateInvalidFormat) {
		t.Fatalf("malformed keyless inspect error = %v, want invalid format", err)
	}
}

func TestEncryptedStateStoreRandomFailureCreatesNoEnvelope(t *testing.T) {
	path := encryptedStoreTestPath(t)
	injected := errors.New("random unavailable")
	options := defaultEncryptedStateStoreOptions()
	options.random = errorReader{err: injected}
	if _, err := createEncryptedStateStoreWithOptions(path, encryptedStoreTestKey(16), options); !errors.Is(err, injected) || !errors.Is(err, errEncryptedStatePersistence) {
		t.Fatalf("random failure = %v", err)
	}
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("random failure created envelope: %v", err)
	}
	if _, err := os.Lstat(filepath.Dir(path)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("random failure left an uncommitted state subtree: %v", err)
	}
}

type errorReader struct{ err error }

func (r errorReader) Read([]byte) (int, error) { return 0, r.err }

func FuzzParseEncryptedStateEnvelope(f *testing.F) {
	key := encryptedStoreTestKey(17)
	f.Add(sealTestEnvelopeForFuzz([]byte(`{}`), key, 1))
	f.Add([]byte(`{}`))
	f.Add([]byte(`null`))
	f.Fuzz(func(t *testing.T, raw []byte) {
		envelope, err := parseEncryptedStateEnvelope(raw, defaultEncryptedStateStoreLimits)
		if err == nil {
			if len(envelope.ciphertext) < secretbox.Overhead || len(envelope.ciphertext) > maxEncryptedStateCiphertextBytes {
				t.Fatalf("successful parse returned invalid ciphertext length %d", len(envelope.ciphertext))
			}
		}
	})
}

func sealTestEnvelopeForFuzz(plaintext []byte, key [encryptedStateKeySize]byte, nonceByte byte) []byte {
	var nonce [encryptedStateNonceSize]byte
	for i := range nonce {
		nonce[i] = nonceByte
	}
	ciphertext := secretbox.Seal(nil, plaintext, &nonce, &key)
	raw, _ := marshalEncryptedStateEnvelope(nonce, ciphertext)
	return raw
}

func FuzzParseEncryptedStateMap(f *testing.F) {
	f.Add([]byte(`{}`))
	f.Add([]byte(`{"a":"YQ=="}`))
	f.Add([]byte(`null`))
	f.Fuzz(func(t *testing.T, raw []byte) {
		state, err := parseEncryptedStateMap(raw)
		if err == nil {
			for _, value := range state {
				if value == nil {
					t.Fatal("successful parse produced a nil value")
				}
			}
		}
	})
}

var _ io.Reader = (*sequentialNonceReader)(nil)
