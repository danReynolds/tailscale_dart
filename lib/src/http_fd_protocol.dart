/// Maximum JSON head envelope accepted by the internal fd-backed HTTP protocol.
///
/// This is intentionally far below the old defensive 16 MiB cap. Real HTTP
/// headers should stay small; large application data belongs in the body fd.
const int tailscaleMaxHttpHeadBytes = 256 * 1024;
