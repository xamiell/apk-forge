import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/logging/log_entry.dart';
import '../core/system/host.dart';
import '../domain/failure.dart';
import '../domain/mcp/mcp_protocol.dart';
import '../domain/mcp/profile_tools.dart';
import '../domain/profiles/key_properties.dart';
import '../domain/profiles/profile.dart';
import '../domain/profiles/profile_run.dart';
import '../domain/profiles/target_problems.dart';
import 'actions/profile_run_action.dart';
import 'apks.dart';
import 'log_notifier.dart';
import 'mcp_notifier.dart';
import 'profiles.dart';
import 'providers.dart';
import 'task_notifier.dart';

/// What the user said to a run an agent asked for.
enum RunApproval {
  allowed,
  declined,

  /// Another agent's run is already waiting for an answer.
  anotherWaiting,
}

/// A run an agent asked for, checked and waiting for Allow. It holds the
/// check, keys opened: it lives only until it's answered.
class McpRunRequest {
  McpRunRequest({required this.profile, required this.check});

  final SigningProfile profile;
  final ProfileRunCheck check;
  final _answer = Completer<RunApproval>();
}

/// The run waiting for Allow, if any. The app shows it in a dialog.
final mcpRunRequestProvider =
    NotifierProvider<McpRunRequestNotifier, McpRunRequest?>(
      McpRunRequestNotifier.new,
    );

class McpRunRequestNotifier extends Notifier<McpRunRequest?> {
  /// [state], kept apart: a disposed notifier can't read its state.
  McpRunRequest? _waiting;

  @override
  McpRunRequest? build() {
    // Closing the app declines what's waiting.
    ref.onDispose(() => _complete(RunApproval.declined));
    return null;
  }

  /// Waits for the user's answer to running [profile] as [check] planned.
  /// One request at a time: another one is [RunApproval.anotherWaiting] at
  /// once.
  Future<RunApproval> ask(SigningProfile profile, ProfileRunCheck check) {
    if (_waiting != null) return Future.value(RunApproval.anotherWaiting);
    final request = McpRunRequest(profile: profile, check: check);
    state = _waiting = request;
    return request._answer.future;
  }

  /// Answers the waiting request, if there is one.
  void answer({required bool allow}) {
    if (_waiting == null) return;
    state = null;
    _complete(allow ? RunApproval.allowed : RunApproval.declined);
  }

  void _complete(RunApproval approval) {
    final request = _waiting;
    _waiting = null;
    if (request != null && !request._answer.isCompleted) {
      request._answer.complete(approval);
    }
  }
}

/// The tools an agent gets over the signing profiles. Each one does what
/// the Profiles view does: the same check, the same run, the same History.
/// What they return holds paths, names and digests; never a password.
class ProfileMcpTools implements McpToolbox {
  const ProfileMcpTools({
    required this.profiles,
    required this.history,
    required this.keySummary,
    required this.reread,
    required this.check,
    required this.askToRun,
    required this.approve,
    required this.run,
    required this.task,
    required this.lastRun,
    required this.log,
    required this.probe,
    required this.host,
  });

  final List<SigningProfile> Function() profiles;

  /// A profile's runs, newest first.
  final List<ProfileRunRecord> Function(String profileId) history;

  /// What a `key.properties` says, without its passwords.
  final Future<KeyFileSummary> Function(String path) keySummary;

  /// Forgets what was read of an APK: an agent may have built it again
  /// since.
  final void Function(String path) reread;

  /// The Run dialog's check of running a profile on [apks].
  final Future<ProfileRunCheck> Function(String profileId, List<String> apks)
  check;

  /// Whether a run waits for the user to allow it, read at each run.
  final bool Function() askToRun;

  /// Asks the user to allow running a checked profile.
  final Future<RunApproval> Function(
    SigningProfile profile,
    ProfileRunCheck check,
  )
  approve;

  /// Runs a checked profile as the Run dialog does, recording that
  /// [startedBy] started it; `null` when it didn't finish.
  final Future<ProfileRunRecord?> Function(
    SigningProfile profile,
    ProfileRunCheck check,
    StartedByAgent startedBy,
  )
  run;

  final TaskState Function() task;

  /// The last run started in the app, for a run that was cancelled.
  final ProfileRunState? Function() lastRun;

  final TaskLog log;
  final FileProbe probe;
  final Host host;

  @override
  List<McpTool> get tools => profileTools;

  @override
  Future<McpToolResult> call(
    String name,
    Map<String, Object?> arguments, {
    required String agent,
  }) {
    if (name == listProfilesTool.name) return _listProfiles();
    if (name == checkProfileRunTool.name) return _check(arguments, agent);
    if (name == runProfileTool.name) return _run(arguments, agent);
    if (name == listRunsTool.name) return _listRuns(arguments);
    throw ArgumentError.value(name, 'name', 'No such tool');
  }

  Future<McpToolResult> _listProfiles() async {
    final all = profiles();
    final keys = <String, KeyFileSummary>{};
    for (final target in all.expand((profile) => profile.targets)) {
      final path = target.keyProperties.trim();
      if (path.isNotEmpty &&
          probe.fileExists(path) &&
          !keys.containsKey(path)) {
        keys[path] = await keySummary(path);
      }
    }
    return McpToolResult({
      'profiles': [
        for (final profile in all)
          profileJson(
            profile,
            keys: keys,
            problems: [
              for (final target in profile.targets)
                for (final problem in targetProblems(
                  target,
                  probe: probe,
                  keySummary: keys[target.keyProperties.trim()],
                ))
                  describeTargetProblem(target, problem),
            ],
          ),
      ],
    });
  }

