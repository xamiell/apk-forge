import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/apks.dart';
import '../../state/providers.dart';
import '../common/file_types.dart';
import '../common/widgets.dart';
import '../theme.dart';
import 'report_view.dart';

/// The session's APKs in a selector, and the selected one's analysis.
class ApkPanel extends ConsumerWidget {
  const ApkPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(apkListProvider);
    final notifier = ref.read(apkListProvider.notifier);

    return SectionCard(
      title: 'Analyze APK',
      icon: Icons.manage_search_rounded,
      expand: true,
      trailing: FilledButton.tonalIcon(
        onPressed: () async {
          final files = await openFiles(acceptedTypeGroups: const [apkTypes]);
          for (final file in files) {
            notifier.add(file.path, ApkOrigin.opened);
          }
        },
        icon: const Icon(Icons.file_open_outlined, size: 18),
        label: const Text('Open APK…'),
      ),
      child: list.items.isEmpty
          ? const _EmptyState()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ApkSelector(list: list),
                const Divider(),
                Expanded(child: ReportView(path: list.selectedPath!)),
              ],
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.android_rounded, size: 48, color: context.status.muted),
        const SizedBox(height: 10),
        const Text('No APKs yet'),
        const SizedBox(height: 4),
        Text(
          'Build one, sign one, or open any APK to read its signature,\n'
          'build type, architectures and hashes.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: context.status.muted),
        ),
      ],
    ),
  );
}

/// A selector rather than a list, so the report keeps the panel's whole
/// width next to the Device panel.
class _ApkSelector extends ConsumerWidget {
  const _ApkSelector({required this.list});

  final ApkList list;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(hostProvider);
    final notifier = ref.read(apkListProvider.notifier);

    Widget item(ApkItem apk) => Row(
      children: [
        Pill(apk.origin.label, color: _originColor(context, apk.origin)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            host.path.basename(apk.path),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: list.selectedPath,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: list.items.length == 1
                    ? 'APK'
                    : 'APK (${list.items.length} this session)',
              ),
              items: [
                for (final apk in list.items)
                  DropdownMenuItem(
                    value: apk.path,
                    child: Tooltip(message: apk.path, child: item(apk)),
                  ),
              ],
              selectedItemBuilder: (_) => [
                for (final apk in list.items) item(apk),
              ],
              onChanged: (path) {
                if (path != null) notifier.select(path);
              },
            ),
          ),
          IconButton(
            tooltip: 'Remove from the list (the file stays)',
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: () => notifier.remove(list.selectedPath!),
          ),
        ],
      ),
    );
  }

  static Color _originColor(BuildContext context, ApkOrigin origin) =>
      switch (origin) {
        ApkOrigin.signed => context.status.ok,
        ApkOrigin.built => context.status.info,
        ApkOrigin.opened => context.status.muted,
      };
}
