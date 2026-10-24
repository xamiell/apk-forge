import '../analysis/apk_report.dart';
import '../signing/signing.dart';
import 'profile.dart';

/// What happened to one target.
enum TargetStatus {
  signed('Signed'),
  failed('Failed'),
  skipped('Skipped');

  const TargetStatus(this.label);
  final String label;
}

/// Where a target is in a run.
enum TargetStage {
  waiting('Waiting'),
  splitting('Splitting'),
  signing('Signing'),
  writing('Writing'),
  finished('Finished');

  const TargetStage(this.label);
  final String label;
}

/// A target's progress, for the run's progress list: its stage, and its
/// result once [TargetStage.finished].
class TargetProgress {
  const TargetProgress({
    required this.target,
    required this.input,
    required this.stage,
    this.result,
  });

  final String target;
  final String input;
  final TargetStage stage;
  final TargetResult? result;
}

/// How a target was signed, as the run's plan decided it. Paths and
/// names; never a password.
class TargetSetup {
  const TargetSetup({
    required this.abi,
    required this.cut,
    required this.keyProperties,
    this.keyAlias,
    required this.schemes,
    required this.schemesFromDefaults,
    this.copiedFrom,
  });

  factory TargetSetup.fromJson(Map<String, Object?> json) => TargetSetup(
    abi: json['abi'] as String? ?? '',
    cut: json['cut'] as bool? ?? false,
    keyProperties: json['keyProperties'] as String? ?? '',
    keyAlias: json['keyAlias'] as String?,
    schemes: SigningSchemes.fromJson(json['schemes']),
    schemesFromDefaults: json['schemesFromDefaults'] as bool? ?? false,
    copiedFrom: json['copiedFrom'] as String?,
  );

  /// The target's ABI (`arm64-v8a`), or [ProfileTarget.universalAbiName].
  final String abi;

  /// Whether the input was cut to [abi]. `false` when it was signed whole:
  /// a universal target, or an input with nothing else to leave out.
  final bool cut;

  /// The `key.properties` it signs with: its path, never its contents.
  final String keyProperties;

  /// The key's alias in its keystore; `null` when the key wasn't opened.
  final String? keyAlias;

  /// The schemes asked of apksigner.
  final SigningSchemes schemes;

  /// [schemes] are the Workbench's Defaults as they were when the run
  /// started; otherwise they're the target's own.
  final bool schemesFromDefaults;

  /// The target whose signing this one shares: the same input, ABI, key
  /// and schemes are signed once, and the APK is copied to each folder.
  final String? copiedFrom;

  Map<String, Object?> toJson() => {
    'abi': abi,
    'cut': cut,
    'keyProperties': keyProperties,
    'keyAlias': keyAlias,
    'schemes': schemes.toJson(),
    'schemesFromDefaults': schemesFromDefaults,
    'copiedFrom': copiedFrom,
  };
}

/// One target's result in a run: the signed APK, or why there is none, and
/// how it was signed.
///
/// A record saved before the history kept the details (#14) has only the
/// fields up to [reason]; the others are `null`.
class TargetResult {
  const TargetResult({
    required this.target,
    required this.input,
    required this.status,
    this.outputPath,
    this.sizeBytes,
    this.signerSha256,
    this.reason,
    this.setup,
    this.signerDistinguishedName,
    this.verifiedSchemes,
    this.hasJarSignature,
    this.outputSha256,
  });

  factory TargetResult.fromJson(Map<String, Object?> json) => TargetResult(
    target: json['target'] as String? ?? '',
    input: json['input'] as String? ?? '',
    status: TargetStatus.values.firstWhere(
      (status) => status.name == json['status'],
      orElse: () => TargetStatus.failed,
    ),
    outputPath: json['outputPath'] as String?,
    sizeBytes: json['sizeBytes'] as int?,
    signerSha256: json['signerSha256'] as String?,
    reason: json['reason'] as String?,
    setup: switch (json['setup']) {
      final Map<String, Object?> setup => TargetSetup.fromJson(setup),
      _ => null,
    },
    signerDistinguishedName: json['signerDistinguishedName'] as String?,
    verifiedSchemes: switch (json['verifiedSchemes']) {
      final Map<String, Object?> schemes => {
        for (final MapEntry(:key, :value) in schemes.entries)
          key: value == true,
      },
      _ => null,
    },
    hasJarSignature: json['hasJarSignature'] as bool?,
    outputSha256: json['outputSha256'] as String?,
  );

