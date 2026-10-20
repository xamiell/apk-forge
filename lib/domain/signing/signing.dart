import '../../core/system/host.dart';
import 'keystore.dart';

/// Which APK signature schemes to write. `null` leaves the choice to
/// apksigner, which picks by the APK's `minSdkVersion` (for example, no v1
/// from minSdk 24 on).
class SigningSchemes {
  const SigningSchemes({this.v1, this.v2, this.v3, this.v4});

  const SigningSchemes.automatic() : this();

  /// Anything but a map is [SigningSchemes.automatic].
  factory SigningSchemes.fromJson(Object? json) {
    if (json is! Map<String, Object?>) return const SigningSchemes.automatic();
    return SigningSchemes(
      v1: json['v1'] as bool?,
      v2: json['v2'] as bool?,
      v3: json['v3'] as bool?,
      v4: json['v4'] as bool?,
    );
  }

  final bool? v1;
  final bool? v2;
  final bool? v3;
  final bool? v4;

  bool get isAutomatic => v1 == null && v2 == null && v3 == null && v4 == null;

  /// Why apksigner can't sign with the ones marked, or `null`. With v1, v2
  /// and v3 off it writes an APK with no signature and exits 0; v4 without
  /// v2 or v3 makes it fail (build-tools 36). A `null` scheme is
  /// apksigner's choice, and it picks v2 and v3 unless told not to.
  String? get problem {
    final v2OrV3 = v2 != false || v3 != false;
    if (v1 != true && !v2OrV3) return 'Mark v1, v2 or v3.';
    if (v4 == true && !v2OrV3) return 'v4 needs v2 or v3.';
    return null;
  }

  /// "Auto", or the ones marked: "v2, v3".
  String get label {
    if (isAutomatic) return 'Auto';
    final marked = [
      if (v1 ?? false) 'v1',
      if (v2 ?? false) 'v2',
      if (v3 ?? false) 'v3',
      if (v4 ?? false) 'v4',
    ];
    return marked.isEmpty ? 'none marked' : marked.join(', ');
  }

  Map<String, Object?> toJson() => {'v1': v1, 'v2': v2, 'v3': v3, 'v4': v4};

  @override
  bool operator ==(Object other) =>
      other is SigningSchemes &&
      other.v1 == v1 &&
      other.v2 == v2 &&
      other.v3 == v3 &&
      other.v4 == v4;

  @override
  int get hashCode => Object.hash(v1, v2, v3, v4);

  SigningSchemes copyWith({bool? v1, bool? v2, bool? v3, bool? v4}) =>
      SigningSchemes(
        v1: v1 ?? this.v1,
        v2: v2 ?? this.v2,
        v3: v3 ?? this.v3,
        v4: v4 ?? this.v4,
      );
}

/// Why the schemes in the Workbench's Defaults can't sign, as Sign and a
/// profile run say it, or `null`.
String? defaultSchemesProblem(SigningSchemes schemes) =>
    switch (schemes.problem) {
      null => null,
      final problem => 'Signature schemes in Defaults: $problem',
    };

class SigningRequest {
  const SigningRequest({
    required this.keystorePath,
    required this.storePassword,
    required this.alias,
    this.keyPassword,
    this.schemes = const SigningSchemes.automatic(),
    this.outputDir,
  });

  final String keystorePath;
  final String storePassword;
  final String alias;

  /// `null` when the key uses the keystore's password, as most do.
  final String? keyPassword;
  final SigningSchemes schemes;

  /// `null` writes the signed APK next to the original.
  final String? outputDir;

  /// This request, writing to [directory] unless it has an output folder of
  /// its own. A split is signed from a temporary folder; its signed APK
  /// goes next to the APK it was split from.
  SigningRequest withDefaultOutputDir(String directory) => outputDir != null
      ? this
      : SigningRequest(
          keystorePath: keystorePath,
          storePassword: storePassword,
          alias: alias,
          keyPassword: keyPassword,
          schemes: schemes,
          outputDir: directory,
        );

  List<String> get secrets => [storePassword, ?keyPassword];

  Map<String, String> get environment => {
    keystorePasswordVariable: storePassword,
    keyPasswordVariable: ?keyPassword,
  };
}

