# ADR: Encrypted node state and Keybay custody

## Status

**Accepted; R4d implemented in current source — 2026-08-10.**

This ADR defines the pre-launch persistence replacement. There is deliberately
no SQLite migration. R4d now wires the encrypted Store, Keybay custody, state
lease, secure idle operations, explicit local forget, and ephemeral in-memory
path together and removes the SQLite runtime/dependency. R6 real-platform
custody, backup-exclusion, crash, and complete sidecar-inventory receipts remain
release gates; this status does not certify those receipts.

## Context

Tailscale StateStore data contains cloning-sensitive node identity, profile,
preferences, and publication state. Before R4d, the package stored that logical
map in SQLite under an owner-only directory. Permissions and mobile sandboxing
were useful, but a copied backup or offline copy of the database could carry the
node's private identity to another device.

The architecture audit initially suggested Tailscale's default FileStore as the
simpler replacement. Current security requirements change that conclusion:

- FileStore is an atomic, mode-`0600`, **plaintext** JSON map.
- wrapping each FileStore value leaks StateStore key names, item count, and
  value sizes while adding two storage abstractions;
- reducing a wrapper to one encrypted value means implementing our own logical
  map and atomicity anyway;
- StateStore is not a data-plane workload, so SQLite has no demonstrated
  performance justification;
- the pre-cutover SQLite implementation violated the upstream nil-delete contract
  and `HasState` creates storage while trying to inspect it.

Keybay already implements the platform-specific custody work in Dart. It can
hold an opaque 32-byte data-encryption key in Apple Keychain or in its
authenticated file whose root key is protected by Android Keystore, macOS
Keychain, or Linux Secret Service. Keybay cannot be called from Go, so core
calls it on the Dart caller isolate and transfers only the raw key bytes across
FFI. Keybay is the required production custody mechanism for persistent nodes.

## Decision summary

For persistent nodes:

1. The core Dart package depends directly on `package:keybay` for production
   persistent-state custody.
2. Core binds one caller-supplied stable host application identifier to one
   dedicated Keybay namespace and DEK entry; production callers do not select
   an alternate provider.
3. A native exclusive state lease serializes key and file operations across
   isolates and processes.
4. Dart obtains or creates one 32-byte random DEK while holding that lease.
5. The key crosses FFI as raw bytes plus an explicit length.
6. Go implements `ipn.StateStore` as an in-memory logical map persisted in one
   versioned, authenticated encrypted file.
7. After startup, Go retains one runtime-scoped in-memory DEK copy; ordinary
   StateStore reads and writes never call Keybay. Runtime close wipes that copy
   best-effort, and a later runtime reads the DEK from Keybay again.
8. The store embeds `ipn.EncryptedStateStore`, exactly implements upstream
   concurrency, missing-key, and nil-delete behavior, and adds TPM-style clone
   discipline so callers cannot mutate its cache by alias.
9. Every missing-key, corrupt, legacy, conflicting, residual, incomplete-reset,
   or unavailable-Keybay condition fails closed.
10. `down()` and `logout()` preserve the storage container and DEK. Logout lets
   upstream remove the current profile from the logical StateStore only after
   confirmed control-plane success. Only explicit local forget records durable
   reset intent and destroys the exact key and package-owned subtree.
11. Legacy SQLite/FileStore state is not migrated pre-launch.

Ephemeral nodes use an in-memory StateStore and do not create a DEK or
persistent StateStore. Because tsnet still requires a writable `Server.Dir` for
logs and possible certificate sidecars, each ephemeral runtime receives a fresh
random `0700` scratch directory in an app cache/temporary location, never the
persistent state root. The current implementation hardcodes the process
temporary directory (Go `os.TempDir()`) as that scratch parent; a
host-configurable scratch parent is an expected R6 follow-up so the platform
backup-exclusion receipts (for example Android `noBackupFilesDir`) can bind
scratch to an app-owned cache location. Normal close removes it. Startup may
sweep an old package-prefixed scratch directory only after validating
ownership and age and acquiring that directory's nonblocking live lock; age
alone can never authorize deleting a suspended or still-running process's
directory. A crash can leave
owner-only scratch, so that location must also be excluded from backup.

This cutover belongs to R4d. Its persistent-root occupancy check is strictly
filesystem-only: ephemeral startup never invokes `read`, `write`, or `delete` on
Keybay. It rejects a reset marker, recognized persistent artifacts, or a
non-empty package-owned state subtree. A Keybay-only orphan is intentionally
invisible to ephemeral mode, remains untouched, and is reported by the next
persistent secure probe.

## Security objectives

The design protects the **StateStore ciphertext** against:

- an attacker or backup service obtaining `tailscaled.state.enc` without the
  externally custodied DEK;
- accidental cloud-backup restoration of node StateStore data onto another
  device without its OS-protected Keybay key;
- offline inspection of StateStore key names and values;
- undetected ciphertext modification, truncation, wrong-key use, and most
  partial-write failures;
- concurrent local runtimes racing key creation or state-file replacement.

The design does not claim to protect against:

- a compromised app process while the node is running;
- root, a debugger, memory inspection, or a hostile kernel;
- guaranteed erasure from Dart's managed heap or Go runtime copies;
- observation of file existence, approximate encrypted size, and write timing;
- replay of any older valid envelope produced under the current stable DEK. An
  attacker or backup system that can replace only `tailscaled.state.enc` can
  roll StateStore data back without changing Keybay;
- every file written by upstream tsnet outside `ipn.StateStore`.

Remote revocation remains the authority that makes an old node credential
unusable. Local encryption is defense in depth and backup-cloning protection,
not a replacement for logout/revocation. Remote revocation limits replay of a
revoked node credential, but does not prevent local prefs, profile, or
publication rollback. Solving replay requires a separately protected monotonic
counter/digest plus a cross-system commit protocol; that is explicitly deferred
from v1 rather than implied by authentication encryption.

## Dart Keybay custody boundary

Production persistence uses Keybay's bytes API directly. Core lazily creates a
`SecretStorage` on the caller/UI isolate, using one caller-supplied stable host
application identifier and the dedicated namespace below. It never sends the
Keybay object to the control worker. The worker first acquires the native state
lease, the caller performs the Keybay operation, and only the resulting bytes
are transferred to the worker for native startup.

Keybay is lifecycle-scoped, not a StateStore backend. Fresh provisioning reads
and then writes the DEK once; a normal later runtime reads it once; explicit
local forget deletes it once. Ordinary logout performs no Keybay mutation.
While a runtime is active, Go uses its in-memory DEK for every encrypted
StateStore mutation and makes no Keybay round trips. An explicit idle
secure-state probe may perform a bounded read because it must authenticate the
envelope before classifying its contents.

Contract:

- `read()` never creates or repairs Tailscale state and its result is copied
  into a fresh core-owned mutable buffer.
- `write()` is called only for confirmed fresh state while the external state
  lease is held. It is not a rotation API. Completion with an error does
  **not** prove that Keybay made no durable change; deleting the exact entry is
  therefore the compensating action after any unsuccessful fresh-key write
  attempt whose encrypted envelope did not commit.