  /// The target's name.
  final String target;

  /// The input APK's file name.
  final String input;
  final TargetStatus status;
  final String? outputPath;
  final int? sizeBytes;

  /// The signed APK's signer, normalized.
  final String? signerSha256;

  /// Why it failed or was skipped.
  final String? reason;

  final TargetSetup? setup;

  /// The signer's certificate DN: `CN=…, O=…`.
  final String? signerDistinguishedName;

  /// What `apksigner verify` said of each scheme of the signed APK
  /// (`v2` → true). From minSdk 24 it doesn't check v1: see
  /// [hasJarSignature].
  final Map<String, bool>? verifiedSchemes;

  /// Whether the signed APK carries a v1 (JAR) signature, read from its
  /// files. `null` when they couldn't be read.
  final bool? hasJarSignature;

  /// The signed APK's SHA-256: what ties a file found later to this run.
  final String? outputSha256;

  Map<String, Object?> toJson() => {
    'target': target,
    'input': input,
    'status': status.name,
    'outputPath': outputPath,
    'sizeBytes': sizeBytes,
    'signerSha256': signerSha256,
    'reason': reason,
    'setup': setup?.toJson(),
    'signerDistinguishedName': signerDistinguishedName,
    'verifiedSchemes': verifiedSchemes,
    'hasJarSignature': hasJarSignature,
    'outputSha256': outputSha256,
  };
}

/// An input APK, as the history remembers it.
class RunInput {
  const RunInput({
    required this.name,
    required this.sha256,
    this.packageName,
    this.versionName,
    this.versionCode,
    this.minSdk,
    this.unsigned,
  });

  /// [report]'s APK, named [name] (its file name).
  factory RunInput.fromReport(ApkReport report, {required String name}) =>
      RunInput(
        name: name,
        sha256: report.sha256,
        packageName: report.badging?.packageName,
        versionName: report.badging?.versionName,
        versionCode: report.badging?.versionCode,
        minSdk: report.badging?.minSdk,
        unsigned: switch (report.isSigned) {
          null => null,
          final signed => !signed,
        },
      );

  factory RunInput.fromJson(Map<String, Object?> json) => RunInput(
    name: json['name'] as String? ?? '',
    sha256: json['sha256'] as String? ?? '',
    packageName: json['packageName'] as String?,
    versionName: json['versionName'] as String?,
    versionCode: json['versionCode'] as String?,
    minSdk: json['minSdk'] as int?,
    unsigned: json['unsigned'] as bool?,
  );

  final String name;
  final String sha256;
  final String? packageName;
  final String? versionName;
  final String? versionCode;
  final int? minSdk;

  /// Whether it had no signature at all; `null` when that couldn't be
  /// checked, or in a record saved before #14.
  final bool? unsigned;

  /// `1.4.0 (140)`, or `null` when the manifest couldn't be read.
  String? get version =>
      versionName == null ? null : '$versionName ($versionCode)';

  Map<String, Object?> toJson() => {
    'name': name,
    'sha256': sha256,
    'packageName': packageName,
    'versionName': versionName,
    'versionCode': versionCode,
    'minSdk': minSdk,
    'unsigned': unsigned,
  };
}

/// What a run came to, as a whole.
enum RunOutcome {
  allSigned('All signed'),
  someSkipped('Signed, some skipped'),
  someFailed('Some failed'),
  failed('Failed'),
  nothingSigned('Nothing signed'),
  cancelled('Cancelled');

  const RunOutcome(this.label);
  final String label;
}

/// Who started a run: **Run** in the app, or an agent through the MCP
/// server.
sealed class RunStarter {
  const RunStarter();

  /// What [toJson] saved; `null` for anything else.
  static RunStarter? fromJson(Object? json) => switch (json) {
    {'by': 'app'} => const StartedInApp(),
    {
      'by': 'agent',
      'agent': final String agent,
      'allowedInApp': final bool allowed,
    } =>
      StartedByAgent(agent, allowedInApp: allowed),
    _ => null,
  };

  Map<String, Object?> toJson();
}

final class StartedInApp extends RunStarter {
  const StartedInApp();

  @override
  Map<String, Object?> toJson() => const {'by': 'app'};
}

/// An agent's run.
final class StartedByAgent extends RunStarter {
  const StartedByAgent(this.agent, {required this.allowedInApp});