/// `apksigner sign` arguments. The passwords are read from the environment
/// ([SigningRequest.environment]), so they never appear here.
List<String> apksignerSignArguments(
  SigningRequest request, {
  required String input,
  required String output,
}) {
  String flag(bool value) => value ? 'true' : 'false';
  final schemes = request.schemes;
  return [
    'sign',
    '--ks',
    request.keystorePath,
    '--ks-pass',
    'env:$keystorePasswordVariable',
    '--ks-key-alias',
    request.alias,
    if (request.keyPassword != null) ...[
      '--key-pass',
      'env:$keyPasswordVariable',
    ],
    if (schemes.v1 != null) ...['--v1-signing-enabled', flag(schemes.v1!)],
    if (schemes.v2 != null) ...['--v2-signing-enabled', flag(schemes.v2!)],
    if (schemes.v3 != null) ...['--v3-signing-enabled', flag(schemes.v3!)],
    if (schemes.v4 != null) ...['--v4-signing-enabled', flag(schemes.v4!)],
    '--out',
    output,
    input,
  ];
}

/// Why `apksigner sign` couldn't open the key: which password, and what to
/// do in Sign.
enum KeyLoadFailure {
  keyPasswordMissing(
    'The key has a password of its own.',
    'Untick "The key uses the keystore password" and enter the key password.',
  ),
  keyPasswordWrong(
    'The key password is wrong.',
    'Enter the key\'s own password, or tick "The key uses the keystore '
        'password" if it has none.',
  ),
  storePasswordWrong(
    'The keystore password is wrong.',
    'Enter the keystore password again and load the keys.',
  );

  const KeyLoadFailure(this.problem, this.fix);

  final String problem;
  final String fix;
}

/// Why `apksigner sign` couldn't open the key, from its output; `null` when
/// it failed for another reason.
///
/// Without `--key-pass` it asks for the key password on its input, which
/// the app closes: "Failed to read … password …: standard input closed".
KeyLoadFailure? parseKeyLoadFailure(Iterable<String> lines) {
  for (final line in lines) {
    if (line.contains(
      'Keystore was tampered with, or password was incorrect',
    )) {
      return KeyLoadFailure.storePasswordWrong;
    }
    if (line.contains('Failed to obtain key with alias') ||
        line.contains('UnrecoverableKeyException: Cannot recover key')) {
      return KeyLoadFailure.keyPasswordWrong;
    }
    if (line.contains('Failed to read') && line.contains('password')) {
      return KeyLoadFailure.keyPasswordMissing;
    }
  }
  return null;
}

List<String> apksignerVerifyArguments(String apk) => [
  'verify',
  '--verbose',
  '--print-certs',
  apk,
];

/// `apksigner lineage` arguments that print [apk]'s key rotation, which
/// `verify` doesn't show.
List<String> apksignerLineageArguments(String apk) => [
  'lineage',
  '--in',
  apk,
  '--print-certs',
];

/// Where the signed copy of [input] goes: `<name>-signed.apk` in
/// [outputDir], or next to [input]. Never [input] itself: a failed signing
/// must leave the original intact.
String signedApkPath(String input, String? outputDir, Host host) {
  final path = host.path;
  final directory = (outputDir == null || outputDir.trim().isEmpty)
      ? path.dirname(input)
      : outputDir.trim();
  final base = path.basenameWithoutExtension(input);
  var candidate = path.join(directory, '$base-signed.apk');
  var copy = 2;
  while (path.equals(candidate, input)) {
    candidate = path.join(directory, '$base-signed-$copy.apk');
    copy++;
  }
  return candidate;
}

/// `zipalign` arguments to check [apk]'s alignment, or to write an aligned
/// copy to [output] when it's given.
///
/// With build-tools 35+, `-P 16` aligns uncompressed native libraries to
/// 16 KB pages, as Android 15+ devices with 16 KB pages require; older
/// build-tools only have `-p` (4 KB pages).
List<String> zipalignArguments(
  String apk, {
  String? output,
  required bool supportsPageSize,
}) => [
  if (output == null) '-c' else '-f',
  if (supportsPageSize) ...['-P', '16'] else '-p',
  '4',
  apk,
  ?output,
];
