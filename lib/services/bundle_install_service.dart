import 'dart:io';

import '../core/process/command.dart';
import '../core/system/host.dart';
import '../domain/devices/devices.dart';
import '../domain/failure.dart';
import '../domain/signing/signing.dart';
import '../domain/tools/bundletool.dart';
import '../domain/tools/toolchain.dart';
import 'owner_only_file.dart';
import 'tool_executor.dart';

/// Installs an App Bundle on a device the way a store would deliver it:
/// bundletool makes the APKs for that device from the bundle, signed with
/// the key in Sign, then installs them.
class BundleInstallService {
  const BundleInstallService({required this.host, this.temporaryDirectory});

  final Host host;

  /// Where the passwords' files and the device's APKs are written. The
  /// system's by default.
  final Directory Function()? temporaryDirectory;

  /// bundletool takes a password as an argument or a file only. It goes in
  /// a file its owner alone can read, deleted with the device's APKs when
  /// this ends, failed or cancelled.
  Future<void> install(
    ToolExecutor executor, {
    required Toolchain toolchain,
    required String bundle,
    required String serial,
    required SigningRequest request,
    required bool allowDowngrade,
  }) async {
    final launch = toolchain.bundletoolLaunch;
    if (launch == null) throw bundletoolMissing;
    final adb = toolchain.adb;
    if (adb == null) throw const ToolFailure('adb was not found');

    final temporary = await (temporaryDirectory?.call() ?? Directory.systemTemp)
        .createTemp('apk_forge_install_');
    try {
      final storePassword = host.path.join(temporary.path, 'store.pass');
      await writeOwnerOnly(
        executor,
        host,
        File(storePassword),
        request.storePassword,
      );
      var keyPassword = storePassword;
      if (request.keyPassword case final password?) {
        keyPassword = host.path.join(temporary.path, 'key.pass');
        await writeOwnerOnly(executor, host, File(keyPassword), password);
      }

      final apks = host.path.join(temporary.path, 'device.apks');
      executor.log.info(
        'Making the APKs for this device from '
        '${host.path.basename(bundle)}, signed with key “${request.alias}”',
      );
      final build = await executor.run(
        Command(
          launch.executable,
          bundletoolBuildApksArguments(
            launch.arguments,
            bundle: bundle,
            output: apks,
            serial: serial,
            adb: adb,
            keystore: request.keystorePath,
            alias: request.alias,
            storePasswordFile: storePassword,
            keyPasswordFile: keyPassword,
          ),
          secrets: request.secrets,
        ),
      );
      if (!build.succeeded) {
        final key = build.cancelled
            ? null
            : parseKeyLoadFailure(build.allLines);
        if (key != null) throw ToolFailure(key.problem, details: [key.fix]);
        throw ToolFailure.fromResult(
          'bundletool could not make the APKs',
          build,
          secrets: request.secrets,
        );
      }

      final install = await executor.run(
        Command(
          launch.executable,
          bundletoolInstallApksArguments(
            launch.arguments,
            apks: apks,
            serial: serial,
            adb: adb,
            allowDowngrade: allowDowngrade,
          ),
        ),
      );
      if (!install.succeeded) {
        final failure = install.cancelled
            ? null
            : parseInstallFailure(install.allLines);
        if (failure != null) {
          throw ToolFailure(
            'Install failed: ${failure.code}',
            details: [?failure.hint],
          );
        }
        throw ToolFailure.fromResult('Install failed', install);
      }
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}
