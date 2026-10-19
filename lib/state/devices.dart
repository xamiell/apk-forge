import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/analysis/comparison.dart';
import '../domain/devices/device_info.dart';
import '../domain/devices/devices.dart';
import '../services/installed_apk_service.dart';
import '../services/tool_executor.dart';
import 'apks.dart';
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
      ref.invalidate(installedApkProvider);

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

/// An app as installed on a device, copied and read once per serial and
/// package until the devices are refreshed; `null` when not installed.
///
/// Like an analysis, it changes nothing, so it runs outside the task lock.
final installedApkProvider =
    FutureProvider.family<InstalledApk?, ({String serial, String package})>((
      ref,
      key,
    ) async {
      final toolchain = await ref.watch(toolchainProvider.future);
      final log = ref.read(logProvider.notifier);
      log.step('Read the installed ${key.package} from ${key.serial}');
      final executor = ToolExecutor(ref.read(processRunnerProvider), log);
      final installed = await ref
          .read(installedApkServiceProvider)
          .read(
            executor,
            toolchain: toolchain,
            serial: key.serial,
            package: key.package,
          );
      log.info(
        installed == null
            ? '${key.package} is not installed.'
            : 'Read ${installed.files.pulledNames}.',
      );
      return installed;
    });

/// [candidate], an APK of the list, compared with the app of its package
/// installed on [serial]; `null` when that app isn't installed.
final installedComparisonProvider =
    FutureProvider.family<
      ApkComparison?,
      ({String serial, String package, String candidate})
    >((ref, key) async {
      final installed = await ref.watch(
        installedApkProvider((serial: key.serial, package: key.package)).future,
      );
      if (installed == null) return null;
      final candidate = await ref.watch(
        apkReportProvider(key.candidate).future,
      );
      return compareApks(installed.report, candidate);
    });

/// Why installing [apk] on [serial] would be refused for its signer: it is
/// signed with another key than the installed app. `null` when that app
/// isn't installed or it would install as an update.
///
/// Reads the installed version first (cheap), and copies the installed app
/// only when there is one.
final installSignerWarningProvider =
    FutureProvider.family<String?, ({String serial, String apk})>((
      ref,
      key,
    ) async {
      final report = await ref.watch(apkReportProvider(key.apk).future);
      final package = report.badging?.packageName;
      if (package == null || !isValidPackageName(package)) return null;
      final app = (serial: key.serial, package: package);
      if (await ref.watch(installedPackageProvider(app).future) == null) {
        return null;
      }
      final installed = await ref.watch(installedApkProvider(app).future);
      if (installed == null) return null;
      return installSignerWarning(installed.report.signature, report.signature);
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
