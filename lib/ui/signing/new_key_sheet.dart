import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/format.dart';
import '../../domain/failure.dart';
import '../../domain/signing/keystore.dart';
import '../../domain/signing/new_key.dart';
import '../../domain/tools/toolchain.dart';
import '../../state/actions/new_key_action.dart';
import '../../state/providers.dart';
import '../../state/task_notifier.dart';
import '../../state/toolchain_notifier.dart';
import '../common/create_folder_button.dart';
import '../common/widgets.dart';
import '../theme.dart';

/// Makes a new upload key, in a panel on the right. Sign loads it once it's
/// made.
Future<void> showNewKeySheet(BuildContext context) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Close',
  barrierColor: Colors.black54,
  transitionDuration: const Duration(milliseconds: 180),
  pageBuilder: (_, _, _) =>
      const Align(alignment: Alignment.centerRight, child: _NewKeySheet()),
  transitionBuilder: (_, animation, _, child) => SlideTransition(
    position: Tween(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
    child: child,
  ),
);

class _NewKeySheet extends ConsumerStatefulWidget {
  const _NewKeySheet();

  @override
  ConsumerState<_NewKeySheet> createState() => _NewKeySheetState();
}

class _NewKeySheetState extends ConsumerState<_NewKeySheet> {
  /// The passwords live here, in memory, until the sheet closes.
  var _form = const NewKeyForm();

  /// A field's problem shows once it has been edited, not while the form is
  /// still empty. The footer counts them all.
  final _touched = <NewKeyField>{};

  /// Why the last Create failed.
  ToolFailure? _failure;

  void _set(NewKeyField field, NewKeyForm form) => setState(() {
    _form = form;
    _touched.add(field);
  });

  Future<void> _create() async {
    setState(() => _failure = null);
    final made = await ref.read(newKeyActionProvider).run(_form);
    if (!mounted) return;
    if (made) {
      Navigator.of(context).pop();
    } else {
      setState(() => _failure = ref.read(taskProvider).failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.status;
    final host = ref.watch(hostProvider);
    final busy = ref.watch(taskProvider.select((task) => task.isRunning));
    final toolchain = ref.watch(toolchainProvider).value;
    final problems = ref.watch(newKeyProblemsProvider(_form));
    final noKeytool = toolchain != null && !toolchain.canReadKeystore;

    NewKeyProblem? problemOf(NewKeyField field) =>
        problems.where((problem) => problem.field == field).firstOrNull;
    String? shown(NewKeyField field) =>
        _touched.contains(field) ? problemOf(field)?.message : null;
    final missingFolder = _touched.contains(NewKeyField.folder)
        ? problemOf(NewKeyField.folder)?.missingFolder
        : null;
    final years = int.tryParse(_form.validityYears.trim());

    Widget field(
      NewKeyField field,
      String label,
      String value,
      NewKeyForm Function(String value) change, {
      String? hint,
      bool obscure = false,
      bool showProblem = true,
    }) => SyncedTextField(
      label: label,
      hint: hint,
      value: value,
      obscure: obscure,
      problem: showProblem ? shown(field) : null,
      onChanged: (value) => _set(field, change(value)),
    );

    Widget pair(Widget left, Widget right) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 10),
        Expanded(child: right),
      ],
    );

    const gap = SizedBox(height: 12);
    const section = SizedBox(height: 20);

