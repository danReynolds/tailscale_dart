// Shared argument validation/normalization for the Serve and Funnel mount
// surfaces, which enforce identical port/address/path rules. Kept in one file
// so the two public APIs can't drift; mirrors the authoritative Go-side checks
// in go/localapi.go.
import 'dart:io';

/// Validates a tailnet/public/local port is in 1–65535, returning it.
int validateServePort(int port, String name) {
  if (port < 1 || port > 65535) {
    throw RangeError.range(port, 1, 65535, name);
  }
  return port;
}

/// Requires [localAddress] to be a loopback address, returning the normalized
/// form (`localhost` → `127.0.0.1`).
String normalizeServeLocalAddress(String localAddress) {
  final trimmed = localAddress.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(
      localAddress,
      'localAddress',
      'must not be empty',
    );
  }
  if (!_isLoopbackAddress(trimmed)) {
    throw ArgumentError.value(
      localAddress,
      'localAddress',
      'must be a loopback address such as 127.0.0.1, ::1, or localhost',
    );
  }
  if (trimmed.toLowerCase() == 'localhost') {
    return '127.0.0.1';
  }
  return trimmed;
}

bool _isLoopbackAddress(String address) {
  if (address.toLowerCase() == 'localhost') return true;
  return InternetAddress.tryParse(address)?.isLoopback ?? false;
}

/// Normalizes a mount path: empty → `/`, must start with `/`, no query/fragment
/// or `.`/`..` traversal segments.
String normalizeServePath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return '/';
  if (!trimmed.startsWith('/')) {
    throw ArgumentError.value(path, 'path', 'must start with /');
  }
  if (trimmed.contains('?') || trimmed.contains('#')) {
    throw ArgumentError.value(
      path,
      'path',
      'must not include query or fragment',
    );
  }
  if (_containsPathTraversal(trimmed)) {
    throw ArgumentError.value(
      path,
      'path',
      'must not include . or .. segments',
    );
  }
  return trimmed;
}

bool _containsPathTraversal(String path) {
  for (final segment in path.split('/')) {
    if (segment == '.' || segment == '..') return true;
  }
  return false;
}
