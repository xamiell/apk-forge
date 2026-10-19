import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/format.dart';
import '../../core/system/host.dart';
import '../../domain/profiles/profile.dart';
import '../../domain/profiles/profile_run.dart';
import '../../state/apks.dart';
import '../../state/forms.dart';
import '../../state/profiles.dart';
import '../../state/providers.dart';
import '../../state/task_notifier.dart';
import '../common/file_types.dart';
import '../common/widgets.dart';
import '../theme.dart';
import 'run_dialog.dart';
import 'target_sheet.dart';

/// Where profiles are set up: the list on the left, the selected profile's
/// Setup or History on the right.
class ProfilesView extends ConsumerWidget {
  const ProfilesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(profilesProvider.select((s) => s.selected));
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(width: 280, child: _ProfileList()),
          const SizedBox(width: 16),
          Expanded(
            child: selected == null
                ? const _NoProfile()
                : _ProfileEditor(profile: selected),
          ),
        ],
      ),
    );
  }
}

class _ProfileList extends ConsumerWidget {
  const _ProfileList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(profilesProvider);
    final history = ref.watch(profileHistoryProvider);
    final notifier = ref.read(profilesProvider.notifier);

    Future<void> import() async {
      final file = await openFile(acceptedTypeGroups: const [profileTypes]);
      if (file == null) return;
      final SigningProfile profile;
      try {
        profile = importProfile(await file.readAsString());
      } on FormatException catch (error) {
        if (context.mounted) _snack(context, error.message);
        return;
      }
      // A name already in the list gets a number.
      final id = notifier.add(profile);
      final name = ref.read(profilesProvider).byId(id)!.name;
      final missing = missingProfilePaths(profile, ref.read(fileProbeProvider));
      if (!context.mounted) return;
      if (missing.isEmpty) {
        _snack(context, 'Imported $name.');
      } else {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Imported $name'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'These don\'t exist on this machine. Pick them again in '
                    'each target before running it:',
                  ),
                  const SizedBox(height: 10),
                  for (final path in missing)
                    SelectableText('• $path', style: monospace),
                ],
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }

    return SectionCard(
      title: 'Profiles',
      icon: Icons.layers_outlined,
      expand: true,
      trailing: IconButton(
        tooltip: 'New profile',
        icon: const Icon(Icons.add_rounded),
        onPressed: notifier.create,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: [
                for (final profile in state.profiles)
                  ListTile(
                    selected: profile.id == state.selectedId,
                    selectedTileColor: Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withValues(alpha: 0.35),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    title: Text(
                      profile.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      _profileLine(
                        profile,
                        history
                            .where((r) => r.profileId == profile.id)
                            .firstOrNull,
                      ),
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () => notifier.select(profile.id),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: OutlinedButton.icon(
              onPressed: import,
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Import profile…'),
            ),
          ),
        ],
      ),
    );
  }

  static String _profileLine(SigningProfile profile, ProfileRunRecord? last) {
    final targets = profile.targets.length;
    final keys = profile.keyFiles.length;
    return [
      '$targets target${targets == 1 ? '' : 's'}',
      '$keys key${keys == 1 ? '' : 's'}',
      if (last != null) 'last run ${_when(last.startedAt)}',
    ].join(' · ');
  }
}

class _NoProfile extends ConsumerWidget {
  const _NoProfile();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Card(
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.layers_outlined, size: 48, color: context.status.muted),
          const SizedBox(height: 10),
          const Text('No profiles yet'),
          const SizedBox(height: 4),
          Text(
            'A profile saves the steps to turn one APK into a signed APK per '
            'device: each with its ABI, its key and its folder.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: context.status.muted),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: ref.read(profilesProvider.notifier).create,
            icon: const Icon(Icons.add_rounded),
            label: const Text('New profile'),
          ),
        ],
      ),
    ),
  );
}

class _ProfileEditor extends ConsumerWidget {
  const _ProfileEditor({required this.profile});

  final SigningProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(profileTabProvider);
    final notifier = ref.read(profilesProvider.notifier);
    final busy = ref.watch(taskProvider.select((task) => task.isRunning));