- core generates the DEK with `Random.secure()` and validates exactly 32 bytes
  before and after Keybay custody.
- reset calls `delete()` for the exact DEK entry and never calls `deleteAll()`.
- every Keybay error propagates. There is no plaintext, constant-key, alternate
  provider, or generated-key fallback.
- one Keybay namespace maps to exactly one stable host application and one
  Tailscale state root.

The exact public initialization spelling is reviewed in the implementation PR,
but its shape is:

```dart
Tailscale.init(
  stateDir: appSupportDirectory.path,
  appId: 'com.example.myapp',
);
```

Core derives the dedicated Keybay namespace from `appId`; callers do not pass a
custodian object. Persistent startup returns a typed secure-storage error when
Keybay is unavailable. A package-internal test constructor may use Keybay's
`SecretStorage.withBackend` fake seam; production API does not expose an
alternate custody provider.

## Keybay namespace policy

Core binds a dedicated Keybay namespace:

```text
Keybay appId: <stable-host-application-id>.tailscale
entry key:    tailscale/state-store/v1/dek
label:        Tailscale node-state encryption key
```

The host supplies the stable application identifier. Do not derive it from an
absolute `stateDir`, process name, hostname, or package-global
`tailscale-dart` value. Core validates Keybay's identifier rules and
length limit before state preparation.

Use a dedicated Keybay `appId` rather than mixing this DEK with unrelated app
secrets. Use Keybay's byte API, not its string convenience API. Never use
`deleteAll()` for local forget or recovery; ordinary logout never deletes the
DEK entry.

The core package imports `package:keybay` directly and R4a adds it to the core
pubspec at a reviewed version. There is no `tailscale_keybay` companion package
and no optional production custodian surface. The integration and its
contract/platform tests live with core.

## Keybay platform boundary

Verified against Keybay 0.1.0:

| Platform | Keybay custody | tailscale_dart policy |
| --- | --- | --- |
| iOS | Data Protection Keychain, device-only/non-syncing item policy. | Intended persistent-node adapter; real-device restart and uninstall/orphan behavior tests required. |
| Entitled macOS | Data Protection Keychain. | Intended adapter. |
| Unentitled macOS/CLI | Keybay encrypted file with its root key in login Keychain. | Intended adapter; locked/unreachable Keychain fails closed. |
| Android 12 / API 31+ | Keybay encrypted file; root key wrapped by Android Keystore, with measured StrongBox fallback. | Required persistent mechanism; API <31 does not support persistent nodes. |
| Linux desktop | Keybay encrypted file; root key in Secret Service. | Intended adapter only with available, unlocked Secret Service and `secret-tool`. |
| Headless Linux | No supported Keybay availability contract. | Persistent nodes are unsupported; ephemeral nodes remain available. Never fall back to plaintext. |
| Windows | Unsupported by Keybay and currently by tailscale_dart. | Out of scope. |

Keybay is pre-1.0 and exact-pins its cryptography dependency. Direct integration
accepts that dependency and platform contract deliberately in exchange for one
secure production path. Any future change of custody mechanism is an explicit
architecture and migration decision, not an application plug-in choice.

## Persistent-state lease

Keybay serializes mutations inside its own backend, but `read` followed by
`write` is not an atomic get-or-create operation. It also cannot coordinate its
commit with the Go ciphertext commit. A separate lease is therefore mandatory.

Given `Tailscale.init(stateDir: <stateBaseDir>, appId: <hostAppId>)`, use:

```text
<stateBaseDir>/.tailscale-state.lock
<stateBaseDir>/.tailscale-state.reset       # present only during incomplete reset
<stateBaseDir>/tailscale/                  # package-owned, deletable state root
```

The lock file and reset-intent marker are outside the deletable `tailscale/`
directory. The lock is created owner-only and its inode is never deleted or
atomically replaced during reset. The marker is a versioned, non-secret,
owner-only file created only by the reset protocol below and removed only after
the subtree deletion is durably complete.
The native layer combines:

- a process-local mutex/map keyed by the canonical state root, so isolates and
  multiple open descriptors in one process cannot bypass each other; and
- a platform-verified open-file-description/advisory exclusive lock for other
  processes (`flock` where its semantics are proven, otherwise the appropriate
  `fcntl` variant plus the process-local guard).

Unsupported lock semantics fail closed. Acquisition is nonblocking or a bounded
retry tied to the exact lifecycle context; it returns typed `stateLeaseBusy`
rather than entering an unbounded syscall. Alias/symlink and same-inode tests
prove that path spelling cannot create two in-process owners.

The lease belongs first to an opaque native preparation token and then to the
committed runtime. Process death releases the OS lock automatically.

All APIs that inspect or mutate persistent state—startup probe, status fallback,
logout, local forget, and tests—respect the same lease. Status on an active
runtime reads through that runtime rather than reacquiring its own lock. A
read-only probe while idle may use a short lease; it never bypasses a running
owner.

A fresh idle probe is allowed to create the app-owned base directory and stable
lock infrastructure. “Non-creating probe” means it creates no Keybay entry,
`tailscale/` state subtree, SQLite file, or encrypted envelope. This keeps the
probe race-free without pretending a mandatory lock file is not a write.

### Preparation and custody token protocol

The multi-phase caller/worker/Go flow is explicit:

1. Before dispatching work, the supervisor creates and retains a unique opaque
   request-generation token and installs worker-exit observation.
2. The caller isolate drives keyless preparation through short-lived helper
   isolates against token-bound native state.
   `beginPersistentPreparation(token)` binds the bounded lease for the
   already-configured canonical state root to that pre-existing token — the
   root and Keybay namespace were frozen by `init`, so the call carries no
   per-request state root or mode, and no isolate can acquire an anonymous
   reservation that rescue cannot name.
3. `inspectPersistentPreparation(token)` returns only format/presence facts.
   The supervisor marks the token's custody phase active with
   `markCustodyActive(token)` before awaiting the caller-isolate custodian
   `read` Future, then records key presence through
   `resolvePersistentCustody(token, dekPresent)`.
4. The DEK never rides a worker message. For fresh provisioning the supervisor
   marks `custodyWriteAttempted` before the custodian `write`; for either
   resolved action it stages the 32-byte key directly from the caller isolate
   into a bounded native allocation with the synchronous
   `supplyPreparedDEK(token, keyPointer, keyLength)` call, which retains
   exactly one wiped-on-consume staged copy.
5. `preparePersistentState(token)` consumes the staged key exactly once. Fresh
   provisioning resolves the empty-envelope write barrier and records the
   rename outcome on the token before any success response can be delivered;
   an existing envelope is authenticated and classified as exactly empty or
   non-empty. `completePersistentCustody(token)` then ends custody. Every
   response carries the token. A response for an abandoned generation is
   ignored and its resources are closed.
6. The long-lived worker performs only the final start: its token-qualified
   start call atomically adopts the exact prepared Store and held lease into
   the runtime candidate. An idle operation that will not start instead ends
   with `finishPreparedPersistentState(token)`.
