import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/devices/device_info.dart';
import '../../state/apks.dart';
import '../../state/devices.dart';
import '../../state/providers.dart';
import '../common/file_types.dart';
import '../common/widgets.dart';
import '../theme.dart';
import 'comparison_view.dart';
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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (list.selectedPath != null) ...[
            _CompareButton(list: list),
            const SizedBox(width: 8),
          ],
          FilledButton.tonalIcon(
            onPressed: () async {
              final files = await openFiles(
                acceptedTypeGroups: const [apkTypes],
              );
              for (final file in files) {
                notifier.add(file.path, ApkOrigin.opened);
              }
            },
            icon: const Icon(Icons.file_open_outlined, size: 18),
            label: const Text('Open APK…'),
          ),
        ],
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

/// Picks the reference to compare the selected APK with: another APK of the
/// list, or a file (a previous release).
class _CompareButton extends ConsumerWidget {
  const _CompareButton({required this.list});

  final ApkList list;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(hostProvider);
    final candidate = list.selectedPath!;
    final others = list.items.where((apk) => apk.path != candidate);
    final device = ref.watch(selectedDeviceProvider);
    final package = ref
        .watch(apkReportProvider(candidate))
        .value
        ?.badging
        ?.packageName;
    final canReadInstalled =
        device != null &&
        device.isReady &&
        package != null &&
        isValidPackageName(package);

    Future<void> compare(String reference) =>
        showApkComparison(context, reference: reference, candidate: candidate);

    return MenuAnchor(
      menuChildren: [
        for (final apk in others)
          MenuItemButton(
            leadingIcon: const Icon(Icons.android_rounded, size: 18),
            onPressed: () => compare(apk.path),
            child: Text(host.path.basename(apk.path)),
          ),
        if (others.isNotEmpty) const Divider(),
        MenuItemButton(
          leadingIcon: const Icon(Icons.phone_android_rounded, size: 18),
          onPressed: canReadInstalled
              ? () => showInstalledComparison(
                  context,
                  serial: device.serial,
                  deviceName: device.displayName,
                  package: package,
                  candidate: candidate,
                )
              : null,
          child: Text(switch (device) {
            null => 'The installed app (no device selected)',
            _ when !device.isReady =>
              'The installed app (${device.displayName} is ${device.state})',
            _ when package == null =>
              'The installed app (the APK has no package name yet)',
            _ => 'The installed app on ${device.displayName}',
          }),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.file_open_outlined, size: 18),
          onPressed: () async {
            final file = await openFile(acceptedTypeGroups: const [apkTypes]);
            if (file == null) return;
            ref
                .read(apkListProvider.notifier)
                .add(file.path, ApkOrigin.opened, select: false);
            if (context.mounted) await compare(file.path);
          },
          child: const Text('Choose a file…'),
        ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: 'Compare ${host.path.basename(candidate)} with another APK',
        child: OutlinedButton.icon(
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
          icon: const Icon(Icons.compare_arrows_rounded, size: 18),
          label: const Text('Compare with…'),
        ),
      ),
    );
  }
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
