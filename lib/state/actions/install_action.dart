import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/system/host.dart';
import '../../domain/devices/devices.dart';
import '../../domain/failure.dart';
import '../../services/adb_service.dart';
import '../apks.dart';
import '../devices.dart';
import '../forms.dart';
import '../providers.dart';
import '../task_notifier.dart';
import '../toolchain_notifier.dart';

/// Installs the APK selected in Analyze APK on the device selected in
/// Install.
class InstallAction {
  const InstallAction({
    required this.task,
    required this.toolchain,
    required this.apk,
    required this.device,
    required this.options,
    required this.adb,
    required this.host,
    required this.onInstalled,
  });

  final TaskRunner task;
  final ToolchainSource toolchain;
  final String? Function() apk;
  final AndroidDevice? Function() device;
  final InstallOptions Function() options;
  final AdbService adb;
  final Host host;

  /// After a successful install: what was read about the apps on the
  /// device is stale.
  final void Function() onInstalled;

  /// Nothing happens without an APK and a device selected.
  Future<void> run() async {
    final apk = this.apk();
    final device = this.device();
    final options = this.options();
    if (apk == null || device == null) return;

    await task.run('Install on ${device.displayName}', (executor) async {
      final adb = (await toolchain()).adb;
      if (adb == null) throw const ToolFailure('adb was not found');
      await this.adb.install(
        executor,
        adb: adb,
        serial: device.serial,
        apk: apk,
        allowDowngrade: options.allowDowngrade,
      );
      onInstalled();
      executor.log.success(
        'Installed ${host.path.basename(apk)} on ${device.displayName}.',
      );
    });
  }
}

final installActionProvider = Provider(
  (ref) => InstallAction(
    task: ref.watch(taskProvider.notifier),
    toolchain: () => ref.read(toolchainProvider.future),
    apk: () => ref.read(apkListProvider).selectedPath,
    device: () => ref.read(selectedDeviceProvider),
    options: () => ref.read(installOptionsProvider),
    adb: ref.watch(adbServiceProvider),
    host: ref.watch(hostProvider),
    // The installed version, the signer and the comparison are read again
    // on the next look, as after a refresh of the devices.
    onInstalled: () {
      ref.invalidate(installedPackageProvider);
      ref.invalidate(installedApkProvider);
    },
  ),
);
