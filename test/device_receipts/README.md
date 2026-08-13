# Physical-device receipts

These dated, content-free receipts record release evidence that simulators,
emulators, and CI cannot provide. They intentionally omit device identifiers,
auth keys, node keys, Keychain contents, and raw state contents.

A receipt is evidence for the exact package commit, OS, hardware class, and
toolchain it names. A partial or externally blocked receipt does not qualify an
entire platform. Keep the normal smoke matrix small; use these files to record
the less frequent production-custody and hosted-control-plane checks.

Generated physical-device smoke matrices and network-performance samples live
under `benchmark/results/<version>/devices/`. Link them from a dated receipt
when a run contributes to release qualification; keep custody and hosted
control-plane evidence here because the ephemeral profile runner does not test
those boundaries.
