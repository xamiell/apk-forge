import '../../core/system/host.dart';
import '../failure.dart';

/// What a job that needs keytool says when it isn't found.
const keytoolMissing = ToolFailure(
  'keytool was not found',
  details: ['Install a JDK, or set JAVA_HOME.'],
);

/// What signing an App Bundle says when jarsigner isn't found.
const jarsignerMissing = ToolFailure(
  'jarsigner was not found',
  details: [
    'It comes with a JDK, next to keytool. Install a JDK, or set JAVA_HOME.',
  ],
);

/// The external programs the app drives, as found on this machine.
///
/// A `null` path means the tool wasn't found, and the panels that need it
/// say so instead of failing at the first click.
class Toolchain {
  const Toolchain({
    this.flutter,
    this.flutterVersion,
    this.androidSdk,
    this.buildToolsVersion,
    this.apksigner,
    this.zipalign,
    this.aapt2,
    this.adb,
    this.keytool,
    this.jarsigner,
  });

  final String? flutter;
  final String? flutterVersion;
  final String? androidSdk;
  final String? buildToolsVersion;
  final String? apksigner;
  final String? zipalign;
  final String? aapt2;
  final String? adb;
  final String? keytool;

  /// Signs App Bundles. It comes with the JDK, next to [keytool].
  final String? jarsigner;

  bool get canBuild => flutter != null;
  bool get canSign => apksigner != null;
  bool get canReadKeystore => keytool != null;
  bool get canInstall => adb != null;

  /// build-tools 35 added `zipalign -P <KB>`, which aligns uncompressed
  /// native libraries to 16 KB pages (required for Android 15's 16 KB page
  /// devices). Older ones only have `-p` (4 KB).
  bool get zipalignSupportsPageSize {
    final major = int.tryParse(buildToolsVersion?.split('.').first ?? '');
    return major != null && major >= 35;
  }

  Toolchain withFlutterVersion(String? version) => Toolchain(
    flutter: flutter,
    flutterVersion: version,
    androidSdk: androidSdk,
    buildToolsVersion: buildToolsVersion,
    apksigner: apksigner,
    zipalign: zipalign,
    aapt2: aapt2,
    adb: adb,
    keytool: keytool,
    jarsigner: jarsigner,
  );
}

/// Folders the user set by hand. They win over anything detected.
class ToolOverrides {
  const ToolOverrides({this.flutterSdk, this.androidSdk});

  factory ToolOverrides.fromJson(Map<String, Object?> json) => ToolOverrides(
    flutterSdk: json['flutterSdk'] as String?,
    androidSdk: json['androidSdk'] as String?,
  );

  final String? flutterSdk;
  final String? androidSdk;

  Map<String, Object?> toJson() => {
    'flutterSdk': flutterSdk,
    'androidSdk': androidSdk,
  };
}

/// Finds the tools the way a developer's terminal would.
///
/// Android SDK: the override, `ANDROID_HOME`, `ANDROID_SDK_ROOT`, then the
/// folder Android Studio installs to on each OS. build-tools: the newest
/// version that has `apksigner`. Flutter: the override, then `PATH`. keytool:
/// `JAVA_HOME`, `PATH`, then Android Studio's bundled JDK. jarsigner: next to
/// keytool, in the same JDK.
class ToolchainLocator {
  const ToolchainLocator({required this.host, required this.probe});

  final Host host;
  final FileProbe probe;

  Toolchain locate(ToolOverrides overrides) {
    final sdk = _androidSdk(overrides.androidSdk);
    final buildTools = sdk == null ? null : _newestBuildTools(sdk);
    final buildToolsDir = buildTools == null
        ? null
        : host.path.join(sdk!, 'build-tools', buildTools);

    String? inBuildTools(String name) {
      if (buildToolsDir == null) return null;
      final candidate = host.path.join(buildToolsDir, name);
      return probe.fileExists(candidate) ? candidate : null;
    }

    final keytool = _keytool();
    return Toolchain(
      flutter: _flutter(overrides.flutterSdk),
      androidSdk: sdk,
      buildToolsVersion: buildTools,
      apksigner: inBuildTools(
        host.executableName('apksigner', windowsExtension: '.bat'),
      ),
      zipalign: inBuildTools(host.executableName('zipalign')),
      aapt2: inBuildTools(host.executableName('aapt2')),
      adb: _adb(sdk),
      keytool: keytool,
      jarsigner: keytool == null ? null : _nextTo(keytool, 'jarsigner'),
    );
  }

