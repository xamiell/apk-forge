import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/format.dart';
import '../../domain/profiles/profile.dart';
import '../../state/forms.dart';
import '../../state/profiles.dart';
import '../../state/providers.dart';
import '../theme.dart';
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
              dataRowMaxHeight: 56,
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
                      DataCell(_KeyCell(path: target.keyProperties)),
                      DataCell(
                        Text(
                          target.schemes?.label ??
                              'Defaults (${defaultSchemes.label})',
                        ),
                      ),
                      DataCell(_FolderCell(path: target.outputDir.trim())),
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

/// A target's output folder, flagged when it doesn't exist on this machine
/// (a profile imported from another one).
class _FolderCell extends ConsumerWidget {
  const _FolderCell({required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.status;
    if (path.isEmpty) {
      return Text('Not set', style: TextStyle(color: colors.warning));
    }
    final missing = !ref.watch(fileProbeProvider).directoryExists(path);
    final name = ref.watch(hostProvider).path.basename(path);
    return Tooltip(
      message: missing ? '$path\nDoes not exist on this machine.' : path,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (missing)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: colors.warning,
              ),
            ),
          Text(name),
        ],
      ),
    );
  }
}

/// The key's alias, read from its `key.properties`, or what's wrong with it.
class _KeyCell extends ConsumerWidget {
  const _KeyCell({required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.status;
    if (path.isEmpty) {
      return Text('Not set', style: TextStyle(color: colors.warning));
    }
    final summary = ref.watch(keyFileSummaryProvider(path)).value;
    final problems = summary?.problems ?? const [];
    return Tooltip(
      message: problems.isEmpty ? path : '$path\n${problems.join('\n')}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (problems.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: colors.warning,
              ),
            ),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                summary?.alias ?? '?',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                shortPath(path, ref.watch(hostProvider)),
                style: TextStyle(fontSize: 11.5, color: colors.muted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
