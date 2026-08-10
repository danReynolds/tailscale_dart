package tailscale

import "errors"

const (
	stateResetMarkerTempFilename = ".tailscale-state.reset.tmp"
	stateResetMaximumDepth       = 256
)

// stateResetMarkerPayload is deliberately fixed rather than marshaled at
// runtime. An exact, versioned marker lets reset distinguish a marker it has
// durably established from an arbitrary directory entry at the same path.
const stateResetMarkerPayload = "{\"format\":\"tailscale-dart-state-reset\",\"version\":1}\n"

var errStateResetMarkerInvalid = errors.New("invalid local-state reset marker")
