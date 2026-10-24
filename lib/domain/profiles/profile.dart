import 'dart:convert';

import '../build/build_options.dart';
import '../signing/signing.dart';

/// One APK a profile writes: for a device, with its ABI and its key.
class ProfileTarget {
  const ProfileTarget({
    required this.id,
    required this.name,
    this.abi,
    this.keyProperties = '',
    this.schemes,
    this.outputDir = '',
  });

  factory ProfileTarget.fromJson(Map<String, Object?> json) => ProfileTarget(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    abi: AndroidAbi.fromAbiName(json['abi'] as String? ?? ''),
    keyProperties: json['keyProperties'] as String? ?? '',
    schemes: json['schemes'] == null
        ? null
        : SigningSchemes.fromJson(json['schemes']),
    outputDir: json['outputDir'] as String? ?? '',
  );

  final String id;

  /// What the device is called, for the file name and the results.
  final String name;

  /// What a target that keeps every ABI is called in file names and tables.
  static const universalAbiName = 'universal';

  /// The ABI the APK keeps; `null` keeps them all (universal).
  final AndroidAbi? abi;

  /// The path of a `key.properties`, never its contents: the passwords stay
  /// in the file and are read when a run starts.
  final String keyProperties;

  /// `null` follows the schemes in the Workbench's Defaults, as they are
  /// when the profile runs.
  final SigningSchemes? schemes;
  final String outputDir;

  /// [abi]'s folder name, or [universalAbiName].
  String get abiName => abi?.abiName ?? universalAbiName;

  @override
  bool operator ==(Object other) =>
      other is ProfileTarget &&
      other.id == id &&
      other.name == name &&
      other.abi == abi &&
      other.keyProperties == keyProperties &&
      other.schemes == schemes &&
      other.outputDir == outputDir;

  @override
  int get hashCode =>
      Object.hash(id, name, abi, keyProperties, schemes, outputDir);

  ProfileTarget copyWith({
    String? id,
    String? name,
    AndroidAbi? abi,
    bool universal = false,
    String? keyProperties,
    SigningSchemes? schemes,
    bool defaultSchemes = false,
    String? outputDir,
  }) => ProfileTarget(
    id: id ?? this.id,
    name: name ?? this.name,
    abi: universal ? null : abi ?? this.abi,
    keyProperties: keyProperties ?? this.keyProperties,
    schemes: defaultSchemes ? null : schemes ?? this.schemes,
    outputDir: outputDir ?? this.outputDir,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'abi': abi?.abiName,
    'keyProperties': keyProperties,
    'schemes': schemes?.toJson(),
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

/// [name], or `<name> 2`, `<name> 3`… when [taken] already has it, ignoring
/// case: two profiles that look the same in the list can't be told apart,
/// nor asked for by name.
String uniqueProfileName(String name, Iterable<String> taken) {
  final names = {for (final other in taken) other.toLowerCase()};
  if (!names.contains(name.toLowerCase())) return name;
  for (var copy = 2; ; copy++) {
    final candidate = '$name $copy';
    if (!names.contains(candidate.toLowerCase())) return candidate;
  }
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

/// What `{name}` stands for: the app's [label] in lowercase, with `-` for
/// spaces ("My App" is `my-app`); without one, the last part of its
/// [packageName] (`com.example.app` is `app`); without either, [fileName],
/// the input's name without its extension.
String profileAppName({
  String? label,
  String? packageName,
  required String fileName,
}) {
  final fromLabel = label?.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');
  if (fromLabel != null && fromLabel.isNotEmpty) return fromLabel;
  final fromPackage = packageName?.trim().split('.').last.toLowerCase();
  if (fromPackage != null && fromPackage.isNotEmpty) return fromPackage;
  return fileName;
}

/// [pattern] with its tokens filled, as a signed APK's file name:
///
/// - `{name}`: the app's name ([profileAppName]);
/// - `{target}`: the target's name;
/// - `{abi}`: its ABI, or `universal`;
/// - `{versionName}`, `{versionCode}`: from the input's manifest;
/// - `{date}`: [date] as `yyyyMMdd`.
///
/// A character a file name can't hold on any OS becomes `_`. The name ends
/// in `-signed.apk`, as Sign's do, unless [pattern] already says "signed".
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
  return _signedApkName(safeFileName(filled), pattern);
}

/// [pattern] as the file names it makes, its tokens unfilled:
/// `{name}-{target}` makes `{name}-{target}-signed.apk`.
String signedFileNamePattern(String pattern) =>
    _signedApkName(pattern.trim(), pattern);

final _token = RegExp(r'\{[^}]*\}');

/// "signed" as a word, so `unsigned` doesn't count.
final _signedWord = RegExp(r'(?<![a-z])signed(?![a-z])', caseSensitive: false);

/// [name] without `.apk`, then `-signed` unless the text of [pattern]
/// outside its tokens says "signed", then `.apk`.
String _signedApkName(String name, String pattern) {
  final stem = name.toLowerCase().endsWith('.apk')
      ? name.substring(0, name.length - '.apk'.length)
      : name;
  final saysSigned = _signedWord.hasMatch(pattern.replaceAll(_token, ' '));
  return saysSigned ? '$stem.apk' : '$stem-signed.apk';
}

/// [name] with each character a file name can't hold on any OS turned
/// into `_`.
String safeFileName(String name) =>
    name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();

const _exportFormat = 'apk-forge-profile';

/// [profile] as a file to share: its paths and choices, never a password.
String exportProfile(SigningProfile profile) => const JsonEncoder.withIndent(
  '  ',
).convert({'format': _exportFormat, 'version': 1, 'profile': profile.toJson()});

/// The profile in a file [exportProfile] wrote. Throws a [FormatException]
/// for anything else.
SigningProfile importProfile(String text) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    throw const FormatException('It is not an APK Forge profile: not JSON.');
  }
  if (json is! Map<String, Object?> ||
      json['format'] != _exportFormat ||
      json['profile'] is! Map<String, Object?>) {
    throw const FormatException('It is not an APK Forge profile.');
  }
  return SigningProfile.fromJson(json['profile'] as Map<String, Object?>);
}

/// What's wrong with a file name pattern: empty, or an unknown `{token}`.
List<String> fileNamePatternProblems(String pattern) {
  if (pattern.trim().isEmpty) return const ['The file name pattern is empty.'];
  final unknown = _token
      .allMatches(pattern)
      .map((match) => match.group(0)!)
      .where((token) => !fileNameTokens.contains(token))
      .toSet();
  return [
    for (final token in unknown)
      '$token is not a token: use ${fileNameTokens.join(', ')}.',
  ];
}
