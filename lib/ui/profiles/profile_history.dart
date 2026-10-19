import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/format.dart';
import '../../core/system/host.dart';
import '../../domain/profiles/profile.dart';
import '../../domain/profiles/profile_run.dart';
import '../../state/apks.dart';
import '../../state/profiles.dart';
import '../../state/providers.dart';
import '../common/widgets.dart';
import '../theme.dart';

/// The History tab: the profile's runs, newest first, and the results of
/// the one selected.
class ProfileHistory extends ConsumerStatefulWidget {
  const ProfileHistory({super.key, required this.profile});

  final SigningProfile profile;

  @override
  ConsumerState<ProfileHistory> createState() => _ProfileHistoryState();
}

class _ProfileHistoryState extends ConsumerState<ProfileHistory> {
  var _selected = 0;

  @override
  Widget build(BuildContext context) {
    final colors = context.status;
    final runs = ref
        .watch(profileHistoryProvider)
        .where((run) => run.profileId == widget.profile.id)
        .toList();
    if (runs.isEmpty) {
      return Center(
        child: Text(
          'No runs yet. Run the profile to see its results here.',
          style: TextStyle(color: colors.muted),
        ),
      );
    }
    final selected = runs[_selected.clamp(0, runs.length - 1)];

    Future<void> clear() async {
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Clear the history?'),
          content: Text(
            'The ${runs.length} run${runs.length == 1 ? '' : 's'} of '
            '${widget.profile.name} are forgotten. The signed APKs stay '
            'where they are.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Clear'),
            ),
          ],
        ),
      );
      if (sure ?? false) {
        ref.read(profileHistoryProvider.notifier).clear(widget.profile.id);
      }
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 300,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(8),
                  children: [
                    for (final (index, run) in runs.indexed)
                      ListTile(
                        selected: run == selected,
                        selectedTileColor: Theme.of(context)
                            .colorScheme
                            .primaryContainer
                            .withValues(alpha: 0.35),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        title: Text(
                          formatDateTime(run.startedAt),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          '${run.inputs.map(_inputLine).join(', ')}\n${run.summary}',
                          style: TextStyle(
                            fontSize: 12,
                            color: run.count(TargetStatus.failed) > 0
                                ? colors.error
                                : null,
                          ),
                        ),
                        isThreeLine: true,
                        onTap: () => setState(() => _selected = index),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colors.error,
                  ),
                  onPressed: clear,
                  child: const Text('Clear history…'),
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: _RunResults(run: selected)),
      ],
    );
  }

  static String _inputLine(RunInput input) => [
    input.name,
    if (input.versionName != null)
      '${input.versionName} (${input.versionCode})',
  ].join(' · ');
}

class _RunResults extends ConsumerWidget {
  const _RunResults({required this.run});

  final ProfileRunRecord run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.status;
    final probe = ref.watch(fileProbeProvider);
    final host = ref.watch(hostProvider);
    final duration = run.finishedAt.difference(run.startedAt);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          formatDateTime(run.startedAt),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 2),
        Text(
          [
            for (final input in run.inputs)
              [
                input.name,
                ?input.packageName,
                if (input.versionName != null)
                  '${input.versionName} (${input.versionCode})',
                if (input.sha256.isNotEmpty)
                  'SHA-256 ${shortDigest(input.sha256)}',
              ].join(' · '),
            'took ${duration.inSeconds} s',
          ].join('\n'),
          style: TextStyle(fontSize: 12.5, color: colors.muted),
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 36,
            dataRowMinHeight: 40,
            dataRowMaxHeight: 56,
            columnSpacing: 24,
            columns: const [
              DataColumn(label: Text('Target')),
              DataColumn(label: Text('Status')),
              DataColumn(label: Text('Output or reason')),
              DataColumn(label: Text('Size')),
              DataColumn(label: SizedBox.shrink()),
            ],
            rows: [
              for (final result in run.results)
                _row(context, ref, result, probe, host, colors),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Kept across restarts, newest first. Holds names, versions, paths '
          'and digests, never a password.',
          style: TextStyle(fontSize: 12, color: colors.muted),
        ),
      ],
    );
  }

  DataRow _row(
    BuildContext context,
    WidgetRef ref,
    TargetResult result,
    FileProbe probe,
    Host host,
    StatusColors colors,
  ) {
    final missing =
        result.status == TargetStatus.signed &&
        !probe.fileExists(result.outputPath!);
    final (label, color) = missing
        ? ('Missing', colors.warning)
        : switch (result.status) {
            TargetStatus.signed => ('Signed', colors.ok),
            TargetStatus.failed => ('Failed', colors.error),
            TargetStatus.skipped => ('Skipped', colors.muted),
          };
    return DataRow(
      cells: [
        DataCell(
          Text(
            result.target,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        DataCell(Pill(label, color: color)),
        DataCell(
          SizedBox(
            width: 300,
            child: Tooltip(
              message: result.outputPath ?? '',
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    missing
                        ? '${shortPath(result.outputPath!, host)} was moved or '
                              'deleted since'
                        : result.outputPath == null
                        ? result.reason ?? ''
                        : shortPath(result.outputPath!, host),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: result.status == TargetStatus.failed
                          ? colors.error
                          : null,
                    ),
                  ),
                  if (result.signerSha256 != null)
                    Text(
                      'Signer SHA-256 ${shortDigest(result.signerSha256!)}',
                      style: monospace.copyWith(
                        fontSize: 11.5,
                        color: colors.muted,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        DataCell(
          Text(result.sizeBytes == null ? '' : formatBytes(result.sizeBytes!)),
        ),
        DataCell(
          result.status == TargetStatus.signed && !missing
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Show in its folder',
                      icon: const Icon(Icons.folder_open_outlined, size: 18),
                      onPressed: () => ref.read(fileRevealerProvider)(
                        result.outputPath!,
                        ref.read(hostProvider),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Analyze',
                      icon: const Icon(Icons.manage_search_rounded, size: 18),
                      onPressed: () {
                        ref
                            .read(apkListProvider.notifier)
                            .add(result.outputPath!, ApkOrigin.signed);
                        ref
                            .read(appViewProvider.notifier)
                            .show(AppView.workbench);
                      },
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
