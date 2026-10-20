import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/format.dart';
import '../../domain/profiles/profile.dart';
import '../../domain/profiles/target_problems.dart';
import '../../state/forms.dart';
import '../../state/profiles.dart';
import '../../state/providers.dart';
import '../common/widgets.dart';
import '../theme.dart';
import 'create_folder_button.dart';
import 'target_sheet.dart';

/// The Targets step: a table of the profile's targets, each one opened in
/// the target editor.
class TargetsStep extends ConsumerWidget {
  const TargetsStep({
    super.key,
    required this.profile,
    required this.onChanged,
  });

  final SigningProfile profile;
  final ValueChanged<SigningProfile> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.status;
    final defaultSchemes = ref.watch(defaultsProvider.select((d) => d.schemes));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (profile.targets.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'A target is one APK to write: for a device, with its ABI, its '
              'key and its folder.',
              style: TextStyle(fontSize: 12.5, color: colors.muted),
            ),
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 36,
              dataRowMinHeight: 44,
              // A problem is written out under the value.
              dataRowMaxHeight: double.infinity,
              columns: const [
                DataColumn(label: Text('Target')),
                DataColumn(label: Text('ABI')),
                DataColumn(label: Text('Key (key.properties)')),
                DataColumn(label: Text('Schemes')),
                DataColumn(label: Text('Output folder')),
                DataColumn(label: SizedBox.shrink()),
              ],
              rows: [
                for (final target in profile.targets)
                  DataRow(
                    cells: [
                      DataCell(
                        Text(
                          target.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      DataCell(Text(target.abiName)),
                      DataCell(_KeyCell(target: target)),
                      DataCell(
                        _FieldCell(
                          value:
                              target.schemes?.label ??
                              'Defaults (${defaultSchemes.label})',
                          problems: _messages(
                            ref.watch(targetProblemsProvider(target)),
                            TargetField.schemes,
                          ),
                        ),
                      ),
                      DataCell(_FolderCell(target: target)),
                      DataCell(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Edit ${target.name}',
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              onPressed: () => showTargetSheet(
                                context,
                                profile: profile,
                                target: target,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Remove ${target.name}',
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () => onChanged(
                                profile.copyWith(
                                  targets: [
                                    for (final t in profile.targets)
                                      if (t.id != target.id) t,
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () => showTargetSheet(context, profile: profile),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add target'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Targets with the same ABI, key and schemes are signed once '
                'and copied to each folder.',
                style: TextStyle(fontSize: 12.5, color: colors.muted),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

List<String> _messages(List<TargetProblem> problems, TargetField field) => [
  for (final problem in problems)
    if (problem.field == field) problem.message,
];

/// One field of a target in the table: its value, then what stops it from
/// running, written out with the warning icon, or else a muted detail.
class _FieldCell extends StatelessWidget {
  const _FieldCell({
    required this.value,
    this.strong = false,
    this.detail,
    this.problems = const [],
    this.tooltip,
    this.action,
  });

  final String value;
  final bool strong;
  final String? detail;
  final List<String> problems;
  final String? tooltip;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final cell = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: strong ? const TextStyle(fontWeight: FontWeight.w600) : null,
          ),
          if (problems.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: ProblemText(problems),
            )
          else if (detail != null)
            Text(
              detail!,
              style: TextStyle(fontSize: 11.5, color: context.status.muted),
            ),
          ?action,
        ],
      ),
    );
    return tooltip == null ? cell : Tooltip(message: tooltip!, child: cell);
  }
}

/// The key's alias, read from its `key.properties`, and what's wrong with
/// it.
class _KeyCell extends ConsumerWidget {
  const _KeyCell({required this.target});

  final ProfileTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = target.keyProperties.trim();
    final summary = path.isEmpty
        ? null
        : ref.watch(keyFileSummaryProvider(path)).value;
    return _FieldCell(
      value: path.isEmpty ? 'Not set' : summary?.alias ?? '?',
      strong: path.isNotEmpty,
      detail: path.isEmpty ? null : shortPath(path, ref.watch(hostProvider)),
      problems: _messages(
        ref.watch(targetProblemsProvider(target)),
        TargetField.key,
      ),
      tooltip: path.isEmpty ? null : path,
    );
  }
}

/// A target's output folder, and what's wrong with it. A folder that
/// doesn't exist on this machine can be created from here.
class _FolderCell extends ConsumerWidget {
  const _FolderCell({required this.target});

  final ProfileTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = target.outputDir.trim();
    final problems = [
      for (final problem in ref.watch(targetProblemsProvider(target)))
        if (problem.field == TargetField.outputFolder) problem,
    ];
    final missing = problems.firstOrNull?.missingPath;
    return _FieldCell(
      value: path.isEmpty
          ? 'Not set'
          : ref.watch(hostProvider).path.basename(path),
      problems: [for (final problem in problems) problem.message],
      tooltip: path.isEmpty ? null : path,
      action: missing == null ? null : CreateFolderButton(path: missing),
    );
  }
}
