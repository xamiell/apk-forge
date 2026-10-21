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

/// What a job that needs bundletool says when it isn't set.
const bundletoolMissing = ToolFailure(
  'bundletool was not found',
  details: [
    'It reads and installs App Bundles. Set it in Tools: the official jar '
        'from github.com/google/bundletool, or the bundletool command.',
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
    this.availableBuildTools = const [],
    this.apksigner,
    this.zipalign,
    this.aapt2,
    this.adb,
    this.keytool,
    this.jarsigner,
    this.java,
    this.javaVersion,
    this.bundletool,
    this.bundletoolVersion,
    this.problems = const [],
  });

  final String? flutter;
  final String? flutterVersion;
  final String? androidSdk;
  final String? buildToolsVersion;

  /// The build-tools versions in [androidSdk] that have `apksigner`, oldest
  /// first: what Tools offers.
  final List<String> availableBuildTools;
  final String? apksigner;
  final String? zipalign;
  final String? aapt2;
  final String? adb;
  final String? keytool;

  /// Signs App Bundles. It comes with the JDK, next to [keytool].
  final String? jarsigner;

  /// The JDK's `java`, next to [keytool]: it runs a bundletool jar.
  final String? java;

  /// What `java -version` says: `21.0.10`.
  final String? javaVersion;

  /// The bundletool jar, or the `bundletool` command.
  final String? bundletool;
  final String? bundletoolVersion;

  /// What Tools sets that can't be used, such as a folder that doesn't
  /// exist. That tool is then missing, rather than another one used.
  final List<String> problems;

  bool get canBuild => flutter != null;
  bool get canSign => apksigner != null;
  bool get canReadKeystore => keytool != null;
  bool get canInstall => adb != null;

  /// How to start bundletool: a jar with [java], or the command itself.
  /// `null` without bundletool, or with a jar and no `java`.
  ({String executable, List<String> arguments})? get bundletoolLaunch {
    final tool = bundletool;
    if (tool == null) return null;
    if (!isJar(tool)) return (executable: tool, arguments: const []);
    final java = this.java;
    return java == null ? null : (executable: java, arguments: ['-jar', tool]);
  }

  /// build-tools 35 added `zipalign -P <KB>`, which aligns uncompressed
  /// native libraries to 16 KB pages (required for Android 15's 16 KB page
  /// devices). Older ones only have `-p` (4 KB).
  bool get zipalignSupportsPageSize {
    final major = int.tryParse(buildToolsVersion?.split('.').first ?? '');
    return major != null && major >= 35;
  }

  /// This toolchain with the versions its tools report.
  ///
  /// Finding a tool only says its file exists: Tools takes any folder or
  /// file. One that ran but gave no version isn't that tool, so it's
  /// dropped with the reason, rather than shown as found:
  /// - Flutter, by `flutter --version`;
  /// - the JDK (keytool, jarsigner and java), by `java -version`;
  /// - bundletool, by `bundletool version`.
  Toolchain withVersions({String? flutter, String? java, String? bundletool}) {
    final notFlutter = this.flutter != null && flutter == null;
    final notJdk = this.java != null && java == null;
    final notBundletool = bundletoolLaunch != null && bundletool == null;
    return Toolchain(
      flutter: notFlutter ? null : this.flutter,
      flutterVersion: flutter,
      androidSdk: androidSdk,
      buildToolsVersion: buildToolsVersion,
      availableBuildTools: availableBuildTools,
      apksigner: apksigner,
      zipalign: zipalign,
      aapt2: aapt2,
      adb: adb,
      keytool: notJdk ? null : keytool,
      jarsigner: notJdk ? null : jarsigner,
      java: notJdk ? null : this.java,
      javaVersion: java,
      // A jar runs with that java: without it, bundletool can't run.
      bundletool:
          notBundletool ||
              (notJdk && this.bundletool != null && isJar(this.bundletool!))
          ? null
          : this.bundletool,
      bundletoolVersion: notJdk ? null : bundletool,
      problems: [
        ...problems,
        if (notFlutter)
          '${this.flutter} is not Flutter: it gave no version. Choose the '
              'Flutter SDK folder, the one with bin/flutter.',
        if (notJdk)
          '${this.java} is not a JDK\'s java: it gave no version. Choose a '
              'JDK folder, the one with bin/keytool.',
        if (notBundletool && !notJdk)
          '${this.bundletool} is not bundletool: it gave no version. Choose '
              'the bundletool jar, or the bundletool command.',
        if (notJdk && this.bundletool != null && isJar(this.bundletool!))
          'bundletool is a jar, which runs with the JDK\'s java: fix the JDK '
              'folder first.',
      ],
    );
  }
}

