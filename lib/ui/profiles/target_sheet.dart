import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/build/build_options.dart';
import '../../domain/profiles/key_properties.dart';
import '../../domain/profiles/profile.dart';
import '../../domain/profiles/target_problems.dart';
import '../../state/forms.dart';
import '../../state/profiles.dart';
import '../common/file_types.dart';
import '../common/widgets.dart';
import '../theme.dart';
import 'create_folder_button.dart';

/// Edits [target] of [profile], or adds a new one, in a panel on the right.
Future<void> showTargetSheet(
  BuildContext context, {
  required SigningProfile profile,
  ProfileTarget? target,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Close',
  barrierColor: Colors.black54,
  transitionDuration: const Duration(milliseconds: 180),
  pageBuilder: (_, _, _) => Align(
    alignment: Alignment.centerRight,
    child: _TargetSheet(profile: profile, target: target),
  ),
  transitionBuilder: (_, animation, _, child) => SlideTransition(
    position: Tween(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
    child: child,
  ),
);

class _TargetSheet extends ConsumerStatefulWidget {
  const _TargetSheet({required this.profile, this.target});

  final SigningProfile profile;
  final ProfileTarget? target;

  @override
  ConsumerState<_TargetSheet> createState() => _TargetSheetState();
}

class _TargetSheetState extends ConsumerState<_TargetSheet> {
  late ProfileTarget _draft =
      widget.target ??
      ProfileTarget(
        id: ref.read(profilesProvider.notifier).newId('t'),
        name: 'Target ${widget.profile.targets.length + 1}',
        abi: AndroidAbi.arm64V8a,
        // A new target starts with the last one's key: most profiles share
        // it. Folders differ per device.
        keyProperties: widget.profile.targets.isEmpty
            ? ''
            : widget.profile.targets.last.keyProperties,
      );

  void _set(ProfileTarget draft) => setState(() => _draft = draft);

  void _save() {
    final profiles = ref.read(profilesProvider.notifier);
    final current = ref.read(profilesProvider).byId(widget.profile.id);
    if (current == null) return;
    // Spaces are kept while typing (a path may have them inside) and
    // trimmed only here, at the ends.
    final draft = _draft.copyWith(
      name: _draft.name.trim(),
      keyProperties: _draft.keyProperties.trim(),
      outputDir: _draft.outputDir.trim(),
    );
    final exists = current.targets.any((t) => t.id == draft.id);
    profiles.update(
      current.copyWith(
        targets: exists
            ? [for (final t in current.targets) t.id == draft.id ? draft : t]
            : [...current.targets, draft],
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.status;
    final nameMissing = _draft.name.trim().isEmpty;
    final defaultSchemes = ref.watch(defaultsProvider.select((d) => d.schemes));
    // Checked as the run check will: they don't stop saving, since a path
    // can be fixed later.
    final problems = ref.watch(targetProblemsProvider(_draft));
    TargetProblem? problemOf(TargetField field) =>
        problems.where((problem) => problem.field == field).firstOrNull;
    final folderProblem = problemOf(TargetField.outputFolder);
    return Material(
      key: const ValueKey('target-sheet'),
      elevation: 12,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SizedBox(
        width: 500,
        height: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.target == null ? 'New target' : 'Edit target',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                children: [
                  SyncedTextField(
                    label: 'Name',
                    hint: 'The device it\'s for',
                    value: _draft.name,
                    onChanged: (value) => _set(_draft.copyWith(name: value)),
                  ),
                  const SizedBox(height: 18),
                  const FieldLabel('ABI'),
                  const SizedBox(height: 6),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      for (final abi in AndroidAbi.values)
                        ButtonSegment(
                          value: abi.abiName,
                          label: Text(abi.abiName),
                        ),
                      const ButtonSegment(
                        value: ProfileTarget.universalAbiName,
                        label: Text('Universal'),
                      ),
                    ],
                    selected: {_draft.abiName},
                    onSelectionChanged: (choice) {
                      final abi = AndroidAbi.fromAbiName(choice.single);
                      _set(
                        abi == null
                            ? _draft.copyWith(universal: true)
                            : _draft.copyWith(abi: abi),
                      );
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _draft.abi == null
                        ? 'Keeps every ABI\'s native code.'
                        : 'The APK keeps only ${_draft.abi!.abiName}\'s native code.',
                    style: TextStyle(fontSize: 12, color: colors.muted),
                  ),
                  const SizedBox(height: 18),
                  PathField(
                    label: 'Key: key.properties file',
                    hint: 'storeFile, keyAlias, storePassword, keyPassword',
                    value: _draft.keyProperties,
                    problem: problemOf(TargetField.key)?.message,
                    onChanged: (value) =>
                        _set(_draft.copyWith(keyProperties: value)),
                    onBrowse: () async {
                      final file = await openFile(
                        acceptedTypeGroups: const [
                          keyPropertiesTypes,
                          XTypeGroup(label: 'All files'),
                        ],
                      );
                      if (file != null) {
                        _set(_draft.copyWith(keyProperties: file.path));
                      }
                    },
                  ),
                  if (_draft.keyProperties.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _KeyFileSummaryBox(path: _draft.keyProperties.trim()),
                  ],
                  const SizedBox(height: 14),
                  const FieldLabel('Signature schemes'),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      'The ones in Defaults (${defaultSchemes.label})',
                    ),
                    subtitle: const Text(
                      'Whatever Defaults has when the profile runs.',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: _draft.schemes == null,
                    onChanged: (on) => _set(
                      on ?? false
                          ? _draft.copyWith(defaultSchemes: true)
                          : _draft.copyWith(schemes: defaultSchemes),
                    ),
                  ),
                  if (_draft.schemes case final schemes?)
                    SchemesField(
                      schemes: schemes,
                      onChanged: (schemes) =>
                          _set(_draft.copyWith(schemes: schemes)),
                    ),
                  const SizedBox(height: 14),
                  PathField(
                    label: 'Output folder',
                    value: _draft.outputDir,
                    problem: folderProblem?.message,
                    onChanged: (value) =>
                        _set(_draft.copyWith(outputDir: value)),
                    onBrowse: () async {
                      final folder = await getDirectoryPath(
                        confirmButtonText: 'Choose folder',
                      );
                      if (folder != null) {
                        _set(_draft.copyWith(outputDir: folder));
                      }
                    },
                  ),
                  if (folderProblem?.missingPath case final missing?)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: CreateFolderButton(path: missing),
                    ),
                ],
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: ProblemText([
                      if (nameMissing) 'Give it a name.',
                      for (final problem in problems) problem.message,
                    ]),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: nameMissing ? null : _save,
                    child: const Text('Save target'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the `key.properties` says, read again each time the sheet opens. The
/// passwords are only said to be there, never shown.
class _KeyFileSummaryBox extends ConsumerWidget {
  const _KeyFileSummaryBox({required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.status;
    final summary = ref.watch(keyFileSummaryProvider(path));
    Widget row(String label, String value, {bool? ok, String? note}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 116,
            child: Text(
              label,
              style: monospace.copyWith(fontSize: 12, color: colors.muted),
            ),
          ),
          if (ok != null)
            Padding(
              padding: const EdgeInsets.only(right: 6, top: 1),
              child: Icon(
                ok ? Icons.check_rounded : Icons.close_rounded,
                size: 15,
                color: ok ? colors.ok : colors.error,
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  value,
                  style: TextStyle(
                    fontSize: 13,
                    color: ok == false ? colors.error : null,
                  ),
                ),
                if (note != null)
                  Text(
                    note,
                    style: TextStyle(fontSize: 12, color: colors.muted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: switch (summary) {
        AsyncData(:final value) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'READ FROM THE FILE',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 0.8,
                fontWeight: FontWeight.w700,
                color: colors.muted,
              ),
            ),
            const SizedBox(height: 6),
            if (value.error != null)
              row('key.properties', value.error!, ok: false)
            else ...[
              row(
                'storeFile',
                value.keystorePath ?? 'Missing',
                ok: value.keystorePath != null && value.keystoreExists,
                note: value.keystorePath == null
                    ? null
                    : value.keystoreExists
                    ? _whereFrom(value)
                    : 'Not found. ${_whereFrom(value)}',
              ),
              row(
                'keyAlias',
                value.alias ?? 'Missing',
                ok: value.alias != null ? null : false,
              ),
              row(
                'storePassword',
                value.hasStorePassword ? 'Present, not shown' : 'Missing',
                ok: value.hasStorePassword ? null : false,
              ),
              row(
                'keyPassword',
                value.hasKeyPassword ? 'Present, not shown' : 'Missing',
                ok: value.hasKeyPassword ? null : false,
              ),
            ],
            const SizedBox(height: 6),
            Text(
              'Read again when a run starts. The passwords stay in memory for '
              'that run, and are never shown, saved, logged or exported.',
              style: TextStyle(fontSize: 12, color: colors.muted),
            ),
          ],
        ),
        AsyncError(:final error) => Text(
          '$error',
          style: TextStyle(color: colors.error),
        ),
        _ => const LinearProgressIndicator(),
      },
    );
  }

  static String _whereFrom(KeyFileSummary summary) =>
      'As written: ${summary.storeFile}';
}