    return Material(
      key: const ValueKey('new-key-sheet'),
      elevation: 12,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SizedBox(
        width: 500,
        height: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'New key',
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                'Makes an upload key with keytool, and the '
                '$keyPropertiesFileName Gradle reads, in a folder you choose. '
                'Sign loads it when it\'s done.',
                style: TextStyle(fontSize: 12, color: colors.muted),
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                children: [
                  const FieldLabel('Files'),
                  PathField(
                    label: 'Folder',
                    value: _form.folder,
                    problem: shown(NewKeyField.folder),
                    onChanged: (value) =>
                        _set(NewKeyField.folder, _form.copyWith(folder: value)),
                    onBrowse: () async {
                      final folder = await getDirectoryPath(
                        confirmButtonText: 'Choose folder',
                      );
                      if (folder != null) {
                        _set(
                          NewKeyField.folder,
                          _form.copyWith(folder: folder),
                        );
                      }
                    },
                  ),
                  if (missingFolder != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: CreateFolderButton(path: missingFolder),
                    ),
                  gap,
                  field(
                    NewKeyField.fileName,
                    'Keystore file',
                    _form.fileName,
                    (value) => _form.copyWith(fileName: value),
                  ),
                  if (_form.folder.trim().isNotEmpty) ...[
                    gap,
                    _WritesBox(
                      paths: [
                        _form.keystorePath(host),
                        _form.keyPropertiesPath(host),
                      ],
                    ),
                  ],
                  section,
                  const FieldLabel('Key'),
                  field(
                    NewKeyField.alias,
                    'Alias',
                    _form.alias,
                    (value) => _form.copyWith(alias: value),
                  ),
                  gap,
                  SegmentedButton<KeystoreType>(
                    segments: [
                      for (final type in KeystoreType.values)
                        ButtonSegment(value: type, label: Text(type.label)),
                    ],
                    selected: {_form.type},
                    onSelectionChanged: (choice) => setState(
                      () => _form = _form.copyWith(type: choice.single),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(switch (_form.type) {
                    KeystoreType.pkcs12 =>
                      'One password for the keystore and its key. keytool\'s '
                          'default, and what Flutter\'s guide makes.',
                    KeystoreType.jks =>
                      'Lets the key have a password of its own. keytool calls '
                          'JKS a proprietary format and suggests PKCS12.',
                  }, style: TextStyle(fontSize: 12, color: colors.muted)),
                  gap,
                  field(
                    NewKeyField.storePassword,
                    'Keystore password',
                    _form.storePassword,
                    (value) => _form.copyWith(storePassword: value),
                    obscure: true,
                  ),
                  gap,
                  field(
                    NewKeyField.confirmStorePassword,
                    'Confirm password',
                    _form.confirmStorePassword,
                    (value) => _form.copyWith(confirmStorePassword: value),
                    obscure: true,
                  ),
                  if (_form.type == KeystoreType.jks) ...[
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('The key uses the keystore password'),
                      value: _form.keyUsesStorePassword,
                      onChanged: (value) => setState(
                        () => _form = _form.copyWith(
                          keyUsesStorePassword: value ?? true,
                        ),
                      ),
                    ),
                    if (_form.hasOwnKeyPassword) ...[
                      field(
                        NewKeyField.keyPassword,
                        'Key password',
                        _form.keyPassword,
                        (value) => _form.copyWith(keyPassword: value),
                        obscure: true,
                      ),
                      gap,
                      field(
                        NewKeyField.confirmKeyPassword,
                        'Confirm key password',
                        _form.confirmKeyPassword,
                        (value) => _form.copyWith(confirmKeyPassword: value),
                        obscure: true,
                      ),
                    ],
                  ],
                  section,
                  const FieldLabel('Certificate'),
                  field(
                    NewKeyField.commonName,
                    'Name (CN)',
                    _form.commonName,
                    (value) => _form.copyWith(commonName: value),
                    hint: 'You, or your company',
                  ),
                  gap,
                  pair(
                    field(
                      NewKeyField.commonName,
                      'Organizational unit',
                      _form.organizationalUnit,
                      (value) => _form.copyWith(organizationalUnit: value),
                      showProblem: false,
                    ),
                    field(
                      NewKeyField.commonName,
                      'Organization',
                      _form.organization,
                      (value) => _form.copyWith(organization: value),
                      showProblem: false,
                    ),
                  ),
                  gap,
                  pair(
                    field(
                      NewKeyField.commonName,
                      'City',
                      _form.city,
                      (value) => _form.copyWith(city: value),
                      showProblem: false,
                    ),
                    field(
                      NewKeyField.commonName,
                      'State',
                      _form.state,
                      (value) => _form.copyWith(state: value),
                      showProblem: false,
                    ),
                  ),
                  gap,
                  pair(
                    field(
                      NewKeyField.countryCode,
                      'Country code',
                      _form.countryCode,
                      (value) => _form.copyWith(countryCode: value),
                      hint: 'US',
                    ),
                    field(
                      NewKeyField.validity,
                      'Valid for (years)',
                      _form.validityYears,
                      (value) => _form.copyWith(validityYears: value),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    problemOf(NewKeyField.validity) == null && years != null
                        ? 'A 2048-bit RSA key, as in Flutter\'s guide, valid '
                              'until ${formatDate(validUntil(ref.watch(clockProvider)(), years))}.'
                        : 'A 2048-bit RSA key, as in Flutter\'s guide.',
                    style: TextStyle(fontSize: 12, color: colors.muted),
                  ),
                  section,
                  _Note(
                    '$keyPropertiesFileName holds the passwords in plain '
                    'text, because Gradle reads them from it. Only you can '
                    'read it, and it\'s never overwritten. Back it up with '
                    'the keystore, and keep both out of git.',
                  ),
                  if (_failure case final failure?) ...[
                    gap,
                    _FailureBox(failure),
                  ],
                ],
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ProblemCount([
                        if (noKeytool) keytoolMissing.title,
                        for (final problem in problems) problem.message,
                      ]),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: problems.isEmpty && !busy && !noKeytool
                        ? _create
                        : null,
                    icon: busy
                        ? const SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.key_outlined, size: 16),
                    label: const Text('Create key'),
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

/// The two files Create writes.
class _WritesBox extends StatelessWidget {
  const _WritesBox({required this.paths});

  final List<String> paths;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Writes',
          style: TextStyle(fontSize: 12, color: context.status.muted),
        ),
        for (final path in paths)
          SelectableText(path, style: monospace.copyWith(fontSize: 12)),
      ],
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline_rounded, size: 16, color: context.status.muted),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
      ],
    ),
  );
}

class _FailureBox extends StatelessWidget {
  const _FailureBox(this.failure);

  final ToolFailure failure;

  @override
  Widget build(BuildContext context) {
    final color = context.status.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          failure.title,
          style: TextStyle(
            fontSize: 13,
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
        for (final line in failure.details)
          Text(line, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
}
