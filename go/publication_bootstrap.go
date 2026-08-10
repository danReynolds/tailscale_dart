package tailscale

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"tailscale.com/ipn"
)

const publicationBootstrapMaxWait = 30 * time.Second

// ErrDataPlaneNotReady means upstream has not yet reached Running, so the
// mandatory first-Up reset has not started. Calls made during the reset join
// its one bounded result instead of receiving this error.
var ErrDataPlaneNotReady = errors.New("tailscale data plane not ready")

// ErrPublicationBootstrapFailure means the one allowed Server.Up/reset failed.
// The exact runtime is detached and drained before this crosses FFI.
var ErrPublicationBootstrapFailure = errors.New("tailscale publication bootstrap failed")

type publicationBootstrapPhase uint8

const (
	publicationBootstrapPreRunning publicationBootstrapPhase = iota
	publicationBootstrapRunning
	publicationBootstrapReady
	publicationBootstrapFailing
	publicationBootstrapFailed
	publicationBootstrapClosed
)

type publicationBootstrap struct {
	mu sync.Mutex

	phase       publicationBootstrapPhase
	latestState ipn.State
	result      chan struct{}
	resultOnce  sync.Once
	resultErr   error

	initiatingUpPending  bool
	initiatingUpDeadline time.Time

	cancel     context.CancelFunc
	workerDone chan struct{}
	up         func(context.Context) error
	now        func() time.Time
}

type publicationBootstrapStart struct {
	ctx  context.Context
	done chan struct{}
	up   func(context.Context) error
}

func newPublicationBootstrap(runtime *nodeRuntime) *publicationBootstrap {
	b := &publicationBootstrap{
		phase:       publicationBootstrapPreRunning,
		latestState: ipn.Starting,
		result:      make(chan struct{}),
		now:         time.Now,
	}
	b.up = func(ctx context.Context) error {
		if runtime == nil || runtime.server == nil {
			return errors.New("tsnet server is unavailable")
		}
		_, err := runtime.server.Up(ctx)
		return err
	}
	return b
}

func (m *publicationManager) beginInitiatingUp(deadline time.Time) {
	if m == nil || m.bootstrap == nil {
		return
	}
	b := m.bootstrap
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.phase != publicationBootstrapPreRunning {
		return
	}
	b.initiatingUpPending = true
	b.initiatingUpDeadline = deadline
}

func (m *publicationManager) markInitiatingUpSettled() {
	if m == nil || m.bootstrap == nil {
		return
	}
	b := m.bootstrap
	b.mu.Lock()
	b.initiatingUpPending = false
	b.mu.Unlock()
}

// observeState records the non-secret lifecycle state and suppresses Running
// until the one first-Up reset has completed. The returned start is non-nil
// exactly once and must be run on its own goroutine.
func (m *publicationManager) observeState(state ipn.State) (suppress bool, start *publicationBootstrapStart) {
	if m == nil || m.bootstrap == nil {
		return state == ipn.Running, nil
	}
	b := m.bootstrap
	b.mu.Lock()
	defer b.mu.Unlock()
	b.latestState = state
	if state != ipn.Running {
		return false, nil
	}

	switch b.phase {
	case publicationBootstrapReady:
		return false, nil
	case publicationBootstrapPreRunning:
		now := b.now()
		deadline := now.Add(publicationBootstrapMaxWait)
		if b.initiatingUpPending && !b.initiatingUpDeadline.IsZero() && b.initiatingUpDeadline.Before(deadline) {
			deadline = b.initiatingUpDeadline
		}
		ctx, cancel := context.WithDeadline(m.runtime.ctx, deadline)
		done := make(chan struct{})
		b.phase = publicationBootstrapRunning
		b.cancel = cancel
		b.workerDone = done
		return true, &publicationBootstrapStart{ctx: ctx, done: done, up: b.up}
	default:
		return true, nil
	}
}

type dataPlaneNotReadyError struct {
	state ipn.State
}

func (e *dataPlaneNotReadyError) Error() string {
	state := e.state.String()
	if state == "" {
		state = ipn.Starting.String()
	}
	return fmt.Sprintf("%v: current state %s", ErrDataPlaneNotReady, state)
}

func (e *dataPlaneNotReadyError) Unwrap() error { return ErrDataPlaneNotReady }