  /// The agent as Agent access named it: its name and version. Never its
  /// session's ID.
  final String agent;

  /// Whether its user allowed it in the app; `false` when it ran without
  /// asking, because Ask before an agent runs a profile was off.
  final bool allowedInApp;

  @override
  Map<String, Object?> toJson() => {
    'by': 'agent',
    'agent': agent,
    'allowedInApp': allowedInApp,
  };
}

/// One run of a profile, for its history. Paths, versions and digests;
/// never a password.
class ProfileRunRecord {
  const ProfileRunRecord({
    required this.profileId,
    required this.profileName,
    required this.startedAt,
    required this.finishedAt,
    required this.inputs,
    required this.results,
    this.cancelled = false,
    this.fileNamePattern,
    this.inputChecks,
    this.buildToolsVersion,
    this.startedBy,
  });

  factory ProfileRunRecord.fromJson(Map<String, Object?> json) =>
      ProfileRunRecord(
        profileId: json['profileId'] as String? ?? '',
        profileName: json['profileName'] as String? ?? '',
        startedAt:
            DateTime.tryParse(json['startedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        finishedAt:
            DateTime.tryParse(json['finishedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        inputs: [
          for (final input in json['inputs'] as List<Object?>? ?? const [])
            if (input is Map<String, Object?>) RunInput.fromJson(input),
        ],
        results: [
          for (final result in json['results'] as List<Object?>? ?? const [])
            if (result is Map<String, Object?>) TargetResult.fromJson(result),
        ],
        cancelled: json['cancelled'] as bool? ?? false,
        fileNamePattern: json['fileNamePattern'] as String?,
        inputChecks: switch (json['inputChecks']) {
          final Map<String, Object?> checks => InputChecks.fromJson(checks),
          _ => null,
        },
        buildToolsVersion: json['buildToolsVersion'] as String?,
        startedBy: RunStarter.fromJson(json['startedBy']),
      );

  final String profileId;
  final String profileName;
  final DateTime startedAt;
  final DateTime finishedAt;
  final List<RunInput> inputs;
  final List<TargetResult> results;
  final bool cancelled;

  /// The profile's, when it ran. `null` in a record saved before #14, as
  /// are [inputChecks] and [buildToolsVersion].
  final String? fileNamePattern;
  final InputChecks? inputChecks;

  /// The build-tools whose apksigner and zipalign signed.
  final String? buildToolsVersion;

  /// `null` in a record saved before #44.
  final RunStarter? startedBy;

  /// Whether it keeps how each target was signed. A record saved before
  /// #14 has only the names, outputs and digests.
  bool get hasDetails => fileNamePattern != null;

  int count(TargetStatus status) =>
      results.where((result) => result.status == status).length;

  RunOutcome get outcome {
    if (cancelled) return RunOutcome.cancelled;
    final signed = count(TargetStatus.signed);
    if (count(TargetStatus.failed) > 0) {
      return signed > 0 ? RunOutcome.someFailed : RunOutcome.failed;
    }
    if (signed == 0) return RunOutcome.nothingSigned;
    return count(TargetStatus.skipped) > 0
        ? RunOutcome.someSkipped
        : RunOutcome.allSigned;
  }

  /// What it signed, each once: `1.4.0 (140)`, or an input's file name
  /// when its version wasn't read.
  List<String> get versions =>
      {for (final input in inputs) input.version ?? input.name}.toList();

  /// The targets it ran, each once, in the order of the results.
  List<String> get targets =>
      {for (final result in results) result.target}.toList();

  /// `2 signed · 1 failed · 1 skipped`.
  String get summary {
    final parts = [
      for (final status in TargetStatus.values)
        if (count(status) > 0) '${count(status)} ${status.name}',
      if (cancelled) 'cancelled',
    ];
    return parts.isEmpty ? 'Nothing signed' : parts.join(' · ');
  }

  Map<String, Object?> toJson() => {
    'profileId': profileId,
    'profileName': profileName,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt.toIso8601String(),
    'inputs': [for (final input in inputs) input.toJson()],
    'results': [for (final result in results) result.toJson()],
    'cancelled': cancelled,
    'fileNamePattern': fileNamePattern,
    'inputChecks': inputChecks?.toJson(),
    'buildToolsVersion': buildToolsVersion,
    'startedBy': startedBy?.toJson(),
  };
}