7. Every exception, timeout, cancellation, or worker exit calls
   `abandon(token)`, never an unqualified “stop current candidate.”

Custodian Futures are not assumed cancellable. Abandoning a token quarantines
it and blocks a newer preparation, but does not release its lease while a
custody operation can still complete late. The supervisor owns that Future and
its continuation:

- a late read result is zeroed and discarded;
- before invoking a fresh-key `write`, mark `custodyWriteAttempted` on the exact
  token. A write error is possibly committed; absence of a later worker response
  is never used to guess whether the envelope committed;
- before the native write owner starts, it publishes
  `envelopeWriteInFlight` plus a `writeDone` barrier under `phaseMu`. It performs
  the write/rename, then under `phaseMu` publishes exactly one
  `envelopeCommitted` or `envelopeNotCommitted` outcome and closes `writeDone`.
  These are deliberately ordered rather than described as a nonexistent atomic
  filesystem-plus-memory action;
- `abandon(token)` may mark the token canceled during the write, but it waits
  for `writeDone` before returning a custody disposition. It retains the lease
  and returns `compensateKey` for `envelopeNotCommitted`, or
  `preserveCoherentPair` for `envelopeCommitted`. This closes the
  post-rename/pre-response race without calling `Server.Close` concurrently
  with startup;
- for `compensateKey`, the supervisor performs idempotent deletion of the exact
  custodian entry even when `write()` returned an error. For
  `preserveCoherentPair`, it never deletes the DEK and native close preserves
  the envelope. It then calls `finishCustody(token)`; only that call can release
  the retained preparation lease/admission;
- if cleanup deletion fails, the state becomes the explicit orphan-key/manual
  recovery case rather than allowing a new start;
- after the authenticated envelope commits, the key/file pair is coherent and
  later Start/worker failure preserves it according to the startup matrix
  rather than treating the DEK as orphaned;
- only after the custody Future and required cleanup settle does
  `finishCustody(token)` release preparation and permit a later generation.

An idle status probe runs the same token protocol under the same root/lease
rules and closes its no-start path with `finishPreparedPersistentState(token)`.
A reset uses the generation-bound transaction described below.

Two callers configured with the same Keybay entry but different state roots are
a host configuration error. The core Keybay binding documents and tests the
one-to-one binding.

## On-disk layout

R4d layout:

```text
  <stateBaseDir>/
    .tailscale-state.lock                  mode 0600, retained across reset
    .tailscale-state.reset                 mode 0600, incomplete-reset intent
    tailscale/                             mode 0700, package-owned
    tailscaled.state.enc                 mode 0600, encrypted StateStore
    .tailscaled.state.enc.tmp            mode 0600, transient pre-rename envelope
    tsnet/                               mode 0700, upstream runtime root
      tailscaled.log.conf                owner-only log-stream credential/config
      tailscaled.log1.txt / tailscaled.log2.txt
                                            mode 0600, sensitive upstream logs
      sockstats.log1.txt / sockstats.log2.txt
                                            mode 0600, sensitive socket logs
      certs/                             ACME/TLS sidecars when used
```

Pass `tailscale/tsnet` as `tsnet.Server.Dir` and pass the custom StateStore
explicitly. During `Server.Start`, temporarily point upstream `TS_LOGS_DIR` at
that same runtime-owned Dir using the scoped/restore protocol in the lifecycle
ADR; never leave it at the pre-cutover
`<stateBaseDir>/tailscale/logs`. The relocation groups upstream logs with the
target `tsnet` runtime root, keeps the encrypted state file distinct from
sidecars, and lets reset remove one exact package-owned subtree.

The complete `tailscale/` subtree still needs owner-only permissions and backup
exclusion because non-Kubernetes upstream TLS/log sidecars are not encrypted by
this ADR, including on any future supported mobile ACME path.

Permissions are a security invariant, not best effort. The lock and
sensitive files must have no group/other bits (`0600` target), and package-owned
directories must have no group/other access (`0700` target). Startup rejects
symlinks, unexpected file types, ownership mismatches where the platform can
inspect ownership, any existing broader mode that it cannot tighten and verify,
and any chmod/stat failure that prevents verification. A TLS/publication path
that creates a sensitive upstream sidecar performs the same post-create check
and closes/fails if it cannot obtain owner-only permissions. A platform-specific
exception requires an explicit threat-model amendment and device receipt; it is
not silently downgraded to a log message.

Legacy or conflicting artifacts include at least:

- `tailscale/state.db`, `state.db-wal`, or `state.db-shm`;
- the current `tailscale/logs/` runtime-log directory when it accompanies a
  legacy SQLite layout;
- a plaintext upstream `tailscaled.state` in either historical runtime root;
- an encrypted state file alongside any recognized legacy state format.

They are detected without opening or creating a legacy store.

## Encrypted file format

The outer file is small, versioned JSON so corruption and unsupported versions
produce deterministic errors:

```json
{
  "format": "tailscale-dart-state",
  "version": 1,
  "algorithm": "secretbox-xsalsa20-poly1305",
  "nonce": "<base64 24 bytes>",
  "ciphertext": "<base64 authenticated ciphertext>"
}
```

Version 1 uses the same primitive as Tailscale's TPM store precedent:

- 32-byte key;
- 24-byte cryptographically random nonce on every successful write attempt;
- NaCl `secretbox` (XSalsa20-Poly1305);
- an inner JSON `map[ipn.StateKey][]byte` containing all StateStore key names
  and values;
- no StateStore key name, value, per-value length, or key identifier outside
  the ciphertext.

The format/version/algorithm are not secret. The reader accepts only the exact
supported tuple; there is no downgrade or plaintext fallback. Tampering with
outer dispatch fields can cause a fail-closed denial of service but cannot make
the reader accept unauthenticated plaintext.

Version 1 requires exactly one occurrence of each listed field and rejects
duplicate fields, unknown fields, non-canonical field types, invalid base64, a
nonce not exactly 24 bytes, and ciphertext shorter than the authenticator.
Strict outer parsing prevents ambiguous parser/version behavior; future
versions get a new explicitly supported schema rather than silently adding v1
fields.

After authentication, strict inner parsing requires a non-null JSON object. It
rejects duplicate keys and rejects every entry whose decoded `[]byte` value is
nil (including JSON `null`). A present non-null zero-length value is valid and
is distinct from a missing key. The inner object is an open
`map[ipn.StateKey][]byte`, not a fixed schema: accept every valid string
StateKey, including names introduced by a later compatible upstream release.

Reject a raw envelope file larger than 24 MiB, decoded ciphertext larger than
16 MiB plus secretbox overhead, or plaintext map larger than 16 MiB. The larger
outer bound accounts for base64 expansion. These limits are deliberately far
above expected node state but bound corrupt-file resource use. Before freezing
them, record sizes from the Headscale and hosted-Tailscale lifecycle corpus;
increasing them later is backward compatible.

## StateStore contract and atomicity

The Go store:

```go
type encryptedStateStore struct {
    ipn.EncryptedStateStore

    path string
    key  [32]byte

    mu    sync.RWMutex
    cache map[ipn.StateKey][]byte
}
```

