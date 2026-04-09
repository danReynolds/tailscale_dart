// tailscale native build hook.
//
// Compiles the Go tsnet library into a platform-appropriate native library
// and registers it as a native code asset. Runs automatically during
// `dart run` or `flutter build`.
//
// Requires Go 1.25+ installed and on PATH.
//
// How the pieces connect:
//
//   1. This hook compiles Go → shared/static library, registered under the
//      asset name 'src/ffi_bindings.dart'.
//
//   2. In Dart, @ffi.DefaultAsset('package:tailscale/src/ffi_bindings.dart')
//      tells FFI to load the library registered under that same name.
//
//   3. The Dart toolchain matches them — @Native external functions in Dart
//      resolve to the compiled Go/C functions.
//
// Platform-specific handling:
//   - iOS: builds a static archive (c-archive) with Xcode toolchain.
//   - Android: builds a shared library (c-shared) with NDK toolchain.
//   - macOS/Linux/Windows: builds a shared library (c-shared) with host toolchain.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as p;

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final targetOS = input.config.code.targetOS;
    final targetArch = input.config.code.targetArchitecture;
    final packageRoot = input.packageRoot.path;
    final outDir = input.outputDirectory;

    final goos = _toGOOS(targetOS);
    final goarch = _toGOARCH(targetArch);
    final isIOS = targetOS == OS.iOS;

    // Output filename
    final libName = targetOS.dylibFileName('tailscale');
    final libPath = outDir.resolve(libName).path;

    // Go source entry point
    final mainGo = p.join(packageRoot, 'go', 'cmd', 'dylib', 'main.go');

    // Build environment
    final env = <String, String>{
      'GOOS': goos,
      'GOARCH': goarch,
      'CGO_ENABLED': '1',
      // Disable raw disco to avoid permission errors on Android/Linux.
      'TS_ENABLE_RAW_DISCO': 'false',
    };

    // Build flags
    final buildTags = <String>[];

    // Platform-specific toolchain setup
    if (targetOS == OS.android) {
      _configureAndroid(env, buildTags, targetArch);
    } else if (isIOS) {
      await _configureIOS(env, targetArch);
    } else if (targetOS == OS.macOS) {
      // macOS: Dart's native asset bundler uses install_name_tool to rewrite
      // dylib paths. This requires enough header padding in the Mach-O binary.
      env['CGO_LDFLAGS'] = '-headerpad_max_install_names';
    }

    // Find Go binary and verify version
    final goBin = await _findGo();
    await _checkGoVersion(goBin);

    // iOS doesn't support c-shared. Build c-archive then convert to dylib
    // using clang. All other platforms use c-shared directly.
    final buildMode = isIOS ? 'c-archive' : 'c-shared';
    final goOutput = isIOS
        ? outDir.resolve('libtailscale.a').path
        : libPath;

    // Run go build
    final goArgs = [
      'build',
      '-buildmode=$buildMode',
      if (buildTags.isNotEmpty) '-tags=${buildTags.join(",")}',
      '-o',
      goOutput,
      mainGo,
    ];

    final result = await Process.run(
      goBin,
      goArgs,
      environment: env,
      workingDirectory: p.join(packageRoot, 'go'),
    );

    if (result.exitCode != 0) {
      throw Exception(
        'Go build failed (exit ${result.exitCode}):\n'
        'Command: go ${goArgs.join(" ")}\n'
        'GOOS=$goos GOARCH=$goarch\n'
        'stderr: ${result.stderr}\n'
        'stdout: ${result.stdout}',
      );
    }

    // On iOS, convert the static archive to a dynamic library.
    if (isIOS) {
      await _archiveToSharedLib(env, goOutput, libPath);
    }

    final linkMode = DynamicLoadingBundled();

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/ffi_bindings.dart',
        file: Uri.file(libPath),
        linkMode: linkMode,
      ),
    );

    // Register Go source files as dependencies so the hook re-runs on changes.
    final goDir = p.join(packageRoot, 'go');
    for (final entity in Directory(goDir).listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.go')) {
        output.dependencies.add(entity.uri);
      }
    }
  });
}

// ---------------------------------------------------------------------------
// Go toolchain
// ---------------------------------------------------------------------------

