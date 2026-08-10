import 'package:tailscale/src/errors.dart';
import 'package:tailscale/src/runtime_config.dart';
import 'package:test/test.dart';

void main() {
  group('canonicalizeControlUrl', () {
    test('resolves the default to one canonical URL', () {
      expect(canonicalizeControlUrl(null), defaultControlUrl);
    });

    test('normalizes scheme, host, default port, and dot segments', () {
      expect(
        canonicalizeControlUrl(
          Uri.parse('HTTPS://CONTROL.EXAMPLE:443/a/../control'),
        ),
        'https://control.example/control',
      );
    });

    test('maps an empty path to slash and preserves a non-default port', () {
      expect(
        canonicalizeControlUrl(Uri.parse('http://HEADSCALE.example:8080')),
        'http://headscale.example:8080/',
      );
    });

    test('preserves percent-encoded path data without double encoding', () {
      expect(
        canonicalizeControlUrl(Uri.parse('https://control.example/a%2Fb')),
        'https://control.example/a%2Fb',
      );
    });

    test('rejects ambiguous or credential-bearing forms', () {
      for (final value in [
        Uri.parse('ftp://control.example/'),
        Uri.parse('https:///missing-host'),
        Uri.parse('https://user:secret@control.example/'),
        Uri.parse('https://control.example/?mode=one'),
        Uri.parse('https://control.example/#section'),
      ]) {
        expect(
          () => canonicalizeControlUrl(value),
          throwsA(isA<TailscaleUsageException>()),
          reason: value.toString(),
        );
      }
    });
  });

  group('validateRuntimeHostname', () {
    test('preserves empty and exact-case hostnames', () {
      expect(validateRuntimeHostname(''), '');
      expect(validateRuntimeHostname('My-Node'), 'My-Node');
    });

    test('rejects surrounding whitespace', () {
      expect(
        () => validateRuntimeHostname(' node'),
        throwsA(isA<TailscaleUsageException>()),
      );
      expect(
        () => validateRuntimeHostname('node\n'),
        throwsA(isA<TailscaleUsageException>()),
      );
    });
  });
}
