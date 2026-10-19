import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/devices/devices.dart';
import '../../state/actions.dart';
import '../../state/apks.dart';
import '../../state/devices.dart';
import '../../state/forms.dart';
import '../../state/providers.dart';
import '../../state/task_notifier.dart';
import '../common/widgets.dart';
import '../theme.dart';

class InstallCard extends ConsumerWidget {
  const InstallCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);
    final options = ref.watch(installOptionsProvider);
    final optionsNotifier = ref.read(installOptionsProvider.notifier);
    final busy = ref.watch(taskProvider.select((task) => task.isRunning));
    final apkPath = ref.watch(
      apkListProvider.select((list) => list.selectedPath),
    );
    final host = ref.watch(hostProvider);

    AndroidDevice? selected;
    for (final device in devices.devices) {
      if (device.serial == options.selectedSerial) selected = device;
    }
    // The APK's ABIs, once its report is read, to warn before installing.
    final apkAbis = apkPath == null
        ? null
        : ref
              .watch(apkReportProvider(apkPath))
              .value
              ?.contents
              .nativeLibraries
              .keys
              .toList();

    final problems = [
      if (apkPath == null) 'Select an APK in the list.',
      if (selected == null) 'Select a device.',
      if (selected != null && !selected.isReady)
        selected.state == 'unauthorized'
            ? 'Accept the USB debugging prompt on the device, then refresh.'
            : 'The device is ${selected.state}.',
    ];
    final abiMismatch =
        selected != null &&
        apkAbis != null &&
        !isAbiCompatible(apkAbis, selected.abis);
    // Another key than the installed app's, once both are read. A failure
    // to read the installed app shows in the log, not here.
    final signerWarning =
        apkPath == null || selected == null || !selected.isReady
        ? null
        : ref
              .watch(
                installSignerWarningProvider((
                  serial: selected.serial,
                  apk: apkPath,
                )),
              )
              .value;

    return SectionCard(
      title: 'Install',
      icon: Icons.install_mobile_rounded,
      trailing: devices.loading
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : IconButton(
              tooltip: 'Refresh devices',
              icon: const Icon(Icons.refresh_rounded, size: 20),
              onPressed: () => ref.read(devicesProvider.notifier).refresh(),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (devices.error != null)
            Text(
              devices.error!,
              style: TextStyle(color: context.status.error, fontSize: 12.5),
            )
          else if (devices.devices.isEmpty)
            Text(
              devices.loading ? 'Looking for devices…' : 'No devices. Connect one by USB with USB debugging on, then refresh.',
              style: TextStyle(fontSize: 12.5, color: context.status.muted),
            )
          else
            RadioGroup<String>(
              groupValue: options.selectedSerial,
              onChanged: optionsNotifier.select,
              child: Column(
                children: [
                  for (final device in devices.devices)
                    RadioListTile<String>(
                      value: device.serial,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(device.displayName),
                      subtitle: Text(
                        [
                          device.serial,
                          if (!device.isReady) device.state,
                          if (device.abis.isNotEmpty) device.abis.join(', '),
                        ].join(' · '),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Allow downgrade (-d)'),
            value: options.allowDowngrade,
            onChanged: (value) =>
                optionsNotifier.setAllowDowngrade(value ?? false),
          ),
          if (apkPath != null) InfoRow('APK', host.path.basename(apkPath)),
          if (abiMismatch)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ProblemText([
                'This APK has native code for ${apkAbis.join(', ')} only; '
                    'the device runs ${selected.abis.join(', ')}.',
              ]),
            ),
          if (signerWarning != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ProblemText([signerWarning]),
            ),
          const SizedBox(height: 8),
          ProblemText(problems),
          const SizedBox(height: 6),
          FilledButton.icon(
            onPressed: problems.isEmpty && !busy
                ? () => ref.read(actionsProvider).install()
                : null,
            icon: const Icon(Icons.download_rounded),
            label: const Text('Install'),
          ),
        ],
      ),
    );
  }
}
