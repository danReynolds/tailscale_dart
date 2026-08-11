package tailscale

import "errors"

// LifecycleErrorCode maps a typed package sentinel to its stable Dart wire
// code, or "" when the error carries no known sentinel. This is the one
// classification table shared by every FFI error surface (the dylib lifecycle
// envelope and the LocalAPI JSON envelope), so a sentinel added in one place
// can no longer silently degrade to `unknown` on the other.
//
// Precedence is deliberate for the pairs that can co-occur in one joined
// error:
//   - logoutIndeterminate wins over runtimeCleanupFailed: callers must not
//     mistake a possibly-completed remote logout for a local cleanup problem.
//   - runtimeCleanupFailed wins over the remaining lifecycle and publication
//     codes: poisoned admission requires a process restart, which subsumes the
//     narrower recovery guidance of the code it joined.
//   - startupAbandoned wins over staleRuntime, matching requireLiveLocked.
//
// The remaining codes are mutually exclusive by construction; their order is
// stable but not semantically load-bearing.
//
// ErrPublicationNotApplied is deliberately absent: it wraps upstream
// validation errors whose HTTP-status or feature classification should win, so
// classifyLocalAPIError applies it only as its final fallback.
func LifecycleErrorCode(err error) string {
	switch {
	case errors.Is(err, ErrLogoutIndeterminate):
		return "logoutIndeterminate"
	case errors.Is(err, ErrRuntimeCleanupFailed):
		return "runtimeCleanupFailed"
	case errors.Is(err, ErrLifecycleBusy):
		return "lifecycleBusy"
	case errors.Is(err, ErrConfigurationMismatch):
		return "configurationMismatch"
	case errors.Is(err, ErrServeConfigConflict):
		return "serveConfigConflict"
	case errors.Is(err, ErrPublicationCommitIndeterminate):
		return "publicationCommitIndeterminate"
	case errors.Is(err, ErrDataPlaneNotReady):
		return "dataPlaneNotReady"
	case errors.Is(err, ErrPublicationBootstrapFailure):
		return "publicationBootstrapFailure"
	case errors.Is(err, ErrStartupAbandoned):
		return "startupAbandoned"
	case errors.Is(err, ErrRuntimeStale):
		return "staleRuntime"
	case errors.Is(err, ErrStateLeaseBusy):
		return "stateLeaseBusy"
	case errors.Is(err, ErrInvalidStateKey):
		return "invalidStateKey"
	case errors.Is(err, ErrMissingStateDEK):
		return "missingStateKey"
	case errors.Is(err, ErrOrphanedStateDEK):
		return "orphanedStateKey"
	case errors.Is(err, ErrLocalResetIncomplete):
		return "localResetIncomplete"
	case errors.Is(err, ErrConflictingStateFormats):
		return "conflictingStateFormats"
	case errors.Is(err, ErrLegacyStateUnsupported):
		return "legacyStateUnsupported"
	case errors.Is(err, ErrUnexpectedStateResidue),
		errors.Is(err, ErrEphemeralPersistentStateOccupied):
		return "unexpectedStateResidue"
	case errors.Is(err, ErrAtomicPersistenceFailure):
		return "atomicPersistenceFailure"
	case errors.Is(err, ErrEncryptedStateAuthentication):
		return "stateAuthenticationFailed"
	case errors.Is(err, ErrEncryptedStateUnsupported):
		return "unsupportedStateFormat"
	case errors.Is(err, ErrEncryptedStateInvalidFormat),
		errors.Is(err, ErrEncryptedStateOversized),
		errors.Is(err, ErrEncryptedStatePathSecurity):
		return "invalidStateFormat"
	}
	return ""
}
