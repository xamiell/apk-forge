import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/system/host.dart';
import '../../domain/profiles/profile.dart';
import '../../domain/profiles/profile_run.dart';
import '../../services/profile_runner.dart';
import '../apks.dart';
import '../profiles.dart';
import '../providers.dart';
import '../task_notifier.dart';
import '../toolchain_notifier.dart';

/// Runs a profile as its check planned it, with the keys the check opened.
class ProfileRunAction {
  const ProfileRunAction({
    required this.task,
    required this.toolchain,
    required this.runner,
    required this.progress,
    required this.addToHistory,
    required this.list,
    required this.reveal,
    required this.clock,
    required this.host,
  });

  final TaskRunner task;
  final ToolchainSource toolchain;
  final ProfileRunner runner;
  final ProfileRunProgress progress;
  final void Function(ProfileRunRecord record) addToHistory;
  final ApkSink list;
  final FileRevealer reveal;
  final DateTime Function() clock;
  final Host host;

  /// The progress goes to [progress], the record to the history, and each
  /// signed APK to the list. `null` when [check] can't run, another task is
  /// running, or the run failed.
  Future<ProfileRunRecord?> run(
    SigningProfile profile,
    ProfileRunCheck check,
  ) async {
    if (!check.canRun || task.isRunning) return null;
    progress.start(profile.id, check.plan, host);
    final startedAt = clock();

    return task.run('Run profile ${profile.name}', (executor) async {
      final tools = await toolchain();
      final results = await runner.run(
        executor,
        toolchain: tools,
        plan: check.plan,
        keys: check.keys!,
        onProgress: progress.update,
      );
      final record = ProfileRunRecord(
        profileId: profile.id,
        profileName: profile.name,
        startedAt: startedAt,
        finishedAt: clock(),
        inputs: [
          for (final input in check.inputs)
            RunInput.fromReport(input, name: host.path.basename(input.path)),
        ],
        results: results,
        cancelled: executor.isCancelled,
        fileNamePattern: profile.fileNamePattern,
        inputChecks: profile.input,
        buildToolsVersion: tools.buildToolsVersion,
      );
      addToHistory(record);
      progress.finish(record);

      final signed = [
        for (final result in results)
          if (result.status == TargetStatus.signed) result.outputPath!,
      ];
      for (final path in signed) {
        list.add(path, ApkOrigin.signed, select: false);
      }
      executor.log.success('${profile.name}: ${record.summary}.');
      if (profile.afterRun == AfterRun.openFolders) {
        // One window per folder, with its APK selected.
        final byFolder = {
          for (final path in signed) host.path.dirname(path): path,
        };
        for (final path in byFolder.values) {
          await reveal(path, host);
        }
      }
      return record;
    });
  }
}

final profileRunActionProvider = Provider(
  (ref) => ProfileRunAction(
    task: ref.watch(taskProvider.notifier),
    toolchain: () => ref.read(toolchainProvider.future),
    runner: ref.watch(profileRunnerProvider),
    progress: ref.watch(profileRunProvider.notifier),
    addToHistory: ref.watch(profileHistoryProvider.notifier).add,
    list: ref.watch(apkListProvider.notifier),
    reveal: ref.watch(fileRevealerProvider),
    clock: ref.watch(clockProvider),
    host: ref.watch(hostProvider),
  ),
);
