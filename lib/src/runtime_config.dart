import 'errors.dart';

const defaultControlUrl = 'https://controlplane.tailscale.com/';

String validateRuntimeHostname(String hostname) {
  if (hostname != hostname.trim()) {
    throw const TailscaleUsageException(
      'hostname must not have leading or trailing whitespace.',
    );
  }
  return hostname;
}

/// Returns the one serialized control URL used for both runtime identity and
/// native construction.
String canonicalizeControlUrl(Uri? value) {
  final input = value ?? Uri.parse(defaultControlUrl);
  final scheme = input.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    throw const TailscaleUsageException(
      'controlUrl must use the http or https scheme.',
    );
  }
  if (!input.hasAuthority || input.host.isEmpty) {
    throw const TailscaleUsageException('controlUrl must include a host.');
  }
  if (input.userInfo.isNotEmpty) {
    throw const TailscaleUsageException(
      'controlUrl must not include user information.',
    );
  }
  if (input.hasQuery) {
    throw const TailscaleUsageException('controlUrl must not include a query.');
  }
  if (input.hasFragment) {
    throw const TailscaleUsageException(
      'controlUrl must not include a fragment.',
    );
  }

  final normalized = input.normalizePath();
  final isDefaultPort =
      (scheme == 'http' && input.port == 80) ||
      (scheme == 'https' && input.port == 443);

  return Uri(
    scheme: scheme,
    host: input.host.toLowerCase(),
    port: input.hasPort && !isDefaultPort ? input.port : null,
    path: normalized.path.isEmpty ? '/' : normalized.path,
  ).toString();
}