func (m *publicationManager) awaitDataPlaneReady(ctx context.Context) error {
	if m == nil || m.bootstrap == nil {
		return &dataPlaneNotReadyError{state: ipn.Starting}
	}
	if ctx == nil {
		ctx = context.Background()
	}
	b := m.bootstrap
	b.mu.Lock()
	switch b.phase {
	case publicationBootstrapPreRunning:
		err := &dataPlaneNotReadyError{state: b.latestState}
		b.mu.Unlock()
		return err
	case publicationBootstrapReady:
		b.mu.Unlock()
		return nil
	case publicationBootstrapFailed:
		err := b.resultErr
		b.mu.Unlock()
		return err
	case publicationBootstrapClosed:
		b.mu.Unlock()
		return ErrRuntimeStale
	case publicationBootstrapRunning, publicationBootstrapFailing:
		result := b.result
		b.mu.Unlock()
		select {
		case <-result:
			b.mu.Lock()
			err := b.resultErr
			phase := b.phase
			b.mu.Unlock()
			if phase == publicationBootstrapReady {
				return nil
			}
			if err != nil {
				return err
			}
			return ErrRuntimeStale
		case <-ctx.Done():
			return ctx.Err()
		}
	default:
		b.mu.Unlock()
		return ErrRuntimeStale
	}
}

func (m *publicationManager) maskRunningState(state string) string {
	if state != ipn.Running.String() || m == nil || m.bootstrap == nil {
		return state
	}
	b := m.bootstrap
	b.mu.Lock()
	ready := b.phase == publicationBootstrapReady
	b.mu.Unlock()
	if ready {
		return state
	}
	return ipn.Starting.String()
}

func (m *publicationManager) bootstrapReady() bool {
	if m == nil || m.bootstrap == nil {
		return false
	}
	b := m.bootstrap
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.phase == publicationBootstrapReady
}

func (m *publicationManager) beginBootstrapFailure(cause error) (error, bool) {
	if m == nil || m.bootstrap == nil {
		return nil, false
	}
	b := m.bootstrap
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.phase != publicationBootstrapPreRunning && b.phase != publicationBootstrapRunning {
		return b.resultErr, false
	}
	failure := fmt.Errorf("%w: %w", ErrPublicationBootstrapFailure, cause)
	b.phase = publicationBootstrapFailing
	b.resultErr = failure
	if b.cancel != nil {
		b.cancel()
	}
	return failure, true
}

// publishBootstrapSuccess is called only by the Up worker. The watcher owner
// check, any still-current synthetic Running post, and gate release are one
// watchMu-serialized boundary, so a dead/superseded watcher can never leave a
// ready-but-hidden runtime behind.
func (m *publicationManager) publishBootstrapSuccess(run *watcherRun) bool {
	if m == nil || m.bootstrap == nil {
		return false
	}
	watchMu.Lock()
	defer watchMu.Unlock()
	if !watcherRunCurrentLocked(run) {
		return false
	}
	b := m.bootstrap
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.phase != publicationBootstrapRunning {
		return false
	}
	// The main watcher can observe a newer non-Running transition while
	// Server.Up is completing its private-watcher Status/reset work. In that
	// case the newer state has already been published and must not be
	// overwritten by a stale synthetic Running. The one-time reset still
	// succeeded, so open the bootstrap gate; a later real Running notification
	// will be published normally once the phase is Ready.
	if b.latestState == ipn.Running {
		post := run.post
		if post == nil {
			post = postMessage
		}
		post(map[string]any{
			"type":         "status",
			"runtimeToken": run.runtimeToken,
			"state":        ipn.Running.String(),
		})
	}
	b.phase = publicationBootstrapReady
	b.resultErr = nil
	if b.cancel != nil {
		b.cancel()
		b.cancel = nil
	}
	b.resultOnce.Do(func() { close(b.result) })
	return true
}

func (m *publicationManager) finishBootstrapFailure(failure error) {
	if m == nil || m.bootstrap == nil {
		return
	}
	b := m.bootstrap
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.phase != publicationBootstrapFailing {
		return
	}
	b.phase = publicationBootstrapFailed
	b.resultErr = failure
	b.resultOnce.Do(func() { close(b.result) })
}

// shutdownBootstrap cancels and joins Server.Up before Server.Close. A fatal
// reaper preserves its typed result until the exact drain has completed;
// ordinary down/logout closes waiters as stale instead.
func (m *publicationManager) shutdownBootstrap(preserveFailure bool) {
	if m == nil || m.bootstrap == nil {
		return
	}
	b := m.bootstrap
	b.mu.Lock()
	if b.cancel != nil {
		b.cancel()
	}
	done := b.workerDone
	if !preserveFailure && b.phase != publicationBootstrapReady {
		b.phase = publicationBootstrapClosed
		b.resultErr = ErrRuntimeStale
		b.resultOnce.Do(func() { close(b.result) })
	}
	b.mu.Unlock()
	if done != nil {
		<-done
	}
}