    Future<void> export() async {
      final location = await getSaveLocation(
        suggestedName: '${profile.name}.json',
        acceptedTypeGroups: const [profileTypes],
      );
      if (location == null) return;
      await XFile.fromData(
        utf8.encode(exportProfile(profile)),
        mimeType: 'application/json',
      ).saveTo(location.path);
      if (context.mounted) _snack(context, 'Exported to ${location.path}.');
    }

    Future<void> delete() async {
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Delete ${profile.name}?'),
          content: const Text(
            'Its history goes too. The signed APKs and the key.properties '
            'files stay where they are.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (sure ?? false) notifier.delete(profile.id);
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 260,
                  child: SyncedTextField(
                    key: ValueKey('name-${profile.id}'),
                    label: 'Profile',
                    value: profile.name,
                    onChanged: (name) =>
                        notifier.update(profile.copyWith(name: name)),
                  ),
                ),
                SegmentedButton<ProfileTab>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: ProfileTab.setup,
                      label: Text('Setup'),
                    ),
                    ButtonSegment(
                      value: ProfileTab.history,
                      label: Text('History'),
                    ),
                  ],
                  selected: {tab},
                  onSelectionChanged: (choice) =>
                      ref.read(profileTabProvider.notifier).show(choice.single),
                ),
                IconButton(
                  tooltip: 'Duplicate profile',
                  icon: const Icon(Icons.copy_rounded, size: 20),
                  onPressed: () => notifier.duplicate(profile.id),
                ),
                OutlinedButton.icon(
                  onPressed: export,
                  icon: const Icon(Icons.upload_rounded, size: 18),
                  label: const Text('Export…'),
                ),
                IconButton(
                  tooltip: 'Delete profile',
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 20,
                    color: context.status.error,
                  ),
                  onPressed: delete,
                ),
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () => showRunProfileDialog(context, profile.id),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Run…'),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: tab == ProfileTab.setup
                ? _Setup(key: ValueKey('setup-${profile.id}'), profile: profile)
                : _History(profile: profile),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ Setup

enum _Step { input, targets, fileName, after }

/// The profile's steps, each one summary line; the one being edited opens.
class _Setup extends ConsumerStatefulWidget {
  const _Setup({super.key, required this.profile});

  final SigningProfile profile;

  @override
  ConsumerState<_Setup> createState() => _SetupState();
}

class _SetupState extends ConsumerState<_Setup> {
  _Step? _open = _Step.targets;

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final notifier = ref.read(profilesProvider.notifier);
    void update(SigningProfile changed) => notifier.update(changed);

    Widget step(
      _Step id,
      int number,
      String title,
      String summary,
      Widget body,
    ) => _StepTile(
      number: number,
      title: title,
      summary: summary,
      open: _open == id,
      onToggle: () => setState(() => _open = _open == id ? null : id),
      child: body,
    );

    final keys = profile.keyFiles.length;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        step(
          _Step.input,
          1,
          'Input',
          [
            profile.input.packageName ?? 'Any package',
            if (profile.input.mustBeUnsigned) 'must be unsigned',
          ].join(' · '),
          _InputStep(profile: profile, onChanged: update),
        ),
        step(
          _Step.targets,
          2,
          'Targets',
          profile.targets.isEmpty
              ? 'None yet'
              : '${profile.targets.length} '
                    'target${profile.targets.length == 1 ? '' : 's'} · '
                    '$keys key${keys == 1 ? '' : 's'}',
          _TargetsStep(profile: profile, onChanged: update),
        ),
        step(
          _Step.fileName,
          3,
          'File name',
          '${profile.fileNamePattern}.apk',
          _FileNameStep(profile: profile, onChanged: update),
        ),
        step(
          _Step.after,
          4,
          'After',
          profile.afterRun.label,
          _AfterStep(profile: profile, onChanged: update),
        ),
      ],
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({
    required this.number,
    required this.title,
    required this.summary,
    required this.open,
    required this.onToggle,
    required this.child,
  });

  final int number;
  final String title;
  final String summary;
  final bool open;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A Material, not a colored box: the step's list tiles (checkboxes,
    // radios) paint their background and splashes on it.
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: open
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.4)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: Theme.of(context).dividerColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: scheme.primaryContainer,
                      child: Text(
                        '$number',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    SizedBox(
                      width: 96,
                      child: Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: context.status.muted),
                      ),
                    ),
                    AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Icon(
                        Icons.expand_more_rounded,
                        color: context.status.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (open)
              Padding(
                padding: const EdgeInsets.fromLTRB(56, 0, 16, 16),
                child: child,
              ),
          ],
        ),
      ),
    );
  }
}

