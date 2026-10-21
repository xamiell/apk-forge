import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/tools/toolchain.dart';
import '../../state/toolchain_notifier.dart';
import '../common/widgets.dart';
import '../theme.dart';

/// The tools the app found, in the top bar. A missing one is red, and the
/// gear opens the folders to set by hand.
class ToolchainBar extends ConsumerWidget {
  const ToolchainBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final toolchain = ref.watch(toolchainProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        switch (toolchain) {
          AsyncData(:final value) => Wrap(
            spacing: 6,
            children: [
              _ToolPill(
                'Flutter',
                value.flutter,
                version: value.flutterVersion,
              ),
              _ToolPill(
                'build-tools',
                value.apksigner,
                version: value.buildToolsVersion,
              ),
              _ToolPill('adb', value.adb),
              _ToolPill('keytool', value.keytool),
            ],
          ),
          AsyncError(:final error) => Text(
            '$error',
            style: TextStyle(color: context.status.error),
          ),
          _ => const Row(
            children: [
              SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 8),
              Text('Looking for tools…', style: TextStyle(fontSize: 12.5)),
            ],
          ),
        },
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Tools',
          icon: const Icon(Icons.settings_outlined, size: 20),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const ToolsDialog(),
          ),
        ),
      ],
    );
  }
}

class _ToolPill extends StatelessWidget {
  const _ToolPill(this.name, this.path, {this.version});

  final String name;
  final String? path;
  final String? version;

  @override
  Widget build(BuildContext context) {
    final found = path != null;
    return Tooltip(
      message: path ?? '$name not found',
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
  late String _flutterSdk = ref.read(toolOverridesProvider).flutterSdk ?? '';
  late String _androidSdk = ref.read(toolOverridesProvider).androidSdk ?? '';

  @override
  Widget build(BuildContext context) {
    final toolchain = ref.watch(toolchainProvider).value;

    return AlertDialog(
      title: const Text('Tools'),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Found from your shell\'s PATH, ANDROID_HOME and the usual install folders. '
              'Set a folder only if a tool is missing or you want another version.',
              style: TextStyle(fontSize: 12.5, color: context.status.muted),
            ),
            const SizedBox(height: 14),
            PathField(
              label: 'Flutter SDK folder',
              hint: 'Detected from PATH',
              value: _flutterSdk,
              onChanged: (value) => setState(() => _flutterSdk = value),
              onBrowse: () async {
                final folder = await getDirectoryPath(
                  confirmButtonText: 'Choose',
                );
                if (folder != null) setState(() => _flutterSdk = folder);
              },
            ),
            const SizedBox(height: 10),
            PathField(
              label: 'Android SDK folder',
              hint: 'Detected from ANDROID_HOME or the default folder',
              value: _androidSdk,
              onChanged: (value) => setState(() => _androidSdk = value),
              onBrowse: () async {
                final folder = await getDirectoryPath(
                  confirmButtonText: 'Choose',
                );
                if (folder != null) setState(() => _androidSdk = folder);
              },
            ),
            const SizedBox(height: 16),
            if (toolchain != null) _ToolTable(toolchain: toolchain),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => ref.read(toolchainProvider.notifier).refresh(),
          child: const Text('Detect again'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: () {
            ref
                .read(toolOverridesProvider.notifier)
                .set(flutterSdk: _flutterSdk, androidSdk: _androidSdk);
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
