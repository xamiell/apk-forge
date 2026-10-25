import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/tools/toolchain.dart';
import '../../state/toolchain_notifier.dart';
import '../common/widgets.dart';
import '../theme.dart';

/// The tools the app found, in the top bar. A missing one is red.
class ToolchainBar extends ConsumerWidget {
  const ToolchainBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(toolchainProvider)) {
      AsyncData(:final value) => Wrap(
        spacing: 6,
        children: [
          _ToolPill('Flutter', value.flutter, version: value.flutterVersion),
          _ToolPill(
            'build-tools',
            value.apksigner,
            version: value.buildToolsVersion,
          ),
          _ToolPill('adb', value.adb),
          _ToolPill('keytool', value.keytool),
          _ToolPill(
            'bundletool',
            value.bundletool,
            version: value.bundletoolVersion,
            missing:
                'bundletool not found: set it in Tools (the gear) to '
                'read and install App Bundles',
          ),
        ],
      ),
      AsyncError(:final error) => Text(
        '$error',
        style: TextStyle(color: context.status.error),
      ),
      _ => const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text('Looking for tools…', style: TextStyle(fontSize: 12.5)),
        ],
      ),
    };
  }
}

/// The gear in the top bar: opens Tools, the folders to set by hand.
class ToolsButton extends StatelessWidget {
  const ToolsButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Tools',
    icon: const Icon(Icons.settings_outlined, size: 20),
    onPressed: () =>
        showDialog<void>(context: context, builder: (_) => const ToolsDialog()),
  );
}

class _ToolPill extends StatelessWidget {
  const _ToolPill(this.name, this.path, {this.version, this.missing});

  final String name;
  final String? path;
  final String? version;

  /// The tooltip when [path] is `null`: what to do about it.
  final String? missing;

  @override
  Widget build(BuildContext context) {
    final found = path != null;
    return Tooltip(
      message: path ?? missing ?? '$name not found',
      child: Pill(
        version == null ? name : '$name $version',
        color: found ? context.status.ok : context.status.error,
        icon: found ? Icons.check_rounded : Icons.close_rounded,
      ),
    );
  }
}

class ToolsDialog extends ConsumerStatefulWidget {
  const ToolsDialog({super.key});

  @override
  ConsumerState<ToolsDialog> createState() => _ToolsDialogState();
}

class _ToolsDialogState extends ConsumerState<ToolsDialog> {
  late ToolOverrides _draft = ref.read(toolOverridesProvider);

  /// What the table shows: the fields as last checked. A pick checks at
  /// once; typed text, with Detect again.
  late ToolOverrides _checked = _draft.cleaned();

  /// The last result, kept on screen while the next one is read.
  Toolchain? _shown;

  void _set(ToolOverrides draft, {bool check = false}) => setState(() {
    _draft = draft;
    if (check) _checked = draft.cleaned();
  });

  void _detectAgain() {
    setState(() => _checked = _draft.cleaned());
    ref.invalidate(toolchainPreviewProvider);
    ref.read(toolchainProvider.notifier).refresh();
  }

  Future<String?> _folder() => getDirectoryPath(confirmButtonText: 'Choose');

