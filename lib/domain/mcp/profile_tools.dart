import '../../core/system/host.dart';
import '../analysis/apk_report.dart';
import '../failure.dart';
import '../profiles/key_properties.dart';
import '../profiles/profile.dart';
import '../profiles/profile_plan.dart';
import '../profiles/profile_run.dart';
import '../profiles/run_report.dart';
import 'mcp_protocol.dart';

const _profileArgument = {
  'type': 'string',
  'description':
      'The profile\'s name, as list_profiles gives it. Case doesn\'t matter.',
};

const _runArguments = {
  'type': 'object',
  'properties': {
    'profile': _profileArgument,
    'apks': {
      'type': 'array',
      'items': {'type': 'string'},
      'minItems': 1,
      'description': 'The absolute paths of the APKs to run the profile on.',
    },
  },
  'required': ['profile', 'apks'],
};

const listProfilesTool = McpTool(
  name: 'list_profiles',
  title: 'List signing profiles',
  description:
      'The saved signing profiles: each one\'s targets (ABI, key, output '
      'folder, schemes), its input checks, its file name pattern, and what '
      'stops a target from running on this machine.',
  inputSchema: {'type': 'object', 'properties': <String, Object?>{}},
  readOnly: true,
);

const checkProfileRunTool = McpTool(
  name: 'check_profile_run',
  title: 'Check a profile run',
  description:
      'The check the Run dialog makes, without signing anything: reads the '
      'APKs, plans the run (what is signed, shared or skipped), and opens '
      'the keys. Says what stops the run, if anything.',
  inputSchema: _runArguments,
  readOnly: true,
);

const runProfileTool = McpTool(
  name: 'run_profile',
  title: 'Run a signing profile',
  description:
      'Checks, then runs the profile on the APKs: one signed APK per target '
      'in its folder, replacing one of the same name. Returns each target\'s '
      'result and the run\'s report, as the History keeps it. Refused while '
      'another task runs in APK Forge, or when the check finds a problem. '
      'When APK Forge asks before an agent runs a profile, it waits for its '
      'user to allow the run in the app.',
  inputSchema: _runArguments,
  readOnly: false,
);

const listRunsTool = McpTool(
  name: 'list_runs',
  title: 'List a profile\'s runs',
  description: 'A profile\'s History, newest first.',
  inputSchema: {
    'type': 'object',
    'properties': {
      'profile': _profileArgument,
      'limit': {
        'type': 'integer',
        'minimum': 1,
        'maximum': ProfileRunsArguments.maxLimit,
        'default': ProfileRunsArguments.defaultLimit,
        'description': 'How many runs, newest first.',
      },
    },
    'required': ['profile'],
  },
  readOnly: true,
);

const profileTools = [
  listProfilesTool,
  checkProfileRunTool,
  runProfileTool,
  listRunsTool,
];

/// The profile [name] asks for, ignoring case, or why there's none.
///
/// New profiles get a unique name, but ones saved before that may share
/// one: those are [ProfileLookup.problem], never a guess.
ProfileLookup findProfile(String name, List<SigningProfile> profiles) {
  final wanted = name.trim().toLowerCase();
  final found = [
    for (final profile in profiles)
      if (profile.name.trim().toLowerCase() == wanted) profile,
  ];
  if (found.length == 1) return ProfileLookup(profile: found.single);
  if (found.isEmpty) {
    return ProfileLookup(
      problem: profiles.isEmpty
          ? 'No profile named "$name": APK Forge has no profiles yet.'
          : 'No profile named "$name". The profiles: '
                '${profiles.map((p) => '"${p.name}"').join(', ')}.',
    );
  }
  return ProfileLookup(
    problem:
        '${found.length} profiles are named "$name": rename one in APK '
        'Forge, then ask again.',
  );
}

class ProfileLookup {
  const ProfileLookup({this.profile, this.problem});

  final SigningProfile? profile;
  final String? problem;
}

const _nameTheProfile =
    'Name the profile (profile): list_profiles gives the names.';

/// The arguments of `check_profile_run` and `run_profile`: a profile's
/// name and the APKs, each an absolute path to a file that exists.
class ProfileRunArguments {
  const ProfileRunArguments({this.profile = '', this.apks = const []})
    : problem = null;

  const ProfileRunArguments._problem(String this.problem)
    : profile = '',
      apks = const [];

  /// [arguments] read, or [problem] says what's wrong with them. A single
  /// path is taken as a list of one.
  factory ProfileRunArguments.read(
    Map<String, Object?> arguments, {
    required Host host,
    required FileProbe probe,
  }) {
    final profile = arguments['profile'];
    if (profile is! String || profile.trim().isEmpty) {
      return const ProfileRunArguments._problem(_nameTheProfile);
    }
    final apks = switch (arguments['apks']) {
      final String path => [path],
      final List<Object?> paths => paths,
      _ => const <Object?>[],
    };
    if (apks.isEmpty) {
      return const ProfileRunArguments._problem(
        'Give the APKs to run on (apks): their absolute paths.',
      );
    }
    final paths = <String>[];
    for (final apk in apks) {
      if (apk is! String || apk.trim().isEmpty) {
        return const ProfileRunArguments._problem(
          'Each APK is a path (a string).',
        );
      }
      final path = apk.trim();
      if (!host.path.isAbsolute(path)) {
        return ProfileRunArguments._problem(
          'Give the APK\'s absolute path, not "$path".',
        );
      }
      if (!probe.fileExists(path)) {
        return ProfileRunArguments._problem('There is no file at $path.');
      }
      if (!paths.contains(path)) paths.add(path);
    }
    return ProfileRunArguments(profile: profile.trim(), apks: paths);
  }

