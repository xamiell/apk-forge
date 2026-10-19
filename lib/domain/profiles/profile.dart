import '../build/build_options.dart';
import '../signing/signing.dart';

/// One APK a profile writes: for a device, with its ABI and its key.
class ProfileTarget {
  const ProfileTarget({
    required this.id,
    required this.name,
    this.abi,
    this.keyProperties = '',
    this.schemes = const SigningSchemes.automatic(),
    this.outputDir = '',
  });

  factory ProfileTarget.fromJson(Map<String, Object?> json) => ProfileTarget(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    abi: AndroidAbi.fromAbiName(json['abi'] as String? ?? ''),
    keyProperties: json['keyProperties'] as String? ?? '',
    schemes: _schemesFromJson(json['schemes']),
    outputDir: json['outputDir'] as String? ?? '',
  );

  final String id;

  /// What the device is called, for the file name and the results.
  final String name;

  /// The ABI the APK keeps; `null` keeps them all (universal).
  final AndroidAbi? abi;

  /// The path of a `key.properties`, never its contents: the passwords stay
  /// in the file and are read when a run starts.
  final String keyProperties;
  final SigningSchemes schemes;
  final String outputDir;

  ProfileTarget copyWith({
    String? id,
    String? name,
    AndroidAbi? abi,
    bool universal = false,
    String? keyProperties,
    SigningSchemes? schemes,
    String? outputDir,
  }) => ProfileTarget(
    id: id ?? this.id,
    name: name ?? this.name,
    abi: universal ? null : abi ?? this.abi,
    keyProperties: keyProperties ?? this.keyProperties,
    schemes: schemes ?? this.schemes,
    outputDir: outputDir ?? this.outputDir,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'abi': abi?.abiName,
    'keyProperties': keyProperties,
    'schemes': _schemesToJson(schemes),
    'outputDir': outputDir,
  };
}

/// What the input APK must be before anything is signed.
class InputChecks {
  const InputChecks({this.packageName, this.mustBeUnsigned = false});

  factory InputChecks.fromJson(Map<String, Object?>? json) {
    final package = (json?['packageName'] as String?)?.trim();
    return InputChecks(
      packageName: package == null || package.isEmpty ? null : package,
      mustBeUnsigned: json?['mustBeUnsigned'] as bool? ?? false,
    );
  }

  /// `null` takes any package.
  final String? packageName;
  final bool mustBeUnsigned;

  Map<String, Object?> toJson() => {
    'packageName': packageName,
    'mustBeUnsigned': mustBeUnsigned,
  };
}

enum AfterRun {
  openFolders('Open the output folders'),
  nothing('Nothing');

  const AfterRun(this.label);
  final String label;
}

/// Saved steps to turn one APK into a signed APK per device.
class SigningProfile {
  const SigningProfile({
    required this.id,
    required this.name,
    this.input = const InputChecks(),
    this.targets = const [],
    this.fileNamePattern = defaultFileNamePattern,
    this.afterRun = AfterRun.openFolders,
  });

  factory SigningProfile.fromJson(Map<String, Object?> json) => SigningProfile(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    input: InputChecks.fromJson(json['input'] as Map<String, Object?>?),
    targets: [
      for (final target in json['targets'] as List<Object?>? ?? const [])
        if (target is Map<String, Object?>) ProfileTarget.fromJson(target),
    ],
    fileNamePattern:
        json['fileNamePattern'] as String? ?? defaultFileNamePattern,
    afterRun: AfterRun.values.firstWhere(
      (value) => value.name == json['afterRun'],
      orElse: () => AfterRun.openFolders,
    ),
  );

  static const defaultFileNamePattern = '{name}-{target}';

  final String id;
  final String name;
  final InputChecks input;
  final List<ProfileTarget> targets;

  /// See [profileFileName] for the tokens.
  final String fileNamePattern;
  final AfterRun afterRun;

  /// The distinct `key.properties` files the targets use, in order.
  List<String> get keyFiles => <String>{
    for (final target in targets)
      if (target.keyProperties.isNotEmpty) target.keyProperties,
  }.toList();

  SigningProfile copyWith({
    String? id,
    String? name,
    InputChecks? input,
    List<ProfileTarget>? targets,
    String? fileNamePattern,
    AfterRun? afterRun,
  }) => SigningProfile(
    id: id ?? this.id,
    name: name ?? this.name,
    input: input ?? this.input,
    targets: targets ?? this.targets,
    fileNamePattern: fileNamePattern ?? this.fileNamePattern,
    afterRun: afterRun ?? this.afterRun,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'input': input.toJson(),
    'targets': [for (final target in targets) target.toJson()],
    'fileNamePattern': fileNamePattern,
    'afterRun': afterRun.name,
  };
}

Map<String, Object?> _schemesToJson(SigningSchemes schemes) => {
  'v1': schemes.v1,
  'v2': schemes.v2,
  'v3': schemes.v3,
  'v4': schemes.v4,
};

SigningSchemes _schemesFromJson(Object? json) {
  if (json is! Map<String, Object?>) return const SigningSchemes.automatic();
  return SigningSchemes(
    v1: json['v1'] as bool?,
    v2: json['v2'] as bool?,
    v3: json['v3'] as bool?,
    v4: json['v4'] as bool?,
  );
}

/// The tokens a file name pattern can use.
const fileNameTokens = [
  '{name}',
  '{target}',
  '{abi}',
  '{versionName}',
  '{versionCode}',
  '{date}',
];

/// [pattern] with its tokens filled, plus `.apk`:
///
/// - `{name}`: the input APK's name without `.apk`;
/// - `{target}`: the target's name;
/// - `{abi}`: its ABI, or `universal`;
/// - `{versionName}`, `{versionCode}`: from the input's manifest;
/// - `{date}`: [date] as `yyyyMMdd`.
///
/// A character a file name can't hold on any OS becomes `_`.
String profileFileName(
  String pattern, {
  required String name,
  required String target,
  required String abi,
  String? versionName,
  String? versionCode,
  required DateTime date,
}) {
  String two(int value) => value.toString().padLeft(2, '0');
  final filled = pattern
      .replaceAll('{name}', name)
      .replaceAll('{target}', target)
      .replaceAll('{abi}', abi)
      .replaceAll('{versionName}', versionName ?? 'unknown')
      .replaceAll('{versionCode}', versionCode ?? 'unknown')
      .replaceAll('{date}', '${date.year}${two(date.month)}${two(date.day)}');
  final safe = filled.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  return safe.toLowerCase().endsWith('.apk') ? safe : '$safe.apk';
}

/// What's wrong with a file name pattern: empty, or an unknown `{token}`.
List<String> fileNamePatternProblems(String pattern) {
  if (pattern.trim().isEmpty) return const ['The file name pattern is empty.'];
  final unknown = RegExp(r'\{[^}]*\}')
      .allMatches(pattern)
      .map((match) => match.group(0)!)
      .where((token) => !fileNameTokens.contains(token))
      .toSet();
  return [
    for (final token in unknown)
      '$token is not a token: use ${fileNameTokens.join(', ')}.',
  ];
}
