package tailscale

import (
	"context"
	"errors"
	"fmt"
	"net"
	"reflect"
	"strconv"
	"sync"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
)

const (
	maxServeConfigMutationAttempts = 3
	publicationDeliveryAckTimeout  = 30 * time.Second
)

// ErrServeConfigConflict means every bounded ServeConfig attempt lost its
// ETag race. The operation is known not to have applied.
var ErrServeConfigConflict = errors.New("tailscale serve config conflict")

// ErrPublicationNotApplied marks a publication operation that conclusively
// failed before its ServeConfig mutation could apply. The wrapped cause keeps
// the more specific LocalAPI classification available to callers.
var ErrPublicationNotApplied = errors.New("tailscale publication not applied")

// ErrPublicationCommitIndeterminate means SetServeConfig may have applied but
// its result was lost. Callers must quarantine the exact runtime generation
// before returning the error across FFI.
var ErrPublicationCommitIndeterminate = errors.New("tailscale publication commit indeterminate")

// publicationLocalClient is the narrow LocalAPI surface owned by one runtime's
// publication manager. Production always supplies the cached LocalClient from
// nodeRuntime; the interface keeps mutation and response-loss behavior
// deterministic in tests without constructing another client.
type publicationLocalClient interface {
	StatusWithoutPeers(context.Context) (*ipnstate.Status, error)
	GetServeConfig(context.Context) (*ipn.ServeConfig, error)
	SetServeConfig(context.Context, *ipn.ServeConfig) error
}

// publicationKey is unique inside one node identity. A nodeRuntime has one DNS
// name, so keeping the host on the record (rather than the key) lets an exact
// stale-handle close be rejected without a LocalAPI status round trip.
type publicationKey struct {
	port uint16
	path string
}

type publicationVariant struct {
	handler *ipn.HTTPHandler
}

// publicationMapping records the configurations that a package mutation may
// own at one coordinate. Normally variants has one entry. An indeterminate
// replacement retains both the prior and attempted variants so runtime close
// can remove whichever one actually committed without deleting an unrelated
// external replacement.
type publicationMapping struct {
	host     string
	token    uint64
	variants []publicationVariant
}

type publicationPortKey struct {
	host string
	port uint16
}

// publicationVisibility is separate from path-handler ownership because
// AllowFunnel is host:port scoped. The latest forward on any path owns that
// policy. funnel means this token may own an enabled bit; the conservative
// "may" is needed only after an indeterminate replacement.
type publicationVisibility struct {
	token    uint64
	funnel   bool
	evidence []publicationVisibilityEvidence
}

// publicationVisibilityEvidence binds a possible port-level policy to the
// exact handler state installed by the same mutation. It lets teardown
// distinguish package-owned Funnel visibility from a later external handler
// replacement, which must be preserved together with its visibility choice.
type publicationVisibilityEvidence struct {
	key     publicationKey
	handler *ipn.HTTPHandler
	funnel  bool
}

// pendingPublicationDelivery keeps native ownership of a committed mapping
// until the caller isolate confirms that it received and validated the exact
// generation/token handle. The timer is a fail-safe for helper/caller isolate
// or result-port loss, where Dart cannot run its explicit compensation path.
type pendingPublicationDelivery struct {
	generation   uint64
	mappingToken uint64
	timer        *time.Timer
}

// publicationManager is the sole Serve/Funnel authority for one nodeRuntime.
// Its mutex serializes the complete get/copy/apply/ETag-set transaction and
// protects mapping tokens. Runtime teardown acquires the same mutex, so a
// mutation either becomes teardown-owned or observes the closed runtime; it
// cannot commit behind the cleanup sweep.
//
// R5 bootstrap state is intentionally added to this runtime-owned object by
// publication_bootstrap.go. Publication APIs never create another LocalClient
// or another bootstrap authority.
type publicationManager struct {
	runtime   *nodeRuntime
	client    publicationLocalClient
	bootstrap *publicationBootstrap

	mu               sync.Mutex
	closed           bool
	nextMappingToken uint64
	mappings         map[publicationKey]publicationMapping
	visibility       map[publicationPortKey]publicationVisibility
	pendingDelivery  map[uint64]*pendingPublicationDelivery
	deliveryTimeout  time.Duration
	onDeliveryLoss   func(*nodeRuntime, error)

	// These are fixed to upstream typed classifiers in production. Keeping
	// them on the manager avoids process-global test hooks.
	isPreconditionsFailed func(error) bool
	isKnownNotApplied     func(error) bool
}