Required behavior:

- safe concurrent `ReadState` and `WriteState`;
- missing key returns exactly `ipn.ErrStateNotExist`;
- reads return a clone, never the cached slice;
- non-nil writes clone caller input;
- `WriteState(id, nil)` deletes the entry;
- writing an unchanged value is a no-op only when the key is already present
  and its non-nil bytes are equal. This comparison is presence-aware because Go
  `bytes.Equal(nil, []byte{})` is true: missing plus a non-null empty write must
  create an entry, while nil plus missing is a delete no-op;
- opening an existing file authenticates before exposing any map value;
- the store embeds `ipn.EncryptedStateStore` so upstream can identify a custom
  encrypted store where that marker is consulted;
- close wipes the cached values and key best-effort after the Server is closed.

Do not use upstream `StateEncrypted` hostinfo/telemetry as the release proof.
In v1.102.2 it is hardcoded true on iOS/Android; on Darwin it is true for Mac
App Store builds, policy-derived for system extensions, and false for ordinary
self-compiled builds; the default non-Darwin branch consults
`ipn.EncryptedStateStore`. It can therefore produce both mobile false assurance
and ordinary-macOS false negative for this architecture. Keep the marker for
upstream integration where it is consulted, but ciphertext, contract, and
persistent-file inventory tests are the security authority.

For each mutation:

1. clone the current map into a candidate map;
2. apply the write/delete to the candidate;
3. serialize the candidate;
4. generate a new nonce and encrypt;
5. exclusively create the same-directory
   `.tailscaled.state.enc.tmp`, enforce mode `0600`, fsync and close it, then
   atomically rename it over the destination;
6. treat successful rename as the commit point and immediately replace the
   in-memory cache with the candidate;
7. attempt to fsync the containing directory where supported. A failure here is
   a durability diagnostic, not a returned write failure, because the rename is
   already visible and reporting failure would leave disk-new/cache-old state.

Any error before rename leaves both the old disk file and old in-memory cache
authoritative. After rename, both the new visible file and new cache are
authoritative. With a supported successful directory fsync, crash recovery may
observe the old or new complete envelope. If directory fsync is unsupported or
fails after rename, the filesystem may instead lose the directory entry after a
crash; a remaining DEK plus missing envelope is then the explicit orphan state
and fails closed. There is no journal or rollback protection. This deliberately
avoids mutating the cache before the atomic commit while acknowledging both the
rename boundary and platform durability limit.

Fresh creation has one prerequisite before this sequence: after creating and
securing the new `tailscale/` directory, fsync its already-existing parent so
the directory entry is durable before attempting the empty-envelope commit. A
failure is pre-commit: remove the fresh directory, sync that removal, and report
`envelopeNotCommitted` so custody can compensate the DEK. The Store constructors
also require the R4c state lease; their check-then-rename no-clobber guarantee is
defined under that exclusive-owner precondition.

The fixed temporary name makes crash residue classifiable rather than leaving
an open-ended random filename family. Normal returned pre-rename failures remove
it. During R4d startup/probe, the lease owner may remove this exact path only
after proving it is a current-user-owned regular file with mode `0600`; removal
and directory-sync failure returns `atomicPersistenceFailure`. A symlink, wrong
file type, ownership/mode failure, or any other similarly named entry fails
closed as unexpected residue. The temporary envelope is never promoted during
recovery because rename is the sole commit point.

No `ExportableStore` implementation is needed because migration is out of
scope.

## Key transfer and memory handling

Key material crosses each boundary in binary form:

```text
Keybay/custodian Uint8List (32)
  -> TransferableTypedData/control message
  -> native allocation + explicit length
  -> Go [32]byte owned successively by candidate, then Store
```

Requirements:

- reject any length other than 32 before native start;
- never encode the key as UTF-8, base64, JSON, command-line data, or an
  environment variable;
- do not include it in logs, tracing, exception interpolation, crash metadata,
  or diagnostics;
- zero temporary native allocations in `finally` before freeing;
- zero mutable Dart buffers and Go copies best-effort as soon as ownership
  transfers or the runtime closes;
- zero the authenticated plaintext JSON buffer after unmarshal and the marshaled
  plaintext buffer immediately after sealing, both best-effort;
- keep one long-lived Go copy only in the StateStore and only while it is open;
- document that managed runtimes and compiler copies prevent a hard erasure
  guarantee.

The auth key is a separate enrollment secret and should receive the same
no-log/bounded-lifetime review, but upstream's API accepts it as text. Transfer
it through its own bounded UTF-8 buffer, never through the binary DEK path, and
zero temporary buffers best-effort. Package code does not store the auth key in
this envelope; upstream writes resulting node state through StateStore.

## Non-creating probe and startup matrix

Probe filesystem format while holding the lease, before reading or creating a
key and before `Server.Start`. Opening a status view may create the app-owned
base directory and stable lock file, but must not create the `tailscale/` state
subtree, database, Keybay entry, or empty encrypted file.

Classification precedence is fixed:

1. Any directory entry at `.tailscale-state.reset` takes precedence over every
   key/file combination and returns `localResetIncomplete`; malformed content,
   a wrong file type, a symlink, or unverifiable ownership/mode is retained as a
   non-secret cause. Startup never follows it, resumes it, or completes a
   destructive transaction automatically.
2. Under the lease, inspect path metadata and return legacy/conflict/malformed
   format errors that do not require decryption. Do not call the custodian for a
   recognized legacy/conflict-only root.
3. A present `tailscale/` subtree with no recognized state format is
   `unexpectedStateResidue`, not fresh state, even if it contains only logs or
   an empty directory.
4. Only for a canonical absent/encrypted layout, read the custodian and classify
   absent/orphan/missing-key/custody errors.
5. Only with an encrypted file and valid DEK, authenticate and classify the
   inner map as exactly empty or non-empty.

This ordering makes a locked custodian irrelevant to a root that already needs
explicit legacy reset and gives every overlapping failure one deterministic
error.

| Filesystem classification | Encrypted file | Custodied DEK | Result |
| --- | --- | --- | --- |
| reset marker present | any | not read | `localResetIncomplete`. Refuse startup; only explicit `forgetLocalIdentity()` may resume the already-authorized reset transaction. |
| unrecognized residual `tailscale/` subtree | absent | not read | `unexpectedStateResidue`. Refuse startup; explicit local reset may remove it. |
| clean root: subtree/marker absent | absent | absent | Fresh. Idle `status()`/`logout()` report `noState` without creating custody or the state subtree. Persistent `up()` creates the DEK and authenticated empty envelope, then starts with a supplied auth key or upstream interactive login. |
| clean root: subtree/marker absent | absent | valid | Orphaned key, including a crash or reinstall edge. Refuse startup; explicit local reset may delete it. Do not silently reuse or overwrite it. |
| canonical secure root | valid and exactly empty | valid | Interrupted/fresh provisioning. Idle inspection reports `noState`; persistent `up()` opens the pair and lets upstream use a supplied auth key or enter interactive login. |
| canonical secure root | valid and non-empty | valid | Persisted upstream state, but not proof of completed enrollment. Open and start. Pass any caller-supplied auth key to the new Server and let upstream decide whether to use or ignore it; never wipe locally. |
| canonical secure root | canonical encrypted file | absent | Lost DEK. Fail closed; explicit local reset is the only local recovery. |
| canonical secure root | malformed or unsupported outer envelope | not read | Return the typed format error before custody and never start empty. |
| canonical secure root | canonical envelope with authentication failure | valid | Corrupt, wrong-key, or tampered state. Fail closed and never start empty. |
| recognized legacy root | absent | not read | `LegacyStateUnsupported`. No migration and no automatic deletion. |
| recognized legacy root | present | not read | `ConflictingStateFormats`. Fail closed. |
| canonical absent/encrypted root | absent or canonical encrypted | custodian error or non-32-byte value | Fail before native launch. Make no StateStore mutation. If a fresh-key write was attempted, run token-qualified compensating delete because the error may have followed a commit. |

