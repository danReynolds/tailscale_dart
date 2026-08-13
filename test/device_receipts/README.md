# Physical-device receipts

These dated, content-free receipts record release evidence that simulators,
emulators, and CI cannot provide. They intentionally omit device identifiers,
auth keys, node keys, Keychain contents, and raw state contents.

A receipt is evidence for the exact package commit, OS, hardware class, and
toolchain it names. A partial or externally blocked receipt does not qualify an
entire platform. Keep the normal smoke matrix small; use these files to record
the less frequent production-custody and hosted-control-plane checks.

Generated physical-device network-performance samples live under
`benchmark/results/<version>/devices/`. Persistent-custody JSON/Markdown pairs
live here because they are release qualification rather than performance
history. The generated platform-qualification matrix keeps ephemeral data
plane, process-death reconnect, production custody, local reset, and profiling
as distinct lanes; `NOT RUN` is not a pass. Link either artifact from a dated
narrative receipt when extra context is useful.
