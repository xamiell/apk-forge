import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/format.dart';
import '../../domain/profiles/profile.dart';
import '../../domain/profiles/profile_run.dart';
import '../../domain/profiles/run_report.dart';
import '../../state/apks.dart';
import '../../state/profiles.dart';
import '../../state/providers.dart';
import '../common/file_types.dart';
import '../common/widgets.dart';
import '../theme.dart';

/// The History tab: the profile's runs, newest first, and the report of
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
                      _RunTile(
                        run: run,
                        selected: run == selected,
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
        Expanded(child: _RunDetail(run: selected)),
      ],
    );
  }
}

Color _outcomeColor(RunOutcome outcome, StatusColors colors) =>
    switch (outcome) {
      RunOutcome.allSigned || RunOutcome.someSkipped => colors.ok,
      RunOutcome.someFailed || RunOutcome.cancelled => colors.warning,
      RunOutcome.failed => colors.error,
      RunOutcome.nothingSigned => colors.muted,
    };

/// A run in the list: when, its outcome, the versions it signed and its
/// targets.
class _RunTile extends StatelessWidget {
  const _RunTile({
    required this.run,
    required this.selected,
    required this.onTap,
  });

  final ProfileRunRecord run;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.status;
    return ListTile(
      selected: selected,
      selectedTileColor: Theme.of(context).colorScheme.primaryContainer
          .withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      title: Row(
        children: [
          Expanded(
            child: Text(
              formatDateTime(run.startedAt),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Pill(run.outcome.label, color: _outcomeColor(run.outcome, colors)),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          '${run.versions.join(', ')}\n${run.targets.join(', ')}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
      ),
      isThreeLine: true,
      onTap: onTap,
    );
  }
}

/// The selected run's report, with Copy and Export.
class _RunDetail extends ConsumerWidget {
  const _RunDetail({required this.run});

  final ProfileRunRecord run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.status;
    final report = runReport(run);
    final theme = Theme.of(context);

    void snack(String message) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );

    Future<void> copy() async {
      await Clipboard.setData(ClipboardData(text: runReportText(report)));
      if (context.mounted) snack('Copied the run\'s report.');
    }

    Future<void> export() async {
      final location = await getSaveLocation(
        suggestedName: runReportFileName(run),
        acceptedTypeGroups: const [textTypes],
      );
      if (location == null) return;
      await XFile.fromData(
        utf8.encode(runReportText(report)),
        mimeType: 'text/plain',
      ).saveTo(location.path);
      if (context.mounted) snack('Exported to ${location.path}.');
    }

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 18, 0, 6),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(report.title, style: theme.textTheme.titleMedium),
            ),
            TextButton.icon(
              onPressed: copy,
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('Copy as text'),
            ),
            const SizedBox(width: 4),
            OutlinedButton.icon(
              onPressed: export,
              icon: const Icon(Icons.save_alt_rounded, size: 16),
              label: const Text('Export…'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _Lines(report.run),
        if (!run.hasDetails)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Saved by an earlier version, which kept only the outputs and '
              'their signer. What it didn\'t keep says "$notRecorded".',
              style: TextStyle(fontSize: 12, color: colors.muted),
            ),
          ),
        heading(report.inputs.length == 1 ? 'Input' : 'Inputs'),
        for (final input in report.inputs)
          _Block(title: input.input.name, child: _Lines(input.lines)),
        heading('Targets'),
        for (final target in report.targets) _TargetBlock(target: target),
        const SizedBox(height: 10),
        Text(
          'Kept across restarts, newest first. Holds names, versions, paths '
          'and digests, never a password.',
          style: TextStyle(fontSize: 12, color: colors.muted),
        ),
      ],
    );
  }
}

/// One target of the report: its status, its lines, and its APK's
/// actions while the APK is where the run wrote it.
class _TargetBlock extends ConsumerWidget {
  const _TargetBlock({required this.target});

  final TargetReport target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.status;
    final result = target.result;
    final output = result.outputPath;
    final signed = result.status == TargetStatus.signed && output != null;
    final gone = signed && ref.watch(signedApkGoneProvider(output));
    final (label, color) = gone
        ? ('Missing', colors.warning)
        : switch (result.status) {
            TargetStatus.signed => ('Signed', colors.ok),
            TargetStatus.failed => ('Failed', colors.error),
            TargetStatus.skipped => ('Skipped', colors.muted),
          };

    return _Block(
      title: target.title,
      trailing: [
        Pill(label, color: color),
        if (signed && !gone) ...[
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Show in its folder',
            icon: const Icon(Icons.folder_open_outlined, size: 18),
            onPressed: () =>
                ref.read(fileRevealerProvider)(output, ref.read(hostProvider)),
          ),
          IconButton(
            tooltip: 'Analyze',
            icon: const Icon(Icons.manage_search_rounded, size: 18),
            onPressed: () {
              ref.read(apkListProvider.notifier).add(output, ApkOrigin.signed);
              ref.read(appViewProvider.notifier).show(AppView.workbench);
            },
          ),
        ],
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (gone)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'It was moved or deleted since the run.',
                style: TextStyle(fontSize: 12.5, color: colors.warning),
              ),
            ),
          _Lines(target.lines),
        ],
      ),
    );
  }
}

/// A titled, outlined group of lines.
class _Block extends StatelessWidget {
  const _Block({
    required this.title,
    required this.child,
    this.trailing = const [],
  });

  final String title;
  final Widget child;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 36,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              ...trailing,
            ],
          ),
        ),
        child,
      ],
    ),
  );
}

class _Lines extends StatelessWidget {
  const _Lines(this.lines);

  final List<ReportLine> lines;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final line in lines)
        InfoRow(line.label, line.value, mono: line.mono),
    ],
  );
}