“Valid and exactly empty” means a successfully authenticated v1 envelope whose
logical map has zero entries other than the package-owned runtime metadata key
below. `logicalEmpty` ignores exactly that one key; similarly named and future
upstream keys remain authoritative state. It is distinct from a missing or
zero-byte file. Do not classify enrollment from `_machinekey`: upstream may
generate a machine key before node/profile enrollment completes. Non-empty
state is only a signal to let upstream resume its own state machine.

### Package-owned runtime metadata

The store keeps one package-owned key inside the authenticated envelope:
`_tailscale-dart/runtime-config`, a bounded (64 KiB) strict-JSON record
`{version, hostname, controlURL, ephemeral}` at version 1. It is deliberately
outside the upstream key namespace and is the only key excluded from the
exactly-empty classification, so idle `status()` and `logout()` classify a
metadata-only envelope as `noState`.

Its lifecycle is bound to the `Server.Start` proof boundary of persistent
runtimes; ephemeral runtimes never write it:

- before a new start may mutate upstream state, the prior tuple is deleted
  with a direct nil `WriteState`, so idle logout can never reconstruct
  possibly-mutated state under a stale configuration;
- only after `Server.Start` returns success is the proven
  `{hostname, controlURL, ephemeral: false}` tuple written; a metadata write
  failure fails that start.

Idle logout on an authenticated non-empty envelope reconstructs its minimum
runtime from this record, not from caller-supplied configuration. Reading is
strict: absence surfaces as `ipn.ErrStateNotExist`, while a duplicate,
unknown, missing, or wrongly typed field, an unsupported version, or an
`ephemeral: true` record is a typed metadata error. If the record is absent or
invalid beside non-empty upstream state — for example after a crash between
the pre-start clear and the post-start save — idle logout fails with that
typed error instead of constructing a runtime. This is fail-closed rather than
terminal: the next successful `up()` re-proves and rewrites the tuple.

Fresh provisioning is an intentionally cross-system transaction:

1. acquire lease;
2. prove no state and no key;
3. generate DEK;
4. write DEK to the custodian;
5. create the encrypted empty envelope;
6. open Store and start Server.

Mark the token before step 4. Any step-4 error can still mean that the backend
committed. Native publishes `envelopeWriteInFlight` before step 5;
`abandon(token)` waits for the write owner to record the rename result and close
`writeDone`. `envelopeNotCommitted` yields `compensateKey`, so the supervisor
runs idempotent DEK deletion under the retained lease and reports the original
plus any cleanup error. A successful rename yields `preserveCoherentPair` even
when the worker dies before response delivery, so rescue cannot strand valid
ciphertext by deleting its key. A whole-process crash between steps 4 and 5 can bypass
supervisor compensation and produces the orphaned-key state above; explicit
reset is required rather than guessing. Once step 5 commits, later lifecycle
failure preserves the coherent empty-envelope/key pair for an explicit retry or
reset.

## `status`, `down`, `logout`, and reset

### Idle operation matrix

This matrix is the final R4d behavior when no runtime is active. If a runtime is
active, `logout()` always follows the remote-first protocol below; it does not
substitute an idle-file inference for upstream authority. Both public operations
return `Future<void>`, so “completes” below means normal completion rather than
returning a `noState` value.

| Secure classification | Idle `status()` | `logout()` | `forgetLocalIdentity()` |
| --- | --- | --- | --- |
| Reset marker present, with any key/subtree combination | `localResetIncomplete` | Throws `localResetIncomplete`; no Server or remote call. | Resumes the marker-owned transaction: idempotent exact-DEK deletion, exact subtree removal, then marker removal. |
| Unrecognized residual subtree, no marker | `unexpectedStateResidue` without custody read | Throws `unexpectedStateResidue`; no remote call or mutation. | Creates the durable marker, then idempotently deletes the exact DEK and owned subtree. |
| State subtree and marker absent, DEK absent | `noState` | Completes; no Server, remote call, custodian mutation, or subtree deletion. | Completes as an idempotent no-op. |
| Authenticated exactly-empty envelope plus DEK | `noState` | Completes; no remote call or deletion, and preserves the pair. Makes no claim that a remote device record was never created or was revoked. | Warns that a remote record may remain, then deletes the DEK and owned subtree. |
| Authenticated non-empty envelope plus DEK | stopped with persisted state | Constructs/reuses the minimum runtime from the package-owned runtime metadata and performs upstream logout. Absent/invalid metadata beside this non-empty state throws its typed metadata error without constructing a runtime; a later successful `up()` rewrites the tuple. Confirmed success preserves the DEK and upstream-mutated encrypted store, then reports `noState`; failure/timeout closes the mutated generation, preserves the same storage pair as recovery evidence, and throws `logoutIndeterminate`. | Warns that a remote record may remain, then deletes the DEK and owned subtree without a remote call. |
| Orphan DEK, no envelope | `orphanedDek` | Throws `orphanedDek`; no remote call or automatic deletion. | Idempotently deletes the exact DEK, then removes the exact owned subtree if present. |
| Canonical encrypted file, DEK absent | `missingDek` | Throws `missingDek`; no remote call or automatic deletion. | Performs idempotent DEK deletion/absence confirmation, then removes the owned subtree. |
| Malformed/unsupported envelope or authenticated-open failure | the exact format/authentication error | Throws the same typed error; no remote call or automatic deletion. | Deletes the exact DEK first, then removes the owned subtree. A malformed outer envelope is not opened merely to reset it. |
| Recognized legacy-only layout | `legacyStateUnsupported` without custody read | Throws `legacyStateUnsupported`; no remote call or mutation. | Invokes idempotent exact-DEK deletion, then removes the package-owned legacy subtree, including SQLite/WAL/SHM and legacy logs. |
| Legacy plus encrypted conflict | `conflictingStateFormats` without custody read | Throws `conflictingStateFormats`; no remote call or mutation. | Invokes idempotent exact-DEK deletion, then removes the entire conflicting package-owned subtree. |
| Custodian unavailable/error/non-32-byte result for an otherwise canonical layout | the exact custodian/DEK error | Throws the same typed error; no remote call or filesystem mutation. | Attempts exact-entry deletion. If custody cannot confirm deletion, throws `localResetIncomplete` and preserves the entire filesystem subtree. |