  final String profile;
  final List<String> apks;
  final String? problem;
}

/// The arguments of `list_runs`: a profile's name and how many runs.
class ProfileRunsArguments {
  const ProfileRunsArguments({this.profile = '', this.limit = defaultLimit})
    : problem = null;

  const ProfileRunsArguments._problem(String this.problem)
    : profile = '',
      limit = defaultLimit;

  static const defaultLimit = 10;
  static const maxLimit = 50;

  factory ProfileRunsArguments.read(Map<String, Object?> arguments) {
    final profile = arguments['profile'];
    if (profile is! String || profile.trim().isEmpty) {
      return const ProfileRunsArguments._problem(_nameTheProfile);
    }
    final limit = arguments['limit'] ?? defaultLimit;
    if (limit is! int || limit < 1 || limit > maxLimit) {
      return const ProfileRunsArguments._problem(
        'limit is a number from 1 to $maxLimit.',
      );
    }
    return ProfileRunsArguments(profile: profile.trim(), limit: limit);
  }

  final String profile;
  final int limit;
  final String? problem;
}

/// [profile] for `list_profiles`: its paths and choices, each target's
/// key alias from [keys] (by `key.properties` path), and [problems], as
/// the Profiles list says them. Never what's in a `key.properties` but its
/// alias.
Map<String, Object?> profileJson(
  SigningProfile profile, {
  required Map<String, KeyFileSummary> keys,
  required List<String> problems,
}) => {
  'name': profile.name,
  'input': profile.input.toJson(),
  'targets': [
    for (final target in profile.targets)
      {
        'name': target.name,
        'abi': target.abiName,
        'keyProperties': target.keyProperties,
        'keyAlias': keys[target.keyProperties.trim()]?.alias,
        'schemes': target.schemes?.label ?? 'Defaults',
        'outputDir': target.outputDir,
      },
  ],
  'fileNamePattern': profile.fileNamePattern,
  'afterRun': profile.afterRun.name,
  'problems': problems,
};

/// A run's check for `check_profile_run` and a refused `run_profile`: whether
/// it [canRun], the inputs read, the plan, and the keys opened ([keyAliases],
/// by `key.properties` path) or the one that didn't open ([keyFailure]).
Map<String, Object?> runCheckJson(
  SigningProfile profile, {
  required bool canRun,
  required List<ApkReport> inputs,
  required ProfileRunPlan plan,
  required Map<String, String>? keyAliases,
  required ToolFailure? keyFailure,
  required Host host,
}) {
  String name(ApkReport report) => host.path.basename(report.path);
  return {
    'profile': profile.name,
    'canRun': canRun,
    'inputs': [
      for (final input in inputs)
        {
          'path': input.path,
          'packageName': input.badging?.packageName,
          'versionName': input.badging?.versionName,
          'versionCode': input.badging?.versionCode,
          'signed': input.isSigned,
          'sha256': input.sha256,
        },
    ],
    'problems': [
      ...plan.problems,
      if (plan.problems.isEmpty && plan.jobs.isEmpty)
        'Every target is skipped: nothing to sign.',
      if (keyFailure != null) ...[keyFailure.title, ...keyFailure.details],
    ],
    'signings': [
      for (final job in plan.jobs)
        {
          'input': name(job.input),
          // `null` signs the input whole: a universal target, or an input
          // with nothing else to leave out.
          'cutToAbi': job.abi?.abiName,
          'keyProperties': job.keyProperties,
          'keyAlias': keyAliases?[job.keyProperties],
          'schemes': job.schemes.label,
          'outputs': [
            for (final output in job.outputs)
              {'target': output.target.name, 'path': output.path},
          ],
        },
    ],
    'skipped': [
      for (final skipped in plan.skipped)
        {
          'target': skipped.target.name,
          'input': name(skipped.input),
          'reason': skipped.reason,
        },
    ],
  };
}

/// A finished run for `run_profile`: each target's result, and the report
/// the History's Copy writes.
Map<String, Object?> runResultJson(ProfileRunRecord record) => {
  ...runSummaryJson(record),
  'report': runReportText(runReport(record)),
};

/// A run for `list_runs`: when, what came of it, the inputs and each
/// target's result, as the History keeps them.
Map<String, Object?> runSummaryJson(ProfileRunRecord record) => {
  'profile': record.profileName,
  'startedAt': record.startedAt.toIso8601String(),
  'finishedAt': record.finishedAt.toIso8601String(),
  'outcome': record.outcome.label,
  'summary': record.summary,
  'inputs': [for (final input in record.inputs) input.toJson()],
  'results': [for (final result in record.results) result.toJson()],
};
