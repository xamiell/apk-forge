import '../../core/system/host.dart';
import 'keystore.dart';

/// Which APK signature schemes to write. `null` leaves the choice to
/// apksigner, which picks by the APK's `minSdkVersion` (for example, no v1
/// from minSdk 24 on).
class SigningSchemes {
  const SigningSchemes({this.v1, this.v2, this.v3, this.v4});

  const SigningSchemes.automatic() : this();

  final bool? v1;
  final bool? v2;
  final bool? v3;
  final bool? v4;

  bool get isAutomatic => v1 == null && v2 == null && v3 == null && v4 == null;

  SigningSchemes copyWith({bool? v1, bool? v2, bool? v3, bool? v4}) =>
      SigningSchemes(
        v1: v1 ?? this.v1,
        v2: v2 ?? this.v2,
        v3: v3 ?? this.v3,
        v4: v4 ?? this.v4,
      );
}

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

List<String> apksignerVerifyArguments(String apk) => [
  'verify',
  '--verbose',
  '--print-certs',
  apk,
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