  /// [name] in [tool]'s folder, when it's there.
  String? _nextTo(String tool, String name) {
    final candidate = host.path.join(
      host.path.dirname(tool),
      host.executableName(name),
    );
    return probe.fileExists(candidate) ? candidate : null;
  }

  String? _androidSdk(String? override) {
    final home = host.home;
    final candidates = [
      override,
      host.environment['ANDROID_HOME'],
      host.environment['ANDROID_SDK_ROOT'],
      if (home != null)
        switch (host.os) {
          HostOs.macos => host.path.join(home, 'Library', 'Android', 'sdk'),
          HostOs.linux => host.path.join(home, 'Android', 'Sdk'),
          HostOs.windows => host.path.join(
            host.environment['LOCALAPPDATA'] ??
                host.path.join(home, 'AppData', 'Local'),
            'Android',
            'Sdk',
          ),
        },
    ];
    for (final candidate in candidates) {
      if (candidate != null &&
          candidate.isNotEmpty &&
          probe.directoryExists(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  String? _newestBuildTools(String sdk) {
    final apksigner = host.executableName(
      'apksigner',
      windowsExtension: '.bat',
    );
    final versions =
        probe
            .directoryNames(host.path.join(sdk, 'build-tools'))
            .where(
              (version) => probe.fileExists(
                host.path.join(sdk, 'build-tools', version, apksigner),
              ),
            )
            .toList()
          ..sort(compareVersions);
    return versions.isEmpty ? null : versions.last;
  }

  String? _flutter(String? sdkOverride) {
    final name = host.executableName('flutter', windowsExtension: '.bat');
    if (sdkOverride != null && sdkOverride.isNotEmpty) {
      final candidate = host.path.join(sdkOverride, 'bin', name);
      if (probe.fileExists(candidate)) return candidate;
    }
    return findOnPath(name, host, probe);
  }

  String? _adb(String? sdk) {
    final name = host.executableName('adb');
    if (sdk != null) {
      final candidate = host.path.join(sdk, 'platform-tools', name);
      if (probe.fileExists(candidate)) return candidate;
    }
    return findOnPath(name, host, probe);
  }

  String? _keytool() {
    final name = host.executableName('keytool');
    final javaHome = host.environment['JAVA_HOME'];
    if (javaHome != null && javaHome.isNotEmpty) {
      final candidate = host.path.join(javaHome, 'bin', name);
      if (probe.fileExists(candidate)) return candidate;
    }
    final onPath = findOnPath(name, host, probe);
    if (onPath != null) return onPath;

    final studioJdk = switch (host.os) {
      HostOs.macos => '/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool',
      HostOs.linux => '/opt/android-studio/jbr/bin/keytool',
      HostOs.windows =>
        r'C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe',
    };
    return probe.fileExists(studioJdk) ? studioJdk : null;
  }
}

/// Orders `34.0.0`, `35.0.0-rc1`, `36.0.0` by their numbers. A pre-release
/// sorts before its release.
int compareVersions(String a, String b) {
  List<int> numbers(String version) => version
      .split('-')
      .first
      .split('.')
      .map((part) => int.tryParse(part) ?? 0)
      .toList();

  final left = numbers(a);
  final right = numbers(b);
  for (var index = 0; index < left.length || index < right.length; index++) {
    final x = index < left.length ? left[index] : 0;
    final y = index < right.length ? right[index] : 0;
    if (x != y) return x.compareTo(y);
  }
  final aPre = a.contains('-');
  final bPre = b.contains('-');
  if (aPre != bPre) return aPre ? -1 : 1;
  return a.compareTo(b);
}