/// Whether [path] is a jar, which runs with `java -jar`.
bool isJar(String path) => path.toLowerCase().endsWith('.jar');

/// What the user set in Tools. Each one wins over anything detected; one
/// that can't be used leaves its tool missing, with a problem saying why.
class ToolOverrides {
  const ToolOverrides({
    this.flutterSdk,
    this.androidSdk,
    this.buildToolsVersion,
    this.jdkHome,
    this.bundletool,
  });

  factory ToolOverrides.fromJson(Map<String, Object?> json) => ToolOverrides(
    flutterSdk: json['flutterSdk'] as String?,
    androidSdk: json['androidSdk'] as String?,
    buildToolsVersion: json['buildToolsVersion'] as String?,
    jdkHome: json['jdkHome'] as String?,
    bundletool: json['bundletool'] as String?,
  );

  final String? flutterSdk;
  final String? androidSdk;

  /// One of the Android SDK's build-tools versions. `null`: the newest.
  final String? buildToolsVersion;

  /// A JDK's folder: `keytool`, `jarsigner` and `java` are in its `bin/`.
  final String? jdkHome;

  /// The bundletool jar, or the `bundletool` command.
  final String? bundletool;

  /// A `null` argument keeps the value; an empty one clears it once
  /// [cleaned].
  ToolOverrides copyWith({
    String? flutterSdk,
    String? androidSdk,
    String? buildToolsVersion,
    String? jdkHome,
    String? bundletool,
  }) => ToolOverrides(
    flutterSdk: flutterSdk ?? this.flutterSdk,
    androidSdk: androidSdk ?? this.androidSdk,
    buildToolsVersion: buildToolsVersion ?? this.buildToolsVersion,
    jdkHome: jdkHome ?? this.jdkHome,
    bundletool: bundletool ?? this.bundletool,
  );

  /// Each value trimmed, and `null` when it's empty.
  ToolOverrides cleaned() {
    String? clean(String? value) =>
        (value == null || value.trim().isEmpty) ? null : value.trim();
    return ToolOverrides(
      flutterSdk: clean(flutterSdk),
      androidSdk: clean(androidSdk),
      buildToolsVersion: clean(buildToolsVersion),
      jdkHome: clean(jdkHome),
      bundletool: clean(bundletool),
    );
  }

  Map<String, Object?> toJson() => {
    'flutterSdk': flutterSdk,
    'androidSdk': androidSdk,
    'buildToolsVersion': buildToolsVersion,
    'jdkHome': jdkHome,
    'bundletool': bundletool,
  };

  @override
  bool operator ==(Object other) =>
      other is ToolOverrides &&
      other.flutterSdk == flutterSdk &&
      other.androidSdk == androidSdk &&
      other.buildToolsVersion == buildToolsVersion &&
      other.jdkHome == jdkHome &&
      other.bundletool == bundletool;

  @override
  int get hashCode => Object.hash(
    flutterSdk,
    androidSdk,
    buildToolsVersion,
    jdkHome,
    bundletool,
  );
}

/// Finds the tools the way a developer's terminal would, after what Tools
/// sets ([ToolOverrides]).
///
/// - Android SDK: `ANDROID_HOME`, `ANDROID_SDK_ROOT`, then the folder
///   Android Studio installs to on each OS.
/// - build-tools: the newest version that has `apksigner`.
/// - Flutter: `PATH`.
/// - The JDK: keytool from `JAVA_HOME`, `PATH`, then Android Studio's
///   bundled JDK. jarsigner and java are next to keytool.
/// - bundletool: `PATH`, then Homebrew's `bin`.
class ToolchainLocator {
  const ToolchainLocator({required this.host, required this.probe});

  final Host host;
  final FileProbe probe;