class _InputStep extends StatelessWidget {
  const _InputStep({required this.profile, required this.onChanged});

  final SigningProfile profile;
  final ValueChanged<SigningProfile> onChanged;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 520),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SyncedTextField(
          label: 'Package name',
          hint: 'Empty: any package',
          value: profile.input.packageName ?? '',
          onChanged: (value) => onChanged(
            profile.copyWith(
              input: InputChecks(
                packageName: value.trim().isEmpty ? null : value.trim(),
                mustBeUnsigned: profile.input.mustBeUnsigned,
              ),
            ),
          ),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('The input must be unsigned'),
          value: profile.input.mustBeUnsigned,
          onChanged: (value) => onChanged(
            profile.copyWith(
              input: InputChecks(
                packageName: profile.input.packageName,
                mustBeUnsigned: value ?? false,
              ),
            ),
          ),
        ),
        Text(
          'The run stops before signing when an input doesn\'t match, and '
          'says why.',
          style: TextStyle(fontSize: 12.5, color: context.status.muted),
        ),
      ],
    ),
  );
}

class _TargetsStep extends ConsumerWidget {
  const _TargetsStep({required this.profile, required this.onChanged});

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

class _FileNameStep extends StatelessWidget {
  const _FileNameStep({required this.profile, required this.onChanged});

  final SigningProfile profile;
  final ValueChanged<SigningProfile> onChanged;

  @override
  Widget build(BuildContext context) {
    final example = profile.targets.isEmpty ? null : profile.targets.first;
    final problems = fileNamePatternProblems(profile.fileNamePattern);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SyncedTextField(
            key: ValueKey('pattern-${profile.fileNamePattern.length}'),
            label: 'Pattern',
            value: profile.fileNamePattern,
            onChanged: (value) =>
                onChanged(profile.copyWith(fileNamePattern: value)),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final token in fileNameTokens)
                ActionChip(
                  label: Text(token, style: monospace.copyWith(fontSize: 12)),
                  onPressed: () => onChanged(
                    profile.copyWith(
                      fileNamePattern: '${profile.fileNamePattern}-$token',
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (problems.isNotEmpty)
            ProblemText(problems)
          else
            Text(
              'For app-release.apk 1.0.0: ${profileFileName(profile.fileNamePattern, name: 'app-release', target: example?.name ?? 'Phone', abi: example?.abiName ?? ProfileTarget.universalAbiName, versionName: '1.0.0', versionCode: '1', date: DateTime.now())}',
              style: TextStyle(fontSize: 12.5, color: context.status.muted),
            ),
        ],
      ),
    );
  }
}

class _AfterStep extends StatelessWidget {
  const _AfterStep({required this.profile, required this.onChanged});

  final SigningProfile profile;
  final ValueChanged<SigningProfile> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      RadioGroup<AfterRun>(
        groupValue: profile.afterRun,
        onChanged: (value) {
          if (value != null) onChanged(profile.copyWith(afterRun: value));
        },
        child: Column(
          children: [
            for (final value in AfterRun.values)
              RadioListTile<AfterRun>(
                value: value,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(value.label),
              ),
          ],
        ),
      ),
      Text(
        'Installing stays in Install, on the Workbench.',
        style: TextStyle(fontSize: 12.5, color: context.status.muted),
      ),
    ],
  );
}

// ---------------------------------------------------------------- History

class _History extends ConsumerStatefulWidget {
  const _History({required this.profile});

  final SigningProfile profile;

  @override
  ConsumerState<_History> createState() => _HistoryState();
}

class _HistoryState extends ConsumerState<_History> {
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
                          _when(run.startedAt),
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
          _when(run.startedAt),
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

String _when(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

void _snack(BuildContext context, String message) =>
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