  @override
  Widget build(BuildContext context) {
    final preview = ref.watch(toolchainPreviewProvider(_checked));
    final toolchain = _shown =
        preview.value ?? _shown ?? ref.watch(toolchainProvider).value;
    final available = toolchain?.availableBuildTools ?? const <String>[];
    final buildTools = _draft.buildToolsVersion ?? '';

    return AlertDialog(
      title: const Text('Tools'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Found from your shell\'s PATH, ANDROID_HOME, JAVA_HOME and '
                'the usual install folders. Set one only if a tool is '
                'missing or you want another version.',
                style: TextStyle(fontSize: 12.5, color: context.status.muted),
              ),
              const SizedBox(height: 14),
              PathField(
                label: 'Flutter SDK folder',
                hint: 'Detected from PATH',
                value: _draft.flutterSdk ?? '',
                onChanged: (value) => _set(_draft.copyWith(flutterSdk: value)),
                onBrowse: () async {
                  if (await _folder() case final folder?) {
                    _set(_draft.copyWith(flutterSdk: folder), check: true);
                  }
                },
              ),
              const SizedBox(height: 10),
              PathField(
                label: 'Android SDK folder',
                hint: 'Detected from ANDROID_HOME or the default folder',
                value: _draft.androidSdk ?? '',
                onChanged: (value) => _set(_draft.copyWith(androidSdk: value)),
                onBrowse: () async {
                  if (await _folder() case final folder?) {
                    _set(_draft.copyWith(androidSdk: folder), check: true);
                  }
                },
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: buildTools,
                decoration: const InputDecoration(labelText: 'build-tools'),
                items: [
                  DropdownMenuItem(
                    value: '',
                    child: Text(
                      available.isEmpty
                          ? 'The newest in the Android SDK'
                          : 'The newest (${available.last})',
                    ),
                  ),
                  for (final version in available.reversed)
                    DropdownMenuItem(value: version, child: Text(version)),
                  if (buildTools.isNotEmpty && !available.contains(buildTools))
                    DropdownMenuItem(
                      value: buildTools,
                      child: Text('$buildTools (not installed)'),
                    ),
                ],
                onChanged: (value) => _set(
                  _draft.copyWith(buildToolsVersion: value ?? ''),
                  check: true,
                ),
              ),
              const SizedBox(height: 10),
              PathField(
                label: 'JDK folder (keytool, jarsigner, java)',
                hint: 'Detected from JAVA_HOME, PATH or Android Studio',
                value: _draft.jdkHome ?? '',
                onChanged: (value) => _set(_draft.copyWith(jdkHome: value)),
                onBrowse: () async {
                  if (await _folder() case final folder?) {
                    _set(_draft.copyWith(jdkHome: folder), check: true);
                  }
                },
              ),
              const SizedBox(height: 10),
              PathField(
                label: 'bundletool (for App Bundles)',
                hint:
                    'The bundletool jar, or the command. Detected on PATH '
                    'or in Homebrew',
                value: _draft.bundletool ?? '',
                onChanged: (value) => _set(_draft.copyWith(bundletool: value)),
                onBrowse: () async {
                  final file = await openFile(
                    acceptedTypeGroups: const [
                      XTypeGroup(label: 'bundletool jar', extensions: ['jar']),
                      XTypeGroup(label: 'All files'),
                    ],
                  );
                  if (file != null) {
                    _set(_draft.copyWith(bundletool: file.path), check: true);
                  }
                },
              ),
              if (_draft.cleaned() != _checked) ...[
                const SizedBox(height: 8),
                Text(
                  'Detect again checks what you typed. Save keeps it.',
                  style: TextStyle(fontSize: 12, color: context.status.muted),
                ),
              ],
              if (preview.isLoading) ...[
                const SizedBox(height: 10),
                const LinearProgressIndicator(minHeight: 2),
              ],
              if (toolchain != null && toolchain.problems.isNotEmpty) ...[
                const SizedBox(height: 12),
                ProblemText(toolchain.problems),
              ],
              const SizedBox(height: 16),
              if (toolchain != null) _ToolTable(toolchain: toolchain),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _detectAgain, child: const Text('Detect again')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: () {
            ref.read(toolOverridesProvider.notifier).set(_draft);
            Navigator.of(context).pop();
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ToolTable extends StatelessWidget {
  const _ToolTable({required this.toolchain});

  final Toolchain toolchain;

  @override
  Widget build(BuildContext context) {
    final rows = {
      'flutter': toolchain.flutter,
      'Android SDK': toolchain.androidSdk,
      'apksigner': toolchain.apksigner,
      'zipalign': toolchain.zipalign,
      'aapt2': toolchain.aapt2,
      'adb': toolchain.adb,
      'keytool': toolchain.keytool,
      'jarsigner': toolchain.jarsigner,
      ['java', ?toolchain.javaVersion].join(' '): toolchain.java,
      ['bundletool', ?toolchain.bundletoolVersion].join(' '):
          toolchain.bundletool,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final MapEntry(key: name, value: path) in rows.entries)
          InfoRow(
            name,
            path ?? 'not found',
            mono: path != null,
            trailing: Icon(
              path == null ? Icons.close_rounded : Icons.check_rounded,
              size: 16,
              color: path == null ? context.status.error : context.status.ok,
            ),
          ),
      ],
    );
  }
}