/// Finds the Go binary, checking PATH and common installation paths.
Future<String> _findGo() async {
  // Try PATH first (works on all platforms)
  final whichCmd = Platform.isWindows ? 'where' : 'which';
  final whichResult = await Process.run(whichCmd, ['go']);
  if (whichResult.exitCode == 0) {
    return (whichResult.stdout as String).trim().split('\n').first;
  }

  // Check GOROOT if set
  final goroot = Platform.environment['GOROOT'];
  if (goroot != null) {
    final bin = p.join(goroot, 'bin', Platform.isWindows ? 'go.exe' : 'go');
    if (File(bin).existsSync()) return bin;
  }

  // Common installation paths by platform
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  final candidates = [
    // Official installer default
    if (!Platform.isWindows) '/usr/local/go/bin/go',
    // Homebrew (Apple Silicon + Intel)
    if (Platform.isMacOS) '/opt/homebrew/bin/go',
    // User GOPATH
    if (home.isNotEmpty) p.join(home, 'go', 'bin', 'go'),
    // Windows defaults
    if (Platform.isWindows) r'C:\Go\bin\go.exe',
    if (Platform.isWindows) p.join(home, r'go\bin\go.exe'),
  ];

  // Homebrew Cellar (versioned) — only check if directory exists
  if (Platform.isMacOS) {
    final cellar = Directory('/usr/local/Cellar/go');
    if (cellar.existsSync()) {
      for (final d in cellar.listSync().whereType<Directory>()) {
        candidates.add(p.join(d.path, 'libexec', 'bin', 'go'));
      }
    }
  }

  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }

  throw Exception(
    'Go toolchain not found.\n'
    '\n'
    'tailscale requires Go 1.25+ to compile its native library.\n'
    'Install from: https://go.dev/dl/\n'
    '\n'
    'After installing, ensure `go` is on your PATH, or set the GOROOT\n'
    'environment variable to your Go installation directory.',
  );
}

const _minGoMajor = 1;
const _minGoMinor = 25;

/// Verifies the Go version is at least 1.25.
Future<void> _checkGoVersion(String goBin) async {
  final result = await Process.run(goBin, ['version']);
  if (result.exitCode != 0) {
    throw Exception('Failed to check Go version: ${result.stderr}');
  }

  // Output: "go version go1.25.5 darwin/arm64"
  final output = (result.stdout as String).trim();
  final match = RegExp(r'go(\d+)\.(\d+)').firstMatch(output);
  if (match == null) {
    throw Exception(
      'Could not parse Go version from: $output\n'
      'Expected format: go version go1.X.Y ...',
    );
  }

  final major = int.parse(match.group(1)!);
  final minor = int.parse(match.group(2)!);

  if (major < _minGoMajor ||
      (major == _minGoMajor && minor < _minGoMinor)) {
    throw Exception(
      'Go $_minGoMajor.$_minGoMinor+ required, found go$major.$minor.\n'
      'Update from: https://go.dev/dl/',
    );
  }
}

// ---------------------------------------------------------------------------
// Platform mapping
// ---------------------------------------------------------------------------

String _toGOOS(OS os) => switch (os) {
      OS.android => 'android',
      OS.iOS => 'ios',
      OS.linux => 'linux',
      OS.macOS => 'darwin',
      OS.windows => 'windows',
      _ => throw UnsupportedError('Unsupported target OS: $os'),
    };

String _toGOARCH(Architecture? arch) => switch (arch) {
      Architecture.arm64 => 'arm64',
      Architecture.x64 => 'amd64',
      Architecture.arm => 'arm',
      Architecture.ia32 => '386',
      _ => throw UnsupportedError('Unsupported target architecture: $arch'),
    };

// ---------------------------------------------------------------------------
// Android NDK configuration
// ---------------------------------------------------------------------------

void _configureAndroid(
    Map<String, String> env, List<String> buildTags, Architecture? arch) {
  // Omit raw disco on Android to avoid socket permission issues.
  buildTags.add('ts_omit_listenrawdisco');

  final ndkHome = _findAndroidNDK();
  if (ndkHome == null) {
    throw Exception(
      'Android NDK not found. Set ANDROID_NDK_HOME or ANDROID_HOME.\n'
      'Install via: sdkmanager --install "ndk;<version>"',
    );
  }

  // Determine host OS for toolchain path
  final hostOS = Platform.isWindows
      ? 'windows-x86_64'
      : Platform.isMacOS
          ? 'darwin-x86_64'
          : 'linux-x86_64';
  final toolchain = p.join(ndkHome, 'toolchains', 'llvm', 'prebuilt', hostOS);

  const apiLevel = 24;

  // Map Dart architecture to NDK clang target triple
  final ccTarget = switch (arch) {
    Architecture.arm64 => 'aarch64-linux-android',
    Architecture.arm => 'armv7a-linux-androideabi',
    Architecture.x64 => 'x86_64-linux-android',
    Architecture.ia32 => 'i686-linux-android',
    _ => throw UnsupportedError('Unsupported Android arch: $arch'),
  };

  env['CC'] = p.join(toolchain, 'bin', '$ccTarget$apiLevel-clang');
  env['CXX'] = p.join(toolchain, 'bin', '$ccTarget$apiLevel-clang++');
}

