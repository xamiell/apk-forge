import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/system/host.dart';
import '../../domain/devices/devices.dart';
import '../../domain/failure.dart';
import '../../domain/tools/toolchain.dart';
import '../../domain/signing/signing.dart';
import '../../services/adb_service.dart';
import '../../services/bundle_install_service.dart';
import '../apks.dart';
import '../devices.dart';
import '../forms.dart';
import '../providers.dart';
import '../task_notifier.dart';
import '../toolchain_notifier.dart';

/// Installs the APK selected in Analyze APK on the device selected in
/// Install. An App Bundle goes through bundletool, which makes the device's
/// APKs signed with the key in Sign, as a store would.
class InstallAction {
  const InstallAction({
    required this.task,
    required this.toolchain,
    required this.apk,
    required this.device,
    required this.options,
    required this.signing,
    required this.adb,
    required this.bundles,
    required this.host,
    required this.onInstalled,
  });

  final TaskRunner task;
  final ToolchainSource toolchain;
  final String? Function() apk;
  final AndroidDevice? Function() device;
  final InstallOptions Function() options;
  final SigningSetup Function() signing;
  final AdbService adb;
  final BundleInstallService bundles;
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

    final signing = this.signing();
    await task.run('Install on ${device.displayName}', (executor) async {
      final toolchain = await this.toolchain();
      if (isAppBundle(apk)) {
        final problems = bundleInstallProblems(toolchain, signing);
        if (problems.isNotEmpty) {
          throw ToolFailure(
            'The bundle can\'t be installed yet',
            details: problems,
          );
        }
        await bundles.install(
          executor,
          toolchain: toolchain,
          bundle: apk,
          serial: device.serial,
          request: (signing as ReadyToSign).request,
          allowDowngrade: options.allowDowngrade,
        );
      } else {
        final adb = toolchain.adb;
        if (adb == null) throw const ToolFailure('adb was not found');
        await this.adb.install(
          executor,
          adb: adb,
          serial: device.serial,
          apk: apk,
          allowDowngrade: options.allowDowngrade,
        );
      }
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
    signing: () => ref.read(signingSetupProvider),
    adb: ref.watch(adbServiceProvider),
    bundles: ref.watch(bundleInstallServiceProvider),
    host: ref.watch(hostProvider),
    // The installed version, the signer and the comparison are read again
    // on the next look, as after a refresh of the devices.
    onInstalled: () {
      ref.invalidate(installedPackageProvider);
      ref.invalidate(installedApkProvider);
    },
  ),
);

/// What an App Bundle needs before it can be installed: bundletool, to make
/// the device's APKs, and the key in Sign, to sign them. Empty when ready.
List<String> bundleInstallProblems(
  Toolchain? toolchain,
  SigningSetup signing,
) => [
  if (toolchain != null && toolchain.bundletoolLaunch == null)
    'Set bundletool in Tools: it makes the device\'s APKs from the bundle.',
  if (signing case NotReadyToSign(:final problem))
    'The device\'s APKs are signed with the key in Sign: $problem',
];

/// [bundleInstallProblems] for the tools found and the key in Sign now.
final bundleInstallProblemsProvider = Provider<List<String>>(
  (ref) => bundleInstallProblems(
    ref.watch(toolchainProvider).value,
    ref.watch(signingSetupProvider),
  ),
);