  Future<McpToolResult> _check(
    Map<String, Object?> arguments,
    String agent,
  ) async {
    final (profile, apks, problem) = _runArguments(arguments);
    if (problem != null) return McpToolResult.error(problem);
    log.info('$agent checks "${profile!.name}" on ${_names(apks)}.');
    try {
      final checked = await _checked(profile, apks);
      return McpToolResult(_checkJson(profile, checked));
    } on ToolFailure catch (failure) {
      return _failure('The check failed', failure);
    }
  }

  Future<McpToolResult> _run(
    Map<String, Object?> arguments,
    String agent,
  ) async {
    final (profile, apks, problem) = _runArguments(arguments);
    if (problem != null) return McpToolResult.error(problem);
    if (_busy() case final busy?) return busy;
    log.info('$agent runs "${profile!.name}" on ${_names(apks)}.');

    final ProfileRunCheck checked;
    try {
      checked = await _checked(profile, apks);
    } on ToolFailure catch (failure) {
      return _failure('The check failed', failure);
    }
    if (!checked.canRun) {
      return McpToolResult.error(
        'The run didn\'t start: the check found a problem.',
        data: _checkJson(profile, checked),
      );
    }
    final asks = askToRun();
    if (asks) {
      log.info('Waiting for Allow in APK Forge.');
      switch (await approve(profile, checked)) {
        case RunApproval.allowed:
          log.info('The run was allowed.');
        case RunApproval.declined:
          log.warning('The run was declined.');
          return McpToolResult.error(
            'The run was declined in APK Forge: nothing was signed.',
          );
        case RunApproval.anotherWaiting:
          return McpToolResult.error(
            'APK Forge is already asking its user about another run. Try '
            'again once it is answered.',
          );
      }
      // A task may have started in the app meanwhile.
      if (_busy() case final busy?) return busy;
    }

    final startedBy = StartedByAgent(agent, allowedInApp: asks);
    if (await run(profile, checked, startedBy) case final record?) {
      return McpToolResult(runResultJson(record));
    }
    if (_busy() case final busy?) return busy;
    if (task().failure case final failure?) {
      return _failure('The run failed', failure);
    }
    if (lastRun()?.record case final record?
        when record.profileId == profile.id && record.cancelled) {
      return McpToolResult(runResultJson(record));
    }
    return McpToolResult.error('The run didn\'t finish: see APK Forge\'s log.');
  }

  Future<McpToolResult> _listRuns(Map<String, Object?> arguments) async {
    final read = ProfileRunsArguments.read(arguments);
    if (read.problem case final problem?) return McpToolResult.error(problem);
    final lookup = findProfile(read.profile, profiles());
    final profile = lookup.profile;
    if (profile == null) return McpToolResult.error(lookup.problem!);
    return McpToolResult({
      'profile': profile.name,
      'runs': [
        for (final record in history(profile.id).take(read.limit))
          runSummaryJson(record),
      ],
    });
  }

  /// The profile and the APKs the arguments name, or what's wrong with
  /// them.
  (SigningProfile?, List<String>, String?) _runArguments(
    Map<String, Object?> arguments,
  ) {
    final read = ProfileRunArguments.read(arguments, host: host, probe: probe);
    if (read.problem case final problem?) return (null, const [], problem);
    final lookup = findProfile(read.profile, profiles());
    return (lookup.profile, read.apks, lookup.problem);
  }

  Future<ProfileRunCheck> _checked(SigningProfile profile, List<String> apks) {
    apks.forEach(reread);
    return check(profile.id, apks);
  }

  Map<String, Object?> _checkJson(
    SigningProfile profile,
    ProfileRunCheck checked,
  ) => runCheckJson(
    profile,
    canRun: checked.canRun,
    inputs: checked.inputs,
    plan: checked.plan,
    keyAliases: checked.keys?.map((path, key) => MapEntry(path, key.alias)),
    keyFailure: checked.keyFailure,
    host: host,
  );

  /// One task at a time, as in the app.
  McpToolResult? _busy() => switch (task().running) {
    final running? => McpToolResult.error(
      'APK Forge is busy: $running. Try again once it is done.',
    ),
    null => null,
  };

  McpToolResult _failure(String what, ToolFailure failure) =>
      McpToolResult.error(
        '$what: ${failure.title}',
        data: {'details': failure.details},
      );

  String _names(List<String> apks) => apks.map(host.path.basename).join(', ');
}

final mcpToolboxProvider = Provider<McpToolbox>(
  (ref) => ProfileMcpTools(
    profiles: () => ref.read(profilesProvider).profiles,
    history: (profileId) =>
        ref.read(profileHistoryProvider.notifier).of(profileId),
    keySummary: (path) => ref.read(profileKeyServiceProvider).summarize(path),
    reread: (path) => ref.invalidate(apkReportProvider(path)),
    check: (profileId, apks) async {
      final provider = profileRunCheckProvider((
        profileId: profileId,
        inputs: apks.join('\n'),
      ));
      // Kept alive until it's read: no dialog may be watching it.
      final subscription = ref.listen(provider, (_, _) {});
      try {
        return await ref.read(provider.future);
      } finally {
        subscription.close();
      }
    },
    askToRun: () => ref.read(mcpServerProvider).settings.askToRun,
    approve: (profile, check) =>
        ref.read(mcpRunRequestProvider.notifier).ask(profile, check),
    run: (profile, check, startedBy) => ref
        .read(profileRunActionProvider)
        .run(profile, check, startedBy: startedBy),
    task: () => ref.read(taskProvider),
    lastRun: () => ref.read(profileRunProvider),
    log: ref.read(logProvider.notifier),
    probe: ref.watch(fileProbeProvider),
    host: ref.watch(hostProvider),
  ),
);