For every destructive row, reset retains the external lease and closes any
runtime/Store first. It then executes this ordered, retry-safe protocol:

1. atomically create/replace the versioned `.tailscale-state.reset` marker at
   mode `0600`, sync the file and base directory, and verify it before mutating
   custody; if durable intent cannot be confirmed, stop without deleting
   anything;
2. call only the exact custodian entry's idempotent `delete` and confirm success;
   it never calls `deleteAll()`;
3. remove exactly `<stateBaseDir>/tailscale/` using root-confined,
   no-symlink-following traversal, then sync the base directory;
4. remove the marker and sync the base directory again; only then publish
   success/`noState` and release admission.

Any failure or process death after step 1 leaves the durable marker. Startup and
ordinary logout fail with `localResetIncomplete`; a later explicit local forget
repeats steps 2–4 idempotently. This remains retryable whether deletion stopped
before the envelope, after the envelope but before a log/sidecar, after the
whole subtree, or while removing the marker. If key deletion fails, the
filesystem and marker are preserved. The stable external lock remains in every
case. State is considered absent only when the marker and complete owned
subtree are both absent.

A no-op logout updates any stale cached view so a later `status()` is truthful,
but it need not synthesize a duplicate `noState` stream event when the public
state is already `noState`.

### Status / HasState

R4d replaces the pre-cutover creating `HasState` behavior with an asynchronous,
non-mutating secure probe:

- any reset-marker entry means `localResetIncomplete`, with no automatic
  continuation;
- a residual package-owned subtree without recognized state means
  `unexpectedStateResidue`;
- no package-owned subtree/marker plus no custodied key means `noState`;
- no recognized state file plus a custodied key is the orphan-key error from
  the startup matrix, not `noState`;
- an encrypted file requires the configured Keybay binding and successful
  authentication before classifying it as exactly empty or non-empty;
- an authenticated empty map means `noState`;
- an authenticated non-empty map means persisted state exists, not that the
  node is enrolled. While idle, report a stopped/persisted-state condition and
  let the next upstream start produce authoritative Running/NeedsLogin/
  NeedsMachineAuth state;
- legacy, conflict, missing-key, or corrupt states are surfaced as typed errors,
  not collapsed to `noState`.

### Down

`down()` closes the Server and Store, wipes in-memory key copies, and releases
the lease. It preserves the encrypted file and Keybay DEK for reconnect.

### Successful logout

After upstream remote logout succeeds:

1. upstream has already removed the current profile through the ordinary
   `StateStore.WriteState(..., nil)` contract and persisted any logged-out
   structural state it intentionally retains;
2. detach and close the runtime, then wipe its in-memory DEK copy and release
   the state lease;
3. preserve the Keybay DEK, authenticated envelope, and package-owned subtree;
4. publish `noState` from the confirmed upstream result.

Logout never creates a reset marker and never calls Keybay `delete`. The DEK is
an application-installation storage key, not a Tailscale login-session key.
Reusing it for a later enrollment is cryptographically sound because every
envelope write uses a fresh nonce. It also matches upstream's behavior: logout
deletes the current profile but retains the StateStore backend so a restarted
client remains authoritatively logged out.

If the worker exits after native completion but before delivering the result,
R3's retained lifecycle receipt returns the same confirmed `noState`
disposition. If runtime close fails, lifecycle admission remains poisoned; that
is a resource-cleanup failure, not a key/file reset transaction.

### Failed remote logout

Do not perform package-controlled deletion of the DEK or encrypted state files.
Return an **indeterminate** upstream failure: the remote request may have
succeeded even though the response failed, and upstream mutates some in-memory
logout state before it knows the result. Treat the retained local data as
recovery evidence, not a guarantee that it is unchanged or still valid. Detach
and close the potentially mutated runtime with ordinary state retention before
returning. A later fresh upstream start reconciles actual control-plane/profile
state. Fault injection must prove close/reopen reconciliation; the API does not
promise that repeating `logout()` is safe or meaningful.

### Local forget

The explicitly destructive `forgetLocalIdentity()` path uses the same
generation-bound, durable-intent-then-key-first reset transaction without
claiming remote revocation. It never calls Keybay `deleteAll()`.

If Keybay itself is corrupt or unavailable and cannot delete the entry, retain
the ciphertext and return an incomplete/manual-recovery error. Do not claim
success merely because files were removed.

## Full persistent-file inventory

Encrypting `ipn.StateStore` is not whole-directory encryption.

On non-Kubernetes builds, including a mobile ServeConfig path if it successfully
uses ACME, upstream handling can persist:

- `tsnet/certs/acme-account.key.pem` at mode `0600`;
- `tsnet/certs/<domain>.key` at mode `0600`;
- the corresponding public certificate;
- `tsnet/tailscaled.log.conf`, which includes a private log-stream credential;
- `tsnet/tailscaled.log1.txt`, `tailscaled.log2.txt`,
  `sockstats.log1.txt`, and `sockstats.log2.txt`, plus other logs that can contain
  sensitive operational data such as authentication URLs and socket metadata;
- other non-StateStore metadata under the runtime root.

The accurate release claim is:

> The Tailscale StateStore is authenticated and encrypted with a key held by
> Keybay. Other upstream runtime files are inventoried
> separately and may rely on owner-only permissions and backup exclusion.

For any supported TLS/Serve/Funnel path in the first secure-state release:

- retain upstream-compatible owner-only sidecars;
- require the full package-owned state subtree to remain backup-excluded;
- document their residual risk explicitly;
- add tests that identify every created file after TLS/Funnel use;
- pursue an upstream-supported cert-store hook or upstream change if we need
  those keys protected by the encrypted StateStore.

Do not spoof Kubernetes detection to reach upstream's StateStore-backed cert
path. That would couple security to an unrelated environment heuristic.

On iOS and Android, the LocalAPI certificate endpoint is compiled out, so the
current `tls.bind` certificate callback cannot complete its handshake. R5 has
replaced package Funnel with ServeConfig/`AllowFunnel`; that path does not use
the same package-side certificate call and is therefore **unqualified**, not
proven impossible. It must pass real-device Serve/Funnel handshakes and the
same sidecar inventory before support is claimed. `tls.bind` still needs an
alternate certificate path.

## Backup-exclusion ownership and receipts

Core can create and verify owner-only paths, but a cross-platform Dart/Go
library cannot universally select the host application's container, rewrite its
Android backup manifest, or configure the operator's backup product. Backup
exclusion is therefore an explicit **host-application security precondition**,
not an unconditional package claim. R6 owns first-party example integration,
documentation, and executable receipts; the embedding app/operator owns the
actual policy.

Required receipts are:

- **iOS and macOS:** place the exact package-owned persistent root (or its
  containing dedicated state directory) in a non-backed-up container, or set
  `NSURLIsExcludedFromBackupKey`; read the resource value back for the exact
  resolved root during preparation and in the example/device test. Reapply and
  reverify after operations that recreate/move the directory because Apple
  documents that common file operations can reset the value. Apply the same
  rule to the chosen ephemeral scratch parent.