func runPublicationBootstrap(runtime *nodeRuntime, run *watcherRun, start *publicationBootstrapStart) {
	defer close(start.done)
	if err := start.up(start.ctx); err != nil {
		failPublicationBootstrap(runtime, fmt.Errorf("Server.Up: %w", err))
		return
	}
	if runtime.publication.publishBootstrapSuccess(run) {
		return
	}
	failPublicationBootstrap(runtime, errors.New("state watcher lost ownership before readiness publication"))
}

func failPublicationBootstrap(runtime *nodeRuntime, cause error) bool {
	if runtime == nil || runtime.publication == nil {
		return false
	}
	failure, claimed := runtime.publication.beginBootstrapFailure(cause)
	if !claimed {
		return false
	}
	go reapPublicationBootstrapFailure(runtime, failure)
	return true
}

func detachRuntimeForPublicationFailure(runtime *nodeRuntime) (*drainingRuntime, bool) {
	if runtime == nil {
		return nil, false
	}
	runtimes.mu.Lock()
	defer runtimes.mu.Unlock()
	if runtimes.current != runtime || runtime.generation != nodeEpoch.Load() {
		return nil, false
	}
	return detachRuntimeLocked(runtime, ""), true
}

func reapPublicationBootstrapFailure(runtime *nodeRuntime, failure error) {
	draining, owned := detachRuntimeForPublicationFailure(runtime)
	if !owned {
		// A concurrent explicit lifecycle operation owns teardown and its public
		// receipt. Its normal manager shutdown releases gate waiters as stale.
		return
	}

	closeErr := runtime.closeForPublicationBootstrapFailure()
	finalFailure := failure
	if closeErr != nil {
		finalFailure = errors.Join(failure, cleanupFailureError(closeErr))
	}
	runtime.publication.finishBootstrapFailure(finalFailure)

	// Keep the controller in draining state until this terminal event is queued,
	// so a replacement runtime cannot take over the process-global Dart port.
	postMessage(map[string]any{
		"type":               "runtimeTerminated",
		"runtimeToken":       runtime.token,
		"code":               "publicationBootstrapFailure",
		"error":              finalFailure.Error(),
		"emitStopped":        closeErr == nil,
		"cleanupFailed":      closeErr != nil,
		"reportRuntimeError": true,
	})
	_ = finishRuntimeDrain(draining, closeErr)
}

// quarantinePublicationCommitIndeterminate closes the exact generation before
// a possibly-applied ServeConfig mutation returns to Dart. The operation error
// is the synchronous owner; the terminal event only detaches Dart capabilities
// and publishes a truthful stopped transition.
func quarantinePublicationCommitIndeterminate(runtime *nodeRuntime, cause error) error {
	return quarantinePublicationFailure(runtime, cause, false)
}

// quarantinePublicationDeliveryFailure is the fail-safe owner for a committed
// mapping whose exact handle was not acknowledged by Dart. Unlike a LocalAPI
// response-loss error (which is synchronously returned to its caller), timer
// and result-port loss are background lifecycle failures and publish one typed
// runtime error after the exact generation is detached and drained.
func quarantinePublicationDeliveryFailure(runtime *nodeRuntime, cause error) error {
	return quarantinePublicationFailure(runtime, cause, true)
}

func quarantinePublicationFailure(runtime *nodeRuntime, cause error, reportRuntimeError bool) error {
	draining, owned := detachRuntimeForPublicationFailure(runtime)
	if !owned {
		// An explicit down/logout may have won the detach race. If it is still
		// draining this runtime, join it before returning the uncertain result.
		runtimes.mu.Lock()
		activeDrain := runtimes.draining
		if activeDrain == nil || activeDrain.runtime != runtime {
			runtimes.mu.Unlock()
			return cause
		}
		done := activeDrain.done
		runtimes.mu.Unlock()
		<-done
		if activeDrain.err != nil {
			return errors.Join(cause, cleanupFailureError(activeDrain.err))
		}
		return cause
	}

	closeErr := runtime.close()
	finalErr := cause
	if closeErr != nil {
		finalErr = errors.Join(cause, cleanupFailureError(closeErr))
	}
	postMessage(map[string]any{
		"type":               "runtimeTerminated",
		"runtimeToken":       runtime.token,
		"code":               "publicationCommitIndeterminate",
		"error":              finalErr.Error(),
		"emitStopped":        closeErr == nil,
		"cleanupFailed":      closeErr != nil,
		"reportRuntimeError": reportRuntimeError,
	})
	_ = finishRuntimeDrain(draining, closeErr)
	return finalErr
}