  Toolchain locate(ToolOverrides overrides) {
    final problems = <String>[];
    final sdk = _androidSdk(overrides.androidSdk, problems);
    final available = sdk == null ? const <String>[] : _buildToolsVersions(sdk);
    final buildTools = _buildTools(
      overrides.buildToolsVersion,
      available,
      sdkFound: sdk != null,
      problems: problems,
    );
    final buildToolsDir = buildTools == null
        ? null
        : host.path.join(sdk!, 'build-tools', buildTools);

    String? inBuildTools(String name) {
      if (buildToolsDir == null) return null;
      final candidate = host.path.join(buildToolsDir, name);
      return probe.fileExists(candidate) ? candidate : null;
    }

    final keytool = _keytool(overrides.jdkHome, problems);
    final java = keytool == null ? null : _nextTo(keytool, 'java');
    final bundletool = _bundletool(overrides.bundletool, problems);
    if (bundletool != null && isJar(bundletool) && java == null) {
      problems.add(
        'bundletool is a jar, and no java was found to run it: set the JDK '
        'folder.',
      );
    }

    return Toolchain(
      flutter: _flutter(overrides.flutterSdk, problems),
      androidSdk: sdk,
      buildToolsVersion: buildTools,
      availableBuildTools: available,
      apksigner: inBuildTools(
        host.executableName('apksigner', windowsExtension: '.bat'),
      ),
      zipalign: inBuildTools(host.executableName('zipalign')),
      aapt2: inBuildTools(host.executableName('aapt2')),
      adb: _adb(sdk, sdkSet: overrides.androidSdk != null),
      keytool: keytool,
      jarsigner: keytool == null ? null : _nextTo(keytool, 'jarsigner'),
      java: java,
      bundletool: bundletool,
      problems: problems,
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

  /// A folder with `build-tools` or `platform-tools` in it: any other
  /// folder isn't an Android SDK, though it exists.
  bool _isAndroidSdk(String folder) =>
      probe.directoryExists(host.path.join(folder, 'build-tools')) ||
      probe.directoryExists(host.path.join(folder, 'platform-tools'));

  String? _androidSdk(String? override, List<String> problems) {
    if (override != null) {
      if (!probe.directoryExists(override)) {
        problems.add('The Android SDK folder $override does not exist.');
      } else if (!_isAndroidSdk(override)) {
        problems.add(
          '$override is not an Android SDK: it has no build-tools or '
          'platform-tools folder.',
        );
      } else {
        return override;
      }
      return null;
    }
    final home = host.home;
    final candidates = [
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
          probe.directoryExists(candidate) &&
          _isAndroidSdk(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  /// The build-tools versions in [sdk] that have `apksigner`, oldest first.
  List<String> _buildToolsVersions(String sdk) {
    final apksigner = host.executableName(
      'apksigner',
      windowsExtension: '.bat',
    );
    return probe
        .directoryNames(host.path.join(sdk, 'build-tools'))
        .where(
          (version) => probe.fileExists(
            host.path.join(sdk, 'build-tools', version, apksigner),
          ),
        )
        .toList()
      ..sort(compareVersions);
  }

  String? _buildTools(
    String? override,
    List<String> available, {
    required bool sdkFound,
    required List<String> problems,
  }) {
    if (override == null) return available.isEmpty ? null : available.last;
    if (available.contains(override)) return override;
    if (sdkFound) {
      problems.add('build-tools $override is not in the Android SDK.');
    }
    return null;
  }

  String? _flutter(String? sdkOverride, List<String> problems) {
    final name = host.executableName('flutter', windowsExtension: '.bat');
    if (sdkOverride != null) {
      final candidate = host.path.join(sdkOverride, 'bin', name);
      if (probe.fileExists(candidate)) return candidate;
      problems.add('The Flutter SDK folder $sdkOverride has no bin/$name.');
      return null;
    }
    return findOnPath(name, host, probe);
  }

  /// adb from the Android SDK. With an SDK set in Tools, only from that
  /// one: never another adb in its place.
  String? _adb(String? sdk, {required bool sdkSet}) {
    final name = host.executableName('adb');
    if (sdk != null) {
      final candidate = host.path.join(sdk, 'platform-tools', name);
      if (probe.fileExists(candidate)) return candidate;
    }
    return sdkSet ? null : findOnPath(name, host, probe);
  }

  String? _keytool(String? jdkHome, List<String> problems) {
    final name = host.executableName('keytool');
    if (jdkHome != null) {
      // A macOS JDK bundle (`….jdk`) keeps its tools in Contents/Home.
      for (final home in [
        jdkHome,
        if (host.os == HostOs.macos)
          host.path.join(jdkHome, 'Contents', 'Home'),
      ]) {
        final candidate = host.path.join(home, 'bin', name);
        if (probe.fileExists(candidate)) return candidate;
      }
      problems.add('The JDK folder $jdkHome has no bin/$name.');
      return null;
    }
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

  String? _bundletool(String? override, List<String> problems) {
    if (override != null) {
      if (probe.fileExists(override)) return override;
      problems.add('bundletool $override does not exist.');
      return null;
    }
    final name = host.executableName('bundletool', windowsExtension: '.bat');
    final onPath = findOnPath(name, host, probe);
    if (onPath != null) return onPath;
    // An app opened from Finder may lack Homebrew in its PATH.
    for (final homebrew in const ['/opt/homebrew/bin', '/usr/local/bin']) {
      if (host.os == HostOs.windows) break;
      final candidate = host.path.join(homebrew, name);
      if (probe.fileExists(candidate)) return candidate;
    }
    return null;
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