func newPublicationManager(runtime *nodeRuntime, client *local.Client) *publicationManager {
	return newPublicationManagerWithClient(runtime, client)
}

func newPublicationManagerWithClient(runtime *nodeRuntime, client publicationLocalClient) *publicationManager {
	return &publicationManager{
		runtime:         runtime,
		client:          client,
		bootstrap:       newPublicationBootstrap(runtime),
		mappings:        make(map[publicationKey]publicationMapping),
		visibility:      make(map[publicationPortKey]publicationVisibility),
		pendingDelivery: make(map[uint64]*pendingPublicationDelivery),
		deliveryTimeout: publicationDeliveryAckTimeout,
		onDeliveryLoss: func(runtime *nodeRuntime, cause error) {
			_ = quarantinePublicationDeliveryFailure(runtime, cause)
		},
		isPreconditionsFailed: local.IsPreconditionsFailedError,
		isKnownNotApplied:     local.IsAccessDeniedError,
	}
}

func (m *publicationManager) forward(ctx context.Context, payload serveForwardPayload) (servePublication, error) {
	if m == nil {
		return servePublication{}, notAppliedError(errors.New("publication manager is unavailable"))
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	if err := m.requireCurrentLocked(); err != nil {
		return servePublication{}, notAppliedError(err)
	}
	if err := contextBeforeDispatch(ctx); err != nil {
		return servePublication{}, notAppliedError(err)
	}
	status, err := m.client.StatusWithoutPeers(ctx)
	if err != nil {
		return servePublication{}, notAppliedError(m.runtime.resultError(err))
	}
	if err := m.runtime.validateCurrent(); err != nil {
		return servePublication{}, notAppliedError(err)
	}

	token, err := m.nextTokenLocked()
	if err != nil {
		return servePublication{}, notAppliedError(err)
	}

	var (
		publication servePublication
		attempted   publicationMapping
	)
	err = m.mutateLocked(ctx, true, func(sc *ipn.ServeConfig) (bool, error) {
		var applyErr error
		publication, applyErr = applyServeForward(sc, status, payload)
		if applyErr != nil {
			return false, applyErr
		}
		publication.Generation = m.runtime.generation
		publication.MappingToken = token
		attempted, applyErr = mappingFromPublication(sc, publication, token)
		if applyErr != nil {
			return false, applyErr
		}
		return true, nil
	})

	key := publication.key()
	visibilityKey := publicationPortKey{host: attempted.host, port: key.port}
	switch {
	case err == nil:
		if prior, ok := m.mappings[key]; ok {
			m.cancelPendingDeliveryLocked(prior.token)
		}
		m.mappings[key] = attempted
		m.visibility[visibilityKey] = publicationVisibility{
			token:    token,
			funnel:   publication.Funnel,
			evidence: visibilityEvidence(key, attempted, publication.Funnel),
		}
		// SetServeConfig is confirmed, but teardown may have detached this
		// runtime while the request was in flight. Keep the mapping registered
		// for manager.close, then refuse to return a live handle.
		if staleErr := m.runtime.validateCurrent(); staleErr != nil {
			return servePublication{}, staleErr
		}
		m.armPendingDeliveryLocked(publication)
		return publication, nil
	case errors.Is(err, ErrPublicationCommitIndeterminate):
		// The attempted replacement or the prior mapping can be live. Retain
		// both possibilities so exact-generation teardown can remove either.
		attemptedVisibilityEvidence := visibilityEvidence(key, attempted, publication.Funnel)
		if prior, ok := m.mappings[key]; ok {
			attempted.variants = mergePublicationVariants(prior.variants, attempted.variants)
		}
		m.mappings[key] = attempted
		visibility := publicationVisibility{
			token:    token,
			funnel:   publication.Funnel,
			evidence: attemptedVisibilityEvidence,
		}
		if prior, ok := m.visibility[visibilityKey]; ok {
			visibility.evidence = mergeVisibilityEvidence(prior.evidence, visibility.evidence)
		}
		m.visibility[visibilityKey] = visibility
		return servePublication{}, err
	default:
		return servePublication{}, err
	}
}

func (m *publicationManager) armPendingDeliveryLocked(publication servePublication) {
	if publication.Generation == 0 || publication.MappingToken == 0 {
		return
	}
	delay := m.deliveryTimeout
	if delay <= 0 {
		delay = publicationDeliveryAckTimeout
	}
	pending := &pendingPublicationDelivery{
		generation:   publication.Generation,
		mappingToken: publication.MappingToken,
	}
	m.pendingDelivery[publication.MappingToken] = pending
	pending.timer = time.AfterFunc(delay, func() {
		m.expirePendingDelivery(pending)
	})
}

func (m *publicationManager) expirePendingDelivery(pending *pendingPublicationDelivery) {
	if m == nil || pending == nil {
		return
	}
	m.mu.Lock()
	current := m.pendingDelivery[pending.mappingToken]
	if current != pending || current.generation != pending.generation {
		m.mu.Unlock()
		return
	}
	delete(m.pendingDelivery, pending.mappingToken)
	runtime := m.runtime
	onLoss := m.onDeliveryLoss
	m.mu.Unlock()

	if onLoss != nil {
		onLoss(runtime, fmt.Errorf(
			"%w: publication generation %d mapping token %d was not acknowledged by Dart",
			ErrPublicationCommitIndeterminate,
			pending.generation,
			pending.mappingToken,
		))
	}
}

func (m *publicationManager) cancelPendingDeliveryLocked(mappingToken uint64) {
	pending := m.pendingDelivery[mappingToken]
	if pending == nil {
		return
	}
	delete(m.pendingDelivery, mappingToken)
	if pending.timer != nil {
		pending.timer.Stop()
	}
}

func (m *publicationManager) cancelAllPendingDeliveriesLocked() {
	for token := range m.pendingDelivery {
		m.cancelPendingDeliveryLocked(token)
	}
}

// acknowledgePublication transfers one exact live mapping from native's
// pending-delivery custody to the Dart handle. An already-obsolete mapping is
// an idempotent success; a live mapping with no pending receipt is ambiguous
// and must quarantine the generation rather than manufacture ownership.
func (m *publicationManager) acknowledgePublication(generation, mappingToken uint64) error {
	if m == nil || generation == 0 || mappingToken == 0 {
		return fmt.Errorf("%w: invalid publication acknowledgement", ErrPublicationCommitIndeterminate)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.runtime == nil || generation != m.runtime.generation {
		return ErrRuntimeStale
	}
	if err := m.requireCurrentLocked(); err != nil {
		return err
	}
	if pending := m.pendingDelivery[mappingToken]; pending != nil {
		if pending.generation != generation {
			return ErrRuntimeStale
		}
		m.cancelPendingDeliveryLocked(mappingToken)
		return nil
	}
	for _, mapping := range m.mappings {
		if mapping.token == mappingToken {
			return fmt.Errorf(
				"%w: live publication mapping token %d has no pending delivery receipt",
				ErrPublicationCommitIndeterminate,
				mappingToken,
			)
		}
	}
	return nil
}

func (m *publicationManager) clear(ctx context.Context, payload serveClearPayload) error {
	if m == nil {
		return notAppliedError(errors.New("publication manager is unavailable"))
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	mode, generation, token, err := payload.clearMode()
	if err != nil {
		return notAppliedError(err)
	}
	if mode == publicationClearExact && generation != m.runtime.generation {
		return nil
	}
	if err := m.requireCurrentLocked(); err != nil {
		if mode == publicationClearExact && errors.Is(err, ErrRuntimeStale) {
			return nil
		}
		return notAppliedError(err)
	}

	port, err := validateServePort("tailnetPort", payload.TailnetPort)
	if err != nil {
		return notAppliedError(err)
	}
	path, err := normalizeServePath(payload.Path)
	if err != nil {
		return notAppliedError(err)
	}
	key := publicationKey{port: port, path: path}

	var (
		host                   string
		mapping                publicationMapping
		visibilityKey          publicationPortKey
		visibility             publicationVisibility
		ownsVisibility         bool
		cleanupFunnelWhenEmpty = true
	)
	if mode == publicationClearExact {
		var ok bool
		mapping, ok = m.mappings[key]
		if !ok || mapping.token != token {
			return nil
		}
		host = mapping.host
		visibilityKey = publicationPortKey{host: host, port: port}
		visibility, ownsVisibility = m.visibility[visibilityKey]
		ownsVisibility = ownsVisibility && visibility.token == token
		// Only the latest forward on this host:port can change its Funnel bit.
		// A handle still owning path A cannot undo a later visibility decision
		// made by path B. An external true flip after a package-private mapping
		// is likewise not attributable to this handle and is preserved.
		payload.Funnel = ownsVisibility && visibility.funnel
		cleanupFunnelWhenEmpty = payload.Funnel
	} else {
		if err := contextBeforeDispatch(ctx); err != nil {
			return notAppliedError(err)
		}
		status, statusErr := m.client.StatusWithoutPeers(ctx)
		if statusErr != nil {
			return notAppliedError(m.runtime.resultError(statusErr))
		}
		host, _, err = serveHostFromStatus(status)
		if err != nil {
			return notAppliedError(err)
		}
		mapping = m.mappings[key]
		visibilityKey = publicationPortKey{host: host, port: port}
	}

	err = m.mutateLocked(ctx, true, func(sc *ipn.ServeConfig) (bool, error) {
		before := sc.Clone()
		if mode == publicationClearExact && !mappingMatchesServeConfig(mapping, sc, key) {
			// An external writer replaced the handler. Treat that replacement like
			// a newer package mapping: this exact handle no longer owns either the
			// path or its host:port visibility policy, so it is a stale no-op.
			return false, nil
		}
		if applyErr := applyServeClearForHostWithFunnelCleanup(sc, host, payload, cleanupFunnelWhenEmpty); applyErr != nil {
			return false, applyErr
		}
		return !reflect.DeepEqual(before, sc), nil
	})
	if err == nil {
		// Both an exact close and an explicit coordinate clear invalidate the
		// current package token only after a confirmed commit/no-op.
		m.cancelPendingDeliveryLocked(mapping.token)
		delete(m.mappings, key)
		switch {
		case mode == publicationClearExact && ownsVisibility,
			mode == publicationClearCoordinate && payload.Funnel:
			delete(m.visibility, visibilityKey)
		case mode == publicationClearCoordinate && mapping.token != 0:
			m.transferVisibilityAfterCoordinateClearLocked(visibilityKey, key, mapping)
		}
	}
	// On conflict, known-not-applied, or indeterminate Set, retain ownership
	// for a later retry or runtime teardown.
	return err
}

// close is runtime teardown's publication sweep. It is deliberately
// best-effort with a bounded standalone context: the runtime has already been
// detached/canceled, and the next runtime's mandatory bootstrap is the final
// stale-config barrier. The returned error is diagnostic and must not prevent
// Server.Close or Store/lease release.
func (m *publicationManager) close() error {
	if m == nil {
		return nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return nil
	}
	m.closed = true
	m.cancelAllPendingDeliveriesLocked()

	if (len(m.mappings) == 0 && len(m.visibility) == 0) || m.client == nil {
		clear(m.mappings)
		clear(m.visibility)
		return nil
	}
	ctx, cancel := boundedCallCtx(0)
	defer cancel()

	err := m.mutateLocked(ctx, false, func(sc *ipn.ServeConfig) (bool, error) {
		before := sc.Clone()
		// Evaluate visibility evidence before deleting any owned handlers: the
		// evidence is intentionally tied to the handler installed by the same
		// mutation. A later external replacement owns its unchanged/enabled
		// visibility and must not be clobbered by package teardown.
		for key, visibility := range m.visibility {
			if visibilityOwnsEnabledConfig(sc, key, visibility) {
				sc.SetFunnel(key.host, key.port, false)
			}
		}
		for key, mapping := range m.mappings {
			if !mappingMatchesServeConfig(mapping, sc, key) {
				continue
			}
			removeServeWebHandlerWithFunnelCleanup(sc, mapping.host, key.port, key.path, false)
		}
		return !reflect.DeepEqual(before, sc), nil
	})
	clear(m.mappings)
	clear(m.visibility)
	return err
}

func (m *publicationManager) count() int {
	if m == nil {
		return 0
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.mappings)
}

type serveConfigApply func(*ipn.ServeConfig) (changed bool, err error)

// mutateLocked executes at most three total ETag attempts within the caller's
// one context/deadline. Each attempt deep-clones the fetched config before the
// pure apply callback. Only upstream's typed precondition error is retried.
// Every other Set error is either conclusively not applied from typed evidence
// or conservatively indeterminate.
func (m *publicationManager) mutateLocked(ctx context.Context, requireCurrent bool, apply serveConfigApply) error {
	if m.client == nil {
		return notAppliedError(errors.New("publication LocalClient is unavailable"))
	}
	for attempt := 1; attempt <= maxServeConfigMutationAttempts; attempt++ {
		if err := contextBeforeDispatch(ctx); err != nil {
			return notAppliedError(err)
		}
		if requireCurrent {
			if err := m.requireCurrentLocked(); err != nil {
				return notAppliedError(err)
			}
		}

		base, err := m.client.GetServeConfig(ctx)
		if err != nil {
			if requireCurrent {
				err = m.runtime.resultError(err)
			}
			return notAppliedError(err)
		}
		if base == nil {
			base = new(ipn.ServeConfig)
		}
		candidate := base.Clone()
		changed, err := apply(candidate)
		if err != nil {
			return notAppliedError(err)
		}
		if !changed {
			return nil
		}
		if err := contextBeforeDispatch(ctx); err != nil {
			return notAppliedError(err)
		}
		if requireCurrent {
			if err := m.requireCurrentLocked(); err != nil {
				return notAppliedError(err)
			}
		}

		err = m.client.SetServeConfig(ctx, candidate)
		if err == nil {
			return nil
		}
		if m.isPreconditionsFailed != nil && m.isPreconditionsFailed(err) {
			if attempt == maxServeConfigMutationAttempts {
				return fmt.Errorf("%w after %d attempts: %w", ErrServeConfigConflict, attempt, err)
			}
			continue
		}
		if m.isKnownNotApplied != nil && m.isKnownNotApplied(err) {
			return notAppliedError(err)
		}
		return fmt.Errorf("%w: %w", ErrPublicationCommitIndeterminate, err)
	}
	panic("unreachable ServeConfig mutation attempt bound")
}

func (m *publicationManager) requireCurrentLocked() error {
	if m.closed {
		return ErrRuntimeStale
	}
	if m.runtime == nil {
		return ErrRuntimeStale
	}
	return m.runtime.validateCurrent()
}

func (m *publicationManager) nextTokenLocked() (uint64, error) {
	if m.nextMappingToken == ^uint64(0) {
		return 0, errors.New("publication mapping token space exhausted")
	}
	m.nextMappingToken++
	return m.nextMappingToken, nil
}

func contextBeforeDispatch(ctx context.Context) error {
	if ctx == nil {
		return errors.New("publication context is nil")
	}
	return ctx.Err()
}

func notAppliedError(err error) error {
	if err == nil || errors.Is(err, ErrPublicationNotApplied) {
		return err
	}
	return fmt.Errorf("%w: %w", ErrPublicationNotApplied, err)
}

func mappingFromPublication(sc *ipn.ServeConfig, publication servePublication, token uint64) (publicationMapping, error) {
	key := publication.key()
	if publication.host == "" || key.port == 0 || key.path == "" || token == 0 {
		return publicationMapping{}, errors.New("invalid publication ownership metadata")
	}
	hp := ipn.HostPort(net.JoinHostPort(publication.host, strconv.Itoa(int(key.port))))
	web := sc.Web[hp]
	if web == nil || web.Handlers[key.path] == nil {
		return publicationMapping{}, errors.New("ServeConfig mutation did not produce its web handler")
	}
	return publicationMapping{
		host:  publication.host,
		token: token,
		variants: []publicationVariant{{
			handler: web.Handlers[key.path].Clone(),
		}},
	}, nil
}

func mappingMatchesServeConfig(mapping publicationMapping, sc *ipn.ServeConfig, key publicationKey) bool {
	if mapping.host == "" || sc == nil {
		return false
	}
	hp := ipn.HostPort(net.JoinHostPort(mapping.host, strconv.Itoa(int(key.port))))
	web := sc.Web[hp]
	if web == nil {
		return false
	}
	current := web.Handlers[key.path]
	for _, variant := range mapping.variants {
		if reflect.DeepEqual(current, variant.handler) {
			return true
		}
	}
	return false
}

func mergePublicationVariants(a, b []publicationVariant) []publicationVariant {
	out := make([]publicationVariant, 0, len(a)+len(b))
	for _, candidate := range append(append([]publicationVariant(nil), a...), b...) {
		duplicate := false
		for _, existing := range out {
			if reflect.DeepEqual(existing.handler, candidate.handler) {
				duplicate = true
				break
			}
		}
		if !duplicate {
			out = append(out, candidate)
		}
	}
	return out
}

func visibilityEvidence(key publicationKey, mapping publicationMapping, funnel bool) []publicationVisibilityEvidence {
	evidence := make([]publicationVisibilityEvidence, 0, len(mapping.variants))
	for _, variant := range mapping.variants {
		evidence = append(evidence, publicationVisibilityEvidence{
			key:     key,
			handler: variant.handler.Clone(),
			funnel:  funnel,
		})
	}
	return evidence
}

func mergeVisibilityEvidence(a, b []publicationVisibilityEvidence) []publicationVisibilityEvidence {
	out := make([]publicationVisibilityEvidence, 0, len(a)+len(b))
	for _, candidate := range append(append([]publicationVisibilityEvidence(nil), a...), b...) {
		duplicate := false
		for _, existing := range out {
			if existing.key == candidate.key && existing.funnel == candidate.funnel &&
				reflect.DeepEqual(existing.handler, candidate.handler) {
				duplicate = true
				break
			}
		}
		if !duplicate {
			candidate.handler = candidate.handler.Clone()
			out = append(out, candidate)
		}
	}
	return out
}

func visibilityOwnsEnabledConfig(
	sc *ipn.ServeConfig,
	portKey publicationPortKey,
	visibility publicationVisibility,
) bool {
	if sc == nil {
		return false
	}
	hp := ipn.HostPort(net.JoinHostPort(portKey.host, strconv.Itoa(int(portKey.port))))
	web := sc.Web[hp]
	if web == nil {
		return false
	}
	for _, evidence := range visibility.evidence {
		if !evidence.funnel || evidence.key.port != portKey.port {
			continue
		}
		if reflect.DeepEqual(web.Handlers[evidence.key.path], evidence.handler) {
			return true
		}
	}
	return false
}

// transferVisibilityAfterCoordinateClearLocked repairs the port-level owner
// when an unqualified Serve clear removes the exact mapping that supplied its
// visibility evidence without changing AllowFunnel. The newest surviving
// package mapping on the port becomes the owner. With no surviving package
// mapping, visibility is external/unowned and teardown must preserve it.
func (m *publicationManager) transferVisibilityAfterCoordinateClearLocked(
	portKey publicationPortKey,
	clearedKey publicationKey,
	cleared publicationMapping,
) {
	visibility, ok := m.visibility[portKey]
	if !ok {
		return
	}
	if visibility.token != cleared.token {
		filtered := visibility.evidence[:0]
		for _, evidence := range visibility.evidence {
			if evidence.key != clearedKey {
				filtered = append(filtered, evidence)
			}
		}
		visibility.evidence = filtered
		m.visibility[portKey] = visibility
		return
	}

	var (
		replacementKey publicationKey
		replacement    publicationMapping
		found          bool
	)
	for key, mapping := range m.mappings {
		if key.port != portKey.port || mapping.host != portKey.host {
			continue
		}
		if !found || mapping.token > replacement.token {
			replacementKey = key
			replacement = mapping
			found = true
		}
	}
	if !found {
		delete(m.visibility, portKey)
		return
	}
	visibility.token = replacement.token
	visibility.evidence = visibilityEvidence(replacementKey, replacement, visibility.funnel)
	m.visibility[portKey] = visibility
}
