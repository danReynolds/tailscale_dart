import 'errors.dart';

/// Maps the stable native error vocabulary onto Dart's public error enum.
///
/// Kept outside the worker library because a few synchronous FFI capabilities,
/// such as the generation-bound HTTP client, decode the same envelope.
TailscaleErrorCode parseNativeErrorCode(String? raw) => switch (raw) {
  'lifecycleBusy' => TailscaleErrorCode.lifecycleBusy,
  'runtimeCleanupFailed' => TailscaleErrorCode.runtimeCleanupFailed,
  'configurationMismatch' => TailscaleErrorCode.configurationMismatch,
  'staleRuntime' => TailscaleErrorCode.staleRuntime,
  'dataPlaneNotReady' => TailscaleErrorCode.dataPlaneNotReady,
  'publicationBootstrapFailure' =>
    TailscaleErrorCode.publicationBootstrapFailure,
  'serveConfigConflict' => TailscaleErrorCode.serveConfigConflict,
  'publicationNotApplied' => TailscaleErrorCode.publicationNotApplied,
  'publicationCommitIndeterminate' =>
    TailscaleErrorCode.publicationCommitIndeterminate,
  'startupAbandoned' => TailscaleErrorCode.startupAbandoned,
  'stateLeaseBusy' => TailscaleErrorCode.stateLeaseBusy,
  'invalidStateKey' => TailscaleErrorCode.invalidStateKey,
  'missingStateKey' => TailscaleErrorCode.missingStateKey,
  'orphanedStateKey' => TailscaleErrorCode.orphanedStateKey,
  'localResetIncomplete' => TailscaleErrorCode.localResetIncomplete,
  'conflictingStateFormats' => TailscaleErrorCode.conflictingStateFormats,
  'legacyStateUnsupported' => TailscaleErrorCode.legacyStateUnsupported,
  'unexpectedStateResidue' => TailscaleErrorCode.unexpectedStateResidue,
  'atomicPersistenceFailure' => TailscaleErrorCode.atomicPersistenceFailure,
  'stateAuthenticationFailed' => TailscaleErrorCode.stateAuthenticationFailed,
  'unsupportedStateFormat' => TailscaleErrorCode.unsupportedStateFormat,
  'invalidStateFormat' => TailscaleErrorCode.invalidStateFormat,
  'startupTimeout' => TailscaleErrorCode.startupTimeout,
  'logoutIndeterminate' => TailscaleErrorCode.logoutIndeterminate,
  'workerTerminated' => TailscaleErrorCode.workerTerminated,
  'notFound' => TailscaleErrorCode.notFound,
  'forbidden' => TailscaleErrorCode.forbidden,
  'conflict' => TailscaleErrorCode.conflict,
  'preconditionFailed' => TailscaleErrorCode.preconditionFailed,
  'featureDisabled' => TailscaleErrorCode.featureDisabled,
  _ => TailscaleErrorCode.unknown,
};
