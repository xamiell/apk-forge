import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/format.dart';
import '../../domain/devices/device_info.dart';
import '../../domain/devices/devices.dart';
import '../../state/apks.dart';
import '../../state/devices.dart';
import '../../state/forms.dart';
import '../common/widgets.dart';
import '../theme.dart';

/// What the selected device says about itself, and what installing the
/// selected APK on it would do.
class DevicePanel extends ConsumerWidget {
  const DevicePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);
    final device = ref.watch(selectedDeviceProvider);
    final info = device != null && device.isReady
        ? ref.watch(deviceInfoProvider(device.serial)).value
        : null;

    return SectionCard(
      title: 'Analyze device',
      icon: Icons.phone_android_rounded,
      expand: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (info != null)
            IconButton(
              tooltip: 'Copy device info',
              icon: const Icon(Icons.copy_all_rounded, size: 18),
              onPressed: () => Clipboard.setData(
                ClipboardData(text: deviceInfoSummary(info)),
              ),
            ),
          if (devices.loading)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: 'Refresh devices',
              icon: const Icon(Icons.refresh_rounded, size: 20),
              onPressed: () => ref.read(devicesProvider.notifier).refresh(),
            ),
        ],
      ),
      child: _body(context, ref, devices, device),
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    DevicesState devices,
    AndroidDevice? device,
  ) {
    if (devices.error != null) {
      return _Message(devices.error!, color: context.status.error);
    }
    if (devices.devices.isEmpty) {
      return _Message(
        devices.loading ? 'Looking for devices…' : 'No devices. Connect one by USB with USB debugging on, then refresh.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (devices.devices.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: DropdownButtonFormField<String>(
              initialValue: device?.serial,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Device'),
              items: [
                for (final d in devices.devices)
                  DropdownMenuItem(
                    value: d.serial,
                    child: Text(
                      d.isReady
                          ? '${d.displayName} · ${d.serial}'
                          : '${d.serial} (${d.state})',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: ref.read(installOptionsProvider.notifier).select,
            ),
          ),
        Expanded(child: _DeviceDetails(device: device)),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.usb_rounded,
            size: 40,
            color: color ?? context.status.muted,
          ),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              color: color ?? context.status.muted,
            ),
          ),
        ],
      ),
    ),
  );
}

class _DeviceDetails extends ConsumerWidget {
  const _DeviceDetails({required this.device});

  final AndroidDevice? device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final device = this.device;
    if (device == null) return const _Message('Select a device.');
    if (!device.isReady) {
      return _Message(
        device.state == 'unauthorized'
            ? 'Accept the USB debugging prompt on the device, then refresh.'
            : 'The device is ${device.state}.',
        color: context.status.warning,
      );
    }
    return switch (ref.watch(deviceInfoProvider(device.serial))) {
      AsyncData(:final value) => _Info(info: value),
      AsyncError(:final error) => Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                '$error',
                textAlign: TextAlign.center,
                style: monospace.copyWith(color: context.status.error),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: () =>
                    ref.invalidate(deviceInfoProvider(device.serial)),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

class _Info extends StatelessWidget {
  const _Info({required this.info});

  final DeviceInfo info;

  @override
  Widget build(BuildContext context) {
    final colors = context.status;
    final battery = info.battery;
    final buildType = [info.buildType, info.buildTags].nonNulls.join(' · ');

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(info.displayName, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 2),
          SelectableText(info.serial, style: TextStyle(color: colors.muted)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Pill(
                'Android ${info.androidVersion ?? '?'} · API ${info.sdk ?? '?'}',
                color: colors.info,
                icon: Icons.android_rounded,
              ),
              if (info.abis.isNotEmpty)
                Pill(info.abis.first, color: colors.info),
              if (info.pageSize == 16384)
                Pill(
                  '16 KB pages',
                  color: colors.warning,
                  icon: Icons.memory_rounded,
                ),
              if (info.isEmulator) Pill('Emulator', color: colors.muted),
              if (info.buildType != null && info.buildType != 'user')
                Pill(info.buildType!, color: colors.warning),
            ],
          ),
          const SizedBox(height: 16),
          const _SelectedApkOnDevice(),
          _Section(
            title: 'System',
            children: [
              InfoRow(
                'Android',
                '${info.androidVersion ?? '?'} (API ${info.sdk ?? '?'})',
              ),
              if (info.securityPatch != null)
                InfoRow('Security patch', info.securityPatch!),
              if (info.buildId != null) InfoRow('Build', info.buildId!),
              if (buildType.isNotEmpty) InfoRow('Build type', buildType),
              if (info.fingerprint != null)
                InfoRow(
                  'Fingerprint',
                  info.fingerprint!,
                  mono: true,
                  trailing: CopyButton(info.fingerprint!),
                ),
              if (info.kernel != null)
                InfoRow('Kernel', info.kernel!, mono: true),
              InfoRow(
                'Debuggable',
                info.isDebuggable ? 'Yes (ro.debuggable=1)' : 'No',
              ),
            ],
          ),
          _Section(
            title: 'Hardware',
            children: [
              if (info.manufacturer != null)
                InfoRow('Manufacturer', info.manufacturer!),
              if (info.brand != null) InfoRow('Brand', info.brand!),
              if (info.model != null) InfoRow('Model', info.model!),
              if (info.device != null) InfoRow('Codename', info.device!),
              if (info.soc != null) InfoRow('Chip', info.soc!),
              if (info.abis.isNotEmpty) InfoRow('ABIs', info.abis.join(', ')),
              if (info.pageSize != null)
                InfoRow('Page size', formatBytes(info.pageSize!)),
              if (info.memoryKb != null)
                InfoRow('RAM', formatBytes(info.memoryKb! * 1024)),
              if (info.dataTotalKb != null && info.dataFreeKb != null)
                InfoRow(
                  'Storage',
                  '${formatBytes(info.dataFreeKb! * 1024)} free of '
                      '${formatBytes(info.dataTotalKb! * 1024)}',
                ),
              if (info.screenSize != null)
                InfoRow(
                  'Screen',
                  [
                    info.screenSize!,
                    if (info.density != null) '${info.density} dpi',
                    if (info.screenSizeOverride != null)
                      'shown at ${info.screenSizeOverride}',
                    if (info.densityOverride != null)
                      '${info.densityOverride} dpi',
                  ].join(' · '),
                ),
            ],
          ),
          _Section(
            title: 'Status',
            children: [
              if (battery != null)
                InfoRow(
                  'Battery',
                  [
                    if (battery.level != null) '${battery.level}%',
                    battery.status.label,
                    if (battery.temperatureC != null)
                      '${battery.temperatureC!.toStringAsFixed(1)} °C',
                  ].join(' · '),
                ),
              if (info.locale != null) InfoRow('Locale', info.locale!),
              if (info.timeZone != null) InfoRow('Time zone', info.timeZone!),
            ],
          ),
        ],
      ),
    );
  }
}

