import '../../core/system/host.dart';
import '../analysis/apk_report.dart';
import '../build/build_options.dart';
import '../signing/signing.dart';
import 'profile.dart';
import 'target_problems.dart';

/// Where one target's signed APK goes.
class PlannedOutput {
  const PlannedOutput({required this.target, required this.path});

  final ProfileTarget target;
  final String path;
}

/// One signing: an input, whole or cut to one ABI, with one key and one
/// set of schemes, copied to every target that shares them.
class SignJob {
  const SignJob({
    required this.input,
    required this.abi,
    required this.keyProperties,
    required this.schemes,
    required this.outputs,
  });

  final ApkReport input;

  /// The ABI the input is cut to; `null` signs it whole.
  final AndroidAbi? abi;
  final String keyProperties;
  final SigningSchemes schemes;
  final List<PlannedOutput> outputs;

  SignJob _withOutput(PlannedOutput output) => SignJob(
    input: input,
    abi: abi,
    keyProperties: keyProperties,
    schemes: schemes,
    outputs: [...outputs, output],
  );
}

/// A target an input can't serve, and why.
class SkippedTarget {
  const SkippedTarget({
    required this.input,
    required this.target,
    required this.schemes,
    required this.reason,
  });

  final ApkReport input;
  final ProfileTarget target;

  /// What it would have been signed with: its own, or [planProfileRun]'s
  /// defaults.
  final SigningSchemes schemes;
  final String reason;
}

/// What running a profile on some APKs will do, decided before anything is
/// signed.
class ProfileRunPlan {
  const ProfileRunPlan({
    this.problems = const [],
    this.jobs = const [],
    this.skipped = const [],
  });

  /// Why the run can't start. Nothing is signed while there is one.
  final List<String> problems;
  final List<SignJob> jobs;
  final List<SkippedTarget> skipped;

  bool get canRun => problems.isEmpty && jobs.isNotEmpty;

  /// The signed APKs the run writes.
  int get outputCount =>
      jobs.fold(0, (count, job) => count + job.outputs.length);
}

/// Plans running [profile] on [inputs], from their reports.
///
/// - The input checks (package, unsigned), every target's key file and
///   folder, and a key file or folder that doesn't exist on this machine
///   (a profile imported from another one) are problems that stop the run.
/// - A target an input has no native code (or no Flutter engine) for is
///   skipped, with the reason.
/// - A target without schemes of its own uses [defaultSchemes].
/// - Targets that share the input, the ABI, the key and the schemes are
///   signed once and copied to each folder.
/// - Two targets writing the same file, two inputs that give the same file
///   name, or a target writing over its input, is a problem.
ProfileRunPlan planProfileRun(
  SigningProfile profile,
  List<ApkReport> inputs, {
  required SigningSchemes defaultSchemes,
  required Host host,
  required FileProbe probe,
  required DateTime date,
}) {
  final path = host.path;
  final followsDefaults = profile.targets.any((t) => t.schemes == null);
  final problems = <String>[
    if (profile.targets.isEmpty) 'The profile has no targets.',
    if (inputs.isEmpty) 'Pick an APK to run the profile on.',
    ...fileNamePatternProblems(profile.fileNamePattern),
    if (followsDefaults) ?defaultSchemesProblem(defaultSchemes),
    for (final target in profile.targets)
      for (final problem in targetProblems(target, probe: probe))
        describeTargetProblem(target, problem),
    for (final input in inputs) ..._inputProblems(profile.input, input, host),
  ];

  final jobs = <String, SignJob>{};
  final skipped = <SkippedTarget>[];
  for (final input in inputs) {
    for (final target in profile.targets) {
      final schemes = target.schemes ?? defaultSchemes;
      final source = _source(input.contents, target.abi);
      if (source.skip != null) {
        skipped.add(
          SkippedTarget(
            input: input,
            target: target,
            schemes: schemes,
            reason: source.skip!,
          ),
        );
        continue;
      }
      final output = PlannedOutput(
        target: target,
        path: path.join(
          target.outputDir.trim(),
          profileFileName(
            profile.fileNamePattern,
            name: profileAppName(
              label: input.badging?.label,
              packageName: input.badging?.packageName,
              fileName: path.basenameWithoutExtension(input.path),
            ),
            target: target.name,
            abi: target.abiName,
            versionName: input.badging?.versionName,
            versionCode: input.badging?.versionCode,
            date: date,
          ),
        ),
      );
      final key = [
        input.path,
        source.cut?.abiName,
        target.keyProperties,
        _schemesKey(schemes),
      ].join('|');
      jobs.update(
        key,
        (job) => job._withOutput(output),
        ifAbsent: () => SignJob(
          input: input,
          abi: source.cut,
          keyProperties: target.keyProperties,
          schemes: schemes,
          outputs: [output],
        ),
      );
    }
  }

  final written = <String, _Writer>{};
  final inputPaths = {for (final input in inputs) path.normalize(input.path)};
  for (final job in jobs.values) {
    for (final output in job.outputs) {
      final file = path.normalize(output.path);
      final writer = (target: output.target.name, input: job.input.path);
      if (written[file] case final other?) {
        problems.add(_sameFile(other, writer, output.path, host));
      }
      if (inputPaths.contains(file)) {
        problems.add(
          '${output.target.name} would write over its input, ${output.path}.',
        );
      }
      written[file] = writer;
    }
  }

  return ProfileRunPlan(
    problems: problems,
    jobs: jobs.values.toList(),
    skipped: skipped,
  );
}

