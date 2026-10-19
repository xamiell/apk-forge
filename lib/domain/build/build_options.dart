/// The ABIs Flutter ships an Android engine for.
///
/// Flutter has had no 32-bit x86 engine since 2.0, so `x86` isn't offered.
enum AndroidAbi {
  armeabiV7a('armeabi-v7a', 'android-arm', '32-bit ARM, older phones and POS'),
  arm64V8a('arm64-v8a', 'android-arm64', '64-bit ARM, most devices'),
  x8664('x86_64', 'android-x64', 'Emulators and x86 tablets');

  const AndroidAbi(this.abiName, this.flutterTarget, this.description);

  /// The folder name under `lib/` in the APK.
  final String abiName;

  /// The value for `flutter build apk --target-platform`.
  final String flutterTarget;
  final String description;

  static AndroidAbi? fromAbiName(String name) {
    for (final abi in values) {
      if (abi.abiName == name) return abi;
    }
    return null;
  }
}

enum BuildMode {
  release('Release'),
  debug('Debug');

  const BuildMode(this.label);
  final String label;
}

enum ApkPackaging {
  /// One APK with every selected ABI inside.
  universal('Universal APK'),

  /// One APK per selected ABI (`--split-per-abi`).
  splitPerAbi('Split per ABI');

  const ApkPackaging(this.label);
  final String label;
}

class BuildOptions {
  const BuildOptions({
    this.projectDir = '',
    this.mode = BuildMode.release,
    this.abis = const {
      AndroidAbi.armeabiV7a,
      AndroidAbi.arm64V8a,
      AndroidAbi.x8664,
    },
    this.packaging = ApkPackaging.universal,
    this.obfuscate = false,
    this.symbolsDir = '',
    this.signAfterBuild = true,
  });

  /// What [toJson] saved, with [abis] from the Workbench's Defaults.
  factory BuildOptions.fromJson(
    Map<String, Object?> json, {
    required Set<AndroidAbi> abis,
  }) {
    const defaults = BuildOptions();
    return BuildOptions(
      projectDir: json['projectDir'] as String? ?? '',
      mode: BuildMode.values.asNameMap()[json['mode']] ?? defaults.mode,
      abis: abis,
      packaging:
          ApkPackaging.values.asNameMap()[json['packaging']] ??
          defaults.packaging,
      obfuscate: json['obfuscate'] as bool? ?? false,
      symbolsDir: json['symbolsDir'] as String? ?? '',
      signAfterBuild:
          json['signAfterBuild'] as bool? ?? defaults.signAfterBuild,
    );
  }

  final String projectDir;
  final BuildMode mode;
  final Set<AndroidAbi> abis;
  final ApkPackaging packaging;

  /// Dart obfuscation (`--obfuscate`). Release only. R8 for the Java and
  /// Kotlin side is the project's Gradle setting, not this.
  final bool obfuscate;

  /// Where `--split-debug-info` writes the symbols. Without them an
  /// obfuscated crash's stack trace can't be read.
  final String symbolsDir;

  /// Sign every APK the build produces with the keystore in the Sign panel.
  final bool signAfterBuild;

  /// Obfuscation only applies, and only reaches the command, in release.
  bool get effectiveObfuscate => obfuscate && mode == BuildMode.release;

  /// Splitting needs two ABIs or more. With one, it still makes a single
  /// APK, only renamed (`app-x86_64-release.apk`) and with the ABI's offset
  /// added to its versionCode.
  bool get canSplit => abis.length > 1;

  /// What the build makes: [packaging], or universal when there is nothing
  /// to split. [packaging] keeps the user's choice for when they select more
  /// ABIs again.
  ApkPackaging get effectivePackaging =>
      canSplit ? packaging : ApkPackaging.universal;

  /// What the build writes, in a line for the Build panel.
  String get outputSummary {
    final count = abis.length;
    if (count == 0) return 'Choose an architecture in Defaults.';
    if (effectivePackaging == ApkPackaging.splitPerAbi) {
      return 'One APK per architecture: $count APKs.';
    }
    if (count == 1) {
      return 'One APK for ${abis.single.abiName}. Split needs two or more '
          'architectures.';
    }
    return count == AndroidAbi.values.length
        ? 'One APK with every architecture.'
        : 'One APK with the $count architectures in Defaults.';
  }

  BuildOptions copyWith({
    String? projectDir,
    BuildMode? mode,
    Set<AndroidAbi>? abis,
    ApkPackaging? packaging,
    bool? obfuscate,
    String? symbolsDir,
    bool? signAfterBuild,
  }) => BuildOptions(
    projectDir: projectDir ?? this.projectDir,
    mode: mode ?? this.mode,
    abis: abis ?? this.abis,
    packaging: packaging ?? this.packaging,
    obfuscate: obfuscate ?? this.obfuscate,
    symbolsDir: symbolsDir ?? this.symbolsDir,
    signAfterBuild: signAfterBuild ?? this.signAfterBuild,
  );

  /// Everything but [abis], which the Workbench's Defaults keeps.
  Map<String, Object?> toJson() => {
    'projectDir': projectDir,
    'mode': mode.name,
    'packaging': packaging.name,
    'obfuscate': obfuscate,
    'symbolsDir': symbolsDir,
    'signAfterBuild': signAfterBuild,
  };
}