- **Android:** place the root under `Context.noBackupFilesDir`, or add explicit
  `dataExtractionRules` and legacy `fullBackupContent` exclusions for the exact
  relative subtree across cloud backup and device-to-device/cross-platform
  transfer sections that the app enables. The example instrumentation receipt
  asserts the resolved directory choice or packaged manifest rules and
  exercises configuration on API 31+ and the API 30-and-lower legacy family.
  Ephemeral scratch uses a cache/no-backup location.
- **Linux/headless/custom hosts:** there is no universal API. The operator must
  document the exact exclusion in the real backup tool. CI can verify only
  resolved paths, modes, and the complete file inventory, so release docs retain
  this residual obligation instead of asserting automatic exclusion.

Support/security wording is conditional on those receipts. A release may say
the StateStore is encrypted independently of backup policy, but may say the
runtime subtree is backup-excluded only for a host integration that supplied and
verified the relevant platform policy.

## Failure taxonomy

The Dart surface should expose stable, non-secret error codes/types for at
least:

- Keybay unavailable/locked/busy;
- invalid DEK length;
- orphaned DEK;
- missing DEK for existing ciphertext;
- legacy state unsupported;
- conflicting state formats;
- unexpected residual package state with no recognized StateStore;
- unsupported envelope version/algorithm;
- malformed/truncated state;
- ciphertext authentication failure;
- state lease busy;
- atomic persistence failure;
- `logoutIndeterminate` for a possibly-completed remote logout whose generation
  was closed while evidence was retained;
- `localResetIncomplete` whenever the durable reset marker remains, including
  custodian deletion, partial subtree deletion, or final marker cleanup failure;
- unsupported persistent storage on the current platform.

Preserve typed Keybay causes where useful—locked/busy can be retryable, while
wrong key, invalidated key, or corrupt container require explicit recovery—but
do not expose the DEK, StateStore values, or auth key.

## Verification and acceptance gates

### StateStore contract

- missing read returns `ipn.ErrStateNotExist`;
- empty non-nil value round-trips distinctly from missing;
- one combined regression writes a non-null empty value, writes nil, reopens,
  and receives `ipn.ErrStateNotExist`;
- nil against a missing key is a no-op; empty against a missing key creates it;
- input and output mutation cannot alter cached state;
- unchanged write does not rewrite the file;
- concurrent readers/writers pass `go test -race`;
- reopen produces the identical logical map;
- store embeds the encrypted marker;
- close occurs after Server close and wipes mutable caches best-effort.

### Cryptography and file handling

- known secretbox vectors and round trips;
- fresh random nonce per write;
- wrong key, bit flip, truncated JSON/base64/ciphertext, nonce-length error,
  unsupported version, duplicate/unknown **outer fields**, duplicate inner
  keys, null inner map, null/non-byte inner value, non-canonical field type, and
  oversize input all fail closed; arbitrary valid string StateKeys are accepted;
- file is mode `0600`, parent directories `0700`; precreate broader modes,
  symlinks, wrong file types, ownership mismatches where inspectable, and
  chmod/stat failures, and prove startup fails closed unless it can tighten and
  verify owner-only access;
- fresh-directory creation fsyncs its parent before envelope commit; injected
  parent-sync failure durably removes the uncommitted directory;
- crash/fault injection before write, after temp write, after fsync, and before
  rename leaves the prior disk/cache state authoritative;
- a returned pre-rename error removes `.tailscaled.state.enc.tmp`; simulated
  crash residue has that one exact name and follows the verified R4d cleanup
  rule above;
- fault injection immediately after rename proves the new disk/cache state is
  authoritative even if directory fsync reports a durability diagnostic;
- simulated crash/lost directory entry after unsupported/failed directory fsync
  reopens as an orphan-key error, never as a silent fresh identity;
- a returned pre-rename persistence failure does not alter the in-memory
  authoritative cache;
- replaying an older valid envelope under the stable DEK succeeds and is
  documented as the explicit v1 anti-rollback limitation;
- decrypted and marshaled plaintext scratch buffers are wiped best-effort at
  their documented ownership transitions;
- plaintext fixture secrets and StateStore key names do not appear in the
  encrypted file or logs.

### Custody and lease

- the core Keybay binding uses the exact dedicated appId/entry/label contract;
- missing, locked, busy, corrupt, invalidated, and non-32-byte read responses map
  to the correct failure with no StateStore mutation; only permitted owner-only
  base/lock coordination infrastructure may have been created;
- every fresh-key write error is treated as possibly committed. Fault-inject
  worker exit before, during, and after rename and after rename but before
  response delivery; `abandon(token)` waits on `writeDone` and returns
  `compensateKey` only for the recorded not-committed outcome, otherwise
  `preserveCoherentPair`;
- the process-local keyed admission guard prevents two isolates/descriptors from
  preparing one canonical root, and the OS advisory lock prevents a second
  process; path aliases/symlinks cannot create a second owner;
- lease acquisition is bounded/nonblocking and returns `stateLeaseBusy`;
- a crash releases the OS lease, while normal reset does not replace its inode;
- worker death during Keybay read/write quarantines the exact supervisor-owned
  token and retains admission until that non-cancellable Future plus any
  late-write compensation has settled;
- a late newly generated key write is deleted under the retained lease; cleanup
  failure leaves an explicit orphan/manual-recovery result;
- reset delete success/error arriving after timeout or worker exit retains
  draining/admission until exact subtree removal or manual-recovery disposition;
- DEK buffers never enter string FFI, JSON messages, environment variables, or
  captured test logs; auth-key UTF-8 uses its separate bounded, no-log path;
- iOS, macOS, Android API 31+, and Linux desktop restart receipts use the real
  Keybay backend, not only a fake.

### State matrix and lifecycle

- every row in the no-migration table is a named test;
- every row in the idle-operation matrix asserts `Future<void>` completion or
  exact error, remote-call count, key/file mutations, later status, and remote
  record warning;
- fault-inject explicit local forget before/after marker sync, DEK deletion, removal of the
  envelope, every sidecar/log removal boundary, subtree sync, marker removal,
  and final sync. Before durable marker commit nothing is deleted; afterward
  every restart reports `localResetIncomplete` until explicit local forget
  idempotently reaches marker/subtree/key absence;
- a fresh probe may create only the owner-only base/lock coordination
  infrastructure; it makes no custodian, StateStore-subtree, SQLite, or envelope
  write;
- crash after key write/before envelope is reported as orphan, not fresh;
- successful enrollment then process restart preserves the stable node ID;
- `down`, successful logout, and remote logout failure preserve the StateStore
  container and DEK; only explicit local forget follows
  durable-intent-then-key-first deletion;
- inject remote-logout timeout after possible remote success, then close/reopen
  and reconcile without promising the retained profile is unchanged or
  automatically retryable;
- inject logout failures before local preference mutation, after it, and after
  remote success with response loss; no indeterminate path leaves the mutated
  runtime current;
