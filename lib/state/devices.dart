import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/devices/device_info.dart';
import '../domain/devices/devices.dart';
import '../services/tool_executor.dart';
import 'forms.dart';
import 'log_notifier.dart';
import 'providers.dart';
import 'toolchain_notifier.dart';

class DevicesState {
  const DevicesState({
    this.devices = const [],
    this.loading = false,
    this.error,
  });

  final List<AndroidDevice> devices;
  final bool loading;
  final String? error;
}

final devicesProvider = NotifierProvider<DevicesNotifier, DevicesState>(
  DevicesNotifier.new,
);

class DevicesNotifier extends Notifier<DevicesState> {
  @override
  DevicesState build() => const DevicesState();

  /// Lists the devices again. Runs outside the task lock: it takes a
  /// second and changes nothing, so it can run during a build.
  ///
  /// Keeps the selected device when it's still there; otherwise selects the
  /// first ready one, so the Install and Device panels have one to show.
  Future<void> refresh() async {
    if (state.loading) return;
    state = DevicesState(devices: state.devices, loading: true);
    final toolchain = await ref.read(toolchainProvider.future);
    final adb = toolchain.adb;
    if (adb == null) {
      state = const DevicesState(
        error: 'adb was not found (Android SDK platform-tools).',
      );
      return;
    }
    final log = ref.read(logProvider.notifier);
    try {
      final executor = ToolExecutor(ref.read(processRunnerProvider), log);
      final devices = await ref
          .read(adbServiceProvider)
          .devices(executor, adb: adb);
      log.info(
        devices.isEmpty
            ? 'No devices connected.'
            : 'Devices: ${devices.map((d) => '${d.displayName} (${d.state})').join(', ')}',
      );
      state = DevicesState(devices: devices);
      // The device may have changed (another app installed, an update):
      // read it again on the next look.
      ref.invalidate(deviceInfoProvider);
      ref.invalidate(installedPackageProvider);

      final options = ref.read(installOptionsProvider.notifier);
      final selected = ref.read(installOptionsProvider).selectedSerial;
      if (!devices.any((device) => device.serial == selected)) {
        final ready = devices.where((device) => device.isReady);
        options.select(ready.isEmpty ? null : ready.first.serial);
      }
    } on Exception catch (error) {
      log.error('$error');
      state = DevicesState(error: '$error');
    }
  }
}

/// The selected device, when it's listed.
final selectedDeviceProvider = Provider<AndroidDevice?>((ref) {
  final serial = ref.watch(
    installOptionsProvider.select((options) => options.selectedSerial),
  );
  for (final device in ref.watch(devicesProvider).devices) {
    if (device.serial == serial) return device;
  }
  return null;
});

/// What a ready device says about itself, read once per serial until the
/// devices are refreshed.
final deviceInfoProvider = FutureProvider.family<DeviceInfo, String>((
  ref,
  serial,
) async {
  final toolchain = await ref.watch(toolchainProvider.future);
  final adb = toolchain.adb;
  if (adb == null) throw StateError('adb was not found.');
  final log = ref.read(logProvider.notifier);
  log.step('Read device $serial');
  final executor = ToolExecutor(ref.read(processRunnerProvider), log);
  final info = await ref
      .read(adbServiceProvider)
      .deviceInfo(executor, adb: adb, serial: serial);
  log.info(
    'Read. ${info.displayName}, Android ${info.androidVersion ?? '?'} '
    '(API ${info.sdk ?? '?'}), ${info.abis.join(', ')}.',
  );
  return info;
});

/// A package's installed version on a device; `null` when not installed.
final installedPackageProvider =
    FutureProvider.family<InstalledPackage?, ({String serial, String package})>(
      (ref, key) async {
        final toolchain = await ref.watch(toolchainProvider.future);
        final adb = toolchain.adb;
        if (adb == null) throw StateError('adb was not found.');
        final executor = ToolExecutor(
          ref.read(processRunnerProvider),
          ref.read(logProvider.notifier),
        );
        return ref
            .read(adbServiceProvider)
            .installedPackage(
              executor,
              adb: adb,
              serial: key.serial,
              package: key.package,
            );
      },
    );
