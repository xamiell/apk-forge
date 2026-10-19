import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/format.dart';
import '../../core/system/host.dart';
import '../../domain/profiles/profile.dart';
import '../../domain/profiles/profile_run.dart';
import '../../state/profiles.dart';
import '../../state/providers.dart';
import '../../state/task_notifier.dart';
import '../theme.dart';
import 'run_frame.dart';

/// While it runs, and once it's done: each target's progress, then the
/// summary and a way to the history.
class RunProgressView extends ConsumerWidget {
  const RunProgressView({super.key, required this.profile});

  final SigningProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(profileRunProvider);
    final colors = context.status;
    if (run == null || run.profileId != profile.id) {
      return RunDialogFrame(
        title: 'Run “${profile.name}”',
        onClose: () => Navigator.of(context).pop(),
        body: const Text('Another task is running. Try again once it is done.'),
        footer: const [],
      );
    }
    final record = run.record;
    final total = run.progress.length;
    final several = run.progress.map((p) => p.input).toSet().length > 1;

    return RunDialogFrame(
      title: record == null
          ? 'Running “${profile.name}”'
          : '${profile.name}: ${record.summary}',
      onClose: record == null ? null : () => Navigator.of(context).pop(),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(
            value: total == 0 ? null : run.finished / total,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
          const SizedBox(height: 12),
          for (final entry in run.progress)
            _ProgressRow(
              entry: entry,
              showInput: several,
              host: ref.watch(hostProvider),
            ),
        ],
      ),
      footer: [
        Expanded(
          child: Text(
            record == null
                ? 'A failed target doesn\'t stop the others. Cancelling leaves '
                      'no partial files.'
                : 'Saved to the profile\'s History. The signed APKs joined the '
                      'APK list.',
            style: TextStyle(fontSize: 12.5, color: colors.muted),
          ),
        ),
        if (record == null)
          TextButton(
            onPressed: () => ref.read(taskProvider.notifier).cancel(),
            child: const Text('Cancel'),
          )
        else ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () {
              ref.read(profilesProvider.notifier).select(profile.id);
              ref.read(profileTabProvider.notifier).show(ProfileTab.history);
              ref.read(appViewProvider.notifier).show(AppView.profiles);
              Navigator.of(context).pop();
            },
            child: const Text('View in History'),
          ),
        ],
      ],
    );
  }
}

class _ProgressRow extends StatelessWidget {
  const _ProgressRow({
    required this.entry,
    required this.showInput,
    required this.host,
  });

  final TargetProgress entry;
  final bool showInput;
  final Host host;

  @override
  Widget build(BuildContext context) {
    final colors = context.status;
    final result = entry.result;
    final working =
        entry.stage != TargetStage.waiting &&
        entry.stage != TargetStage.finished;
    final (icon, color) = switch (result?.status) {
      TargetStatus.signed => (Icons.check_circle_rounded, colors.ok),
      TargetStatus.failed => (Icons.error_rounded, colors.error),
      TargetStatus.skipped => (Icons.remove_circle_rounded, colors.warning),
      null when working => (Icons.play_circle_rounded, colors.info),
      null => (Icons.schedule_rounded, colors.muted),
    };
    final detail = switch (result?.status) {
      TargetStatus.signed => shortPath(result!.outputPath!, host),
      TargetStatus.failed || TargetStatus.skipped => result!.reason ?? '',
      null => '${entry.stage.label}${working ? '…' : ''}',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: color),
          const SizedBox(width: 12),
          SizedBox(
            width: 160,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.target,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (showInput)
                  Text(
                    entry.input,
                    style: TextStyle(fontSize: 12, color: colors.muted),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Tooltip(
                  message: result?.outputPath ?? '',
                  child: SelectableText(
                    detail,
                    style: TextStyle(
                      fontSize: 13,
                      color: result?.status == TargetStatus.failed
                          ? colors.error
                          : result?.status == TargetStatus.skipped
                          ? colors.warning
                          : null,
                    ),
                  ),
                ),
                if (working)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: LinearProgressIndicator(minHeight: 3),
                  ),
              ],
            ),
          ),
          if (result?.sizeBytes != null)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                formatBytes(result!.sizeBytes!),
                style: TextStyle(fontSize: 12.5, color: colors.muted),
              ),
            ),
        ],
      ),
    );
  }
}