- a new auth key never triggers local deletion or forced identity replacement,
  and exact-empty, arbitrary non-empty, and machine-key-only states all pass a
  caller-supplied auth key to upstream on a fresh runtime;
- ephemeral startup requires an auth key, never touches the custodian or
  persistent StateStore, rejects filesystem-visible occupied persistent roots,
  deliberately ignores a custodian-only orphan, and sweeps stale scratch only
  after a nonblocking per-directory live-lock check;
- no SQLite package, database, WAL/SHM artifact, or code path remains.

### Broader storage inventory

- capture a complete relative file listing after fresh start, reconnect,
  HTTP/TCP/UDP, desktop TLS, Serve, Funnel, down, logout, and crash recovery;
- classify every file as encrypted secret, owner-only residual secret, public
  certificate, log, metadata, or lock;
- assert `0700` runtime/log directories and `0600` log/config files rather than
  assuming upstream creation preserved the intended modes;
- assert that `tailscaled.log.conf` is treated as credential-bearing and that
  logs/authentication URLs are handled as sensitive even when no StateStore
  plaintext marker is present;
- prove the temporary `TS_LOGS_DIR` override places both tailscaled and
  sockstats files under the persistent runtime Dir or ephemeral scratch,
  restores the host environment exactly, and leaves no old
  `<stateBaseDir>/tailscale/logs` path after reset;
- prove ephemeral close/safe stale sweep removes its logs and persistent reset
  removes every runtime log while retaining only the external lock file;
- fail CI if a known plaintext node-StateStore marker appears outside the
  encrypted envelope;
- never treat upstream `StateEncrypted` telemetry as evidence that these checks
  passed;
- verify the exact Apple exclusion resource value, Android no-backup location or
  packaged backup rules, and ephemeral scratch policy in first-party example
  apps; on Linux/custom hosts, record the operator-owned exclusion and the
  residual that CI cannot configure it;
- keep `tls.bind` unsupported on mobile until an alternate certificate path
  passes; and keep R5 ServeConfig Funnel/HTTPS Serve unqualified until full
  real-device handshakes and their sidecar inventory pass.

### Performance

StateStore writes are control-plane events, not a data-plane hot path. Record:

- encrypted-store open/read/write latency and file size;
- startup and reconnect time with a real Keybay backend;
- allocation/peak-memory behavior at the 16 MiB cap;
- repeated start/down handle counts.

The goal is bounded and negligible lifecycle overhead, not a SQLite comparison
contest. Do not add caching or batching without a measured failure against a
documented startup/write budget.

## Rollout

Because the package is pre-launch, rollout is a clean cut after the runtime and
fail-safe foundations. R4a through R4d are implemented together in the current
source; the numbered list retains their review order and the remaining R6 gate:

1. **R4a:** add Keybay directly to core, require the stable host application
   identifier, bind the dedicated DEK entry, and add package-internal fake
   backend tests.
2. **R4b:** land the encrypted Store unwired with the reusable Go contract/fault
   matrix.
3. **R4c:** add native admission/lease and extend R3's supervisor-owned tokens
   with custody quarantine, the `envelopeWriteInFlight`/`writeDone` disposition
   barrier, and binary DEK FFI.
4. **R4d:** switch persistent startup/status/logout/forget/reset and ephemeral
   in-memory/scratch behavior atomically, then delete SQLite source, dependency,
   `DuneHasState`, and artifact assumptions. Verify superseded PR #86 was closed
   after R0 and replacement R4 tracking were linked; do not defer closing it to
   cutover. No standalone SQLite correction or query probe lands first.
5. **R6:** after R5 publication convergence, run Headscale persistence, real
   platform-Keybay, crash, fail-closed permission, platform backup-exclusion,
   and plaintext/sidecar-inventory gates.
6. Keep current-source docs on the exact encrypted StateStore behavior, but do
   not publish broader platform/security support claims until the corresponding
   release receipts pass.

Do not ship an intermediate release that can create both SQLite and encrypted
state or that falls back to plaintext when custody fails.

## Alternatives rejected

- **Use upstream FileStore unchanged.** Simple and conformant, but plaintext and
  cloneable from a copied directory.
- **Encrypt FileStore values.** Leaks map structure and adds an unnecessary
  storage layer.
- **Store one encrypted blob inside FileStore.** Still requires our own logical
  StateStore and makes atomic/cache semantics harder to reason about.
- **Encrypt SQLite.** Retains a database and native dependency for a tiny map,
  requires a separate encryption solution, and creates WAL/key-management
  complexity.
- **Optional custodian interface and Keybay companion.** Preserves custom and
  headless provider flexibility, but creates multiple production security paths
  and makes the supported mobile setup look optional. Persistent support now
  deliberately follows Keybay's verified platform contract instead.
- **Pass a Keybay secret into Go as text.** Creates avoidable encoded copies and
  logging/error hazards.
- **Keep the DEK beside ciphertext.** Provides obfuscation, not protection from
  copied state.
- **Silently reset on missing/wrong key.** Converts recoverable security signals
  into a new identity and can leave the old remote node valid.
- **Migrate SQLite.** The user has explicitly chosen a pre-launch clean cut;
  migration adds code and rollback surface that should never ship.
- **Encrypt the whole tsnet directory by claiming StateStore coverage.** False:
  upstream non-Kubernetes ACME keys and credential-bearing logs bypass
  StateStore.

## References

- [Tailscale StateStore contract](https://github.com/tailscale/tailscale/blob/v1.102.2/ipn/store.go)
- [Tailscale FileStore](https://github.com/tailscale/tailscale/blob/v1.102.2/ipn/store/stores.go)
- [Tailscale TPM encrypted StateStore](https://github.com/tailscale/tailscale/blob/v1.102.2/feature/tpm/tpm.go)
- [Tailscale atomic file writer](https://github.com/tailscale/tailscale/blob/v1.102.2/atomicfile/atomicfile.go)
- [Tailscale secure node state storage](https://tailscale.com/docs/features/secure-node-state-storage)
- [Tailscale ACME certificate storage](https://github.com/tailscale/tailscale/blob/v1.102.2/feature/acme/certstore.go)
- [Tailscale log-directory policy](https://github.com/tailscale/tailscale/blob/v1.102.2/logpolicy/logpolicy.go)
- [Tailscale sockstat log files](https://github.com/tailscale/tailscale/blob/v1.102.2/log/sockstatlog/logger.go)
- [Upstream `StateEncrypted` reporting](https://github.com/tailscale/tailscale/blob/v1.102.2/ipn/ipnlocal/local.go)
- [Mobile-disabled LocalAPI certificate endpoint](https://github.com/tailscale/tailscale/blob/v1.102.2/ipn/localapi/disabled_stubs.go)
- [Apple `isExcludedFromBackupKey`](https://developer.apple.com/documentation/foundation/urlresourcekey/isexcludedfrombackupkey)
- [Android Auto Backup and data-extraction rules](https://developer.android.com/identity/data/autobackup)
- [Keybay repository and platform security design](https://github.com/danReynolds/keybay)