String? _findAndroidNDK() {
  final ndkHome = Platform.environment['ANDROID_NDK_HOME'];
  if (ndkHome != null && Directory(ndkHome).existsSync()) return ndkHome;

  // Check ANDROID_HOME, ANDROID_SDK_ROOT, and common default locations.
  final candidates = [
    Platform.environment['ANDROID_HOME'],
    Platform.environment['ANDROID_SDK_ROOT'],
    if (Platform.isMacOS) '${Platform.environment['HOME']}/Library/Android/sdk',
    if (Platform.isLinux) '${Platform.environment['HOME']}/Android/Sdk',
    if (Platform.isWindows)
      '${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk',
  ];

  for (final sdk in candidates) {
    if (sdk == null) continue;
    final ndkDir = Directory(p.join(sdk, 'ndk'));
    if (!ndkDir.existsSync()) continue;

    final versions = ndkDir
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path)
        .toList()
      ..sort();

    if (versions.isNotEmpty) return versions.last;
  }

  return null;
}

// ---------------------------------------------------------------------------
// iOS configuration
// ---------------------------------------------------------------------------

Future<void> _configureIOS(
    Map<String, String> env, Architecture? arch) async {
  // On Apple Silicon Macs, the simulator uses arm64 (same as device).
  // The Dart build system tells us the target — we just need to pick the right SDK.
  // For now, physical device = iphoneos, and we don't distinguish simulator here
  // because the Dart native assets system handles that via the target triple.
  const sdk = 'iphoneos';
  const minVersion = '13.0';

  final ccResult =
      await Process.run('xcrun', ['--sdk', sdk, '--find', 'clang']);
  if (ccResult.exitCode != 0) {
    throw Exception('Failed to find iOS clang: ${ccResult.stderr}');
  }
  final cc = (ccResult.stdout as String).trim();

  final sdkPathResult =
      await Process.run('xcrun', ['--sdk', sdk, '--show-sdk-path']);
  if (sdkPathResult.exitCode != 0) {
    throw Exception('Failed to find iOS SDK path: ${sdkPathResult.stderr}');
  }
  final sdkPath = (sdkPathResult.stdout as String).trim();

  final archFlag = arch == Architecture.arm64 ? 'arm64' : 'x86_64';

  env['CC'] = cc;
  env['CXX'] = cc.replaceAll('clang', 'clang++');
  env['CGO_CFLAGS'] =
      '-isysroot $sdkPath -arch $archFlag -miphoneos-version-min=$minVersion';
  env['CGO_LDFLAGS'] =
      '-isysroot $sdkPath -arch $archFlag -miphoneos-version-min=$minVersion';
}

/// Converts a Go c-archive (.a) into a shared library (.dylib) using clang.
///
/// Go doesn't support c-shared on ios/arm64, but Flutter's native assets
/// system requires a dynamic library. This bridges the gap.
Future<void> _archiveToSharedLib(
    Map<String, String> env, String archivePath, String dylibPath) async {
  final cc = env['CC'];
  if (cc == null) throw Exception('CC not set for iOS build');

  final cflags = env['CGO_CFLAGS'] ?? '';
  final ldflags = env['CGO_LDFLAGS'] ?? '';

  final args = [
    ...cflags.split(' ').where((s) => s.isNotEmpty),
    '-fpic',
    '-shared',
    '-Wl,-all_load',
    archivePath,
    '-framework', 'CoreFoundation',
    '-framework', 'Security',
    '-o', dylibPath,
    '-headerpad_max_install_names',
    ...ldflags.split(' ').where((s) => s.isNotEmpty),
  ];

  final result = await Process.run(cc, args);
  if (result.exitCode != 0) {
    throw Exception(
      'Failed to convert archive to shared library:\n'
      'Command: $cc ${args.join(" ")}\n'
      'stderr: ${result.stderr}\n'
      'stdout: ${result.stdout}',
    );
  }
}