/// A target and the input it signs, as a file name collision names them.
typedef _Writer = ({String target, String input});

/// Why [first] and [second] can't both write [file]: two targets, or two
/// inputs that give the same file name through one target.
String _sameFile(_Writer first, _Writer second, String file, Host host) {
  String name(String input) => host.path.basename(input);
  if (first.target != second.target) {
    final who = first.input == second.input
        ? '${first.target} and ${second.target}'
        : '${first.target} for ${name(first.input)} and '
              '${second.target} for ${name(second.input)}';
    return '$who would both write $file. '
        'Put {target} in the file name, or give them different folders.';
  }
  return '${name(first.input)} and ${name(second.input)} would both write '
      '$file for ${first.target}. Put {versionCode} in the file name if '
      'their versions differ, or run them one at a time.';
}

List<String> _inputProblems(InputChecks checks, ApkReport input, Host host) {
  final name = host.path.basename(input.path);
  final expected = checks.packageName;
  final package = input.badging?.packageName;
  final signature = input.signature;
  final signer = signature?.signers.firstOrNull;
  return [
    if (input.contentsError != null) '$name: ${input.contentsError}',
    if (expected != null && package == null)
      '$name: its package could not be read '
          '(${input.badgingError ?? 'aapt2 printed none'}), so it can\'t be '
          'checked against $expected.',
    if (expected != null && package != null && package != expected)
      '$name is $package, not $expected.',
    if (checks.mustBeUnsigned && signature == null)
      '$name: its signature could not be checked '
          '(${input.signatureError ?? 'apksigner printed nothing'}).',
    if (checks.mustBeUnsigned && input.isSigned == true)
      '$name is already signed'
          '${signer == null ? '' : ' by ${signer.distinguishedName ?? 'an unknown signer'}'}'
          '; the profile wants an unsigned APK.',
  ];
}

/// The ABI to cut [contents] to for a target of [abi] (`null`: sign it
/// whole), or why it can't serve that target.
({AndroidAbi? cut, String? skip}) _source(
  ApkContents contents,
  AndroidAbi? abi,
) {
  final libraries = contents.nativeLibraries;
  // Universal, or no native code at all: the whole APK runs anywhere.
  if (abi == null || libraries.isEmpty) return (cut: null, skip: null);
  if (!libraries.containsKey(abi.abiName)) {
    return (cut: null, skip: 'No native code for ${abi.abiName}');
  }
  if (contents.abisWithoutFlutterEngine.contains(abi.abiName)) {
    return (cut: null, skip: 'No Flutter engine for ${abi.abiName}');
  }
  // Nothing else to leave out.
  if (libraries.length == 1) return (cut: null, skip: null);
  return (cut: abi, skip: null);
}

String _schemesKey(SigningSchemes schemes) =>
    [schemes.v1, schemes.v2, schemes.v3, schemes.v4].join(',');
