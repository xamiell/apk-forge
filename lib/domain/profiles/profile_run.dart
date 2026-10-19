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

/// One target's result in a run: the signed APK, or why there is none.
class TargetResult {
  const TargetResult({
    required this.target,
    required this.input,
    required this.status,
    this.outputPath,
    this.sizeBytes,
    this.signerSha256,
    this.reason,
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

  Map<String, Object?> toJson() => {
    'target': target,
    'input': input,
    'status': status.name,
    'outputPath': outputPath,
    'sizeBytes': sizeBytes,
    'signerSha256': signerSha256,
    'reason': reason,
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
  });

  factory RunInput.fromJson(Map<String, Object?> json) => RunInput(
    name: json['name'] as String? ?? '',
    sha256: json['sha256'] as String? ?? '',
    packageName: json['packageName'] as String?,
    versionName: json['versionName'] as String?,
    versionCode: json['versionCode'] as String?,
  );

  final String name;
  final String sha256;
  final String? packageName;
  final String? versionName;
  final String? versionCode;

  Map<String, Object?> toJson() => {
    'name': name,
    'sha256': sha256,
    'packageName': packageName,
    'versionName': versionName,
    'versionCode': versionCode,
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
      );

  final String profileId;
  final String profileName;
  final DateTime startedAt;
  final DateTime finishedAt;
  final List<RunInput> inputs;
  final List<TargetResult> results;
  final bool cancelled;

  int count(TargetStatus status) =>
      results.where((result) => result.status == status).length;

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
  };
}