/// The APK selected on the left, against this device: which ABI it would
/// run, and whether installing it is an upgrade, a reinstall or a downgrade.
class _SelectedApkOnDevice extends ConsumerWidget {
  const _SelectedApkOnDevice();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.status;
    final path = ref.watch(apkListProvider.select((list) => list.selectedPath));
    final device = ref.watch(selectedDeviceProvider);
    if (path == null || device == null) return const SizedBox.shrink();
    final report = ref.watch(apkReportProvider(path)).value;
    final info = ref.watch(deviceInfoProvider(device.serial)).value;
    final badging = report?.badging;
    if (report == null || info == null || badging?.packageName == null) {
      return const SizedBox.shrink();
    }

    final package = badging!.packageName!;
    final apkAbis = report.contents.nativeLibraries.keys.toList();
    final abi = preferredAbi(apkAbis, info.abis);
    final installed = isValidPackageName(package)
        ? ref.watch(
            installedPackageProvider((serial: device.serial, package: package)),
          )
        : null;
    final apkCode = int.tryParse(badging.versionCode ?? '');

    final rows = <Widget>[
      InfoRow('Package', package, mono: true),
      InfoRow(
        'Runs as',
        apkAbis.isEmpty
            ? 'No native code: runs on any ABI'
            : abi ?? 'Nothing: the APK has ${apkAbis.join(', ')} only',
      ),
      switch (installed) {
        AsyncData(:final value) => InfoRow(
          'Installed',
          value == null
              ? 'No'
              : '${value.versionName ?? '?'} (${value.versionCode})'
                    '${value.lastUpdate == null ? '' : ' · ${value.lastUpdate}'}',
        ),
        AsyncError(:final error) => InfoRow('Installed', '$error'),
        _ => const InfoRow('Installed', 'Checking…'),
      },
    ];

    final outcome = switch (installed) {
      AsyncData(:final value) when apkCode != null => installOutcome(
        value,
        apkCode,
      ),
      _ => null,
    };
    final apkRuns = apkAbis.isEmpty || abi != null;
    final color = !apkRuns || outcome == InstallOutcome.downgrade
        ? colors.warning
        : colors.ok;

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'SELECTED APK ON THIS DEVICE',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
              color: colors.muted,
            ),
          ),
          const SizedBox(height: 6),
          ...rows,
          if (outcome != null || !apkRuns)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                !apkRuns
                    ? 'It won\'t install: no native code for this device.'
                    : 'Installing ${badging.versionName ?? ''} ($apkCode): '
                          '${outcome!.description}',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
              color: context.status.muted,
            ),
          ),
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );
  }
}
