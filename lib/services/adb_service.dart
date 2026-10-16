import '../core/process/command.dart';
import '../domain/devices/device_info.dart';
import '../domain/devices/devices.dart';
import '../domain/failure.dart';
import 'tool_executor.dart';

class AdbService {
  const AdbService();

  /// The connected devices, with the ABIs of the ready ones.
  Future<List<AndroidDevice>> devices(
    ToolExecutor executor, {
    required String adb,
  }) async {
    final result = await executor.run(
      Command(adb, const ['devices', '-l']),
      echoOutput: false,
    );
    if (!result.succeeded) {
      throw ToolFailure.fromResult('adb could not list the devices', result);
    }
    final devices = parseAdbDevices(result.stdout);
    return [
      for (final device in devices)
        device.isReady
            ? device.withAbis(await _abis(executor, adb, device.serial))
            : device,
    ];
  }

  Future<List<String>> _abis(
    ToolExecutor executor,
    String adb,
    String serial,
  ) async {
    final result = await executor.run(
      Command(adb, [
        '-s',
        serial,
        'shell',
        'getprop',
        'ro.product.cpu.abilist',
      ]),
      echoOutput: false,
    );
    return result.succeeded ? parseAbiList(result.stdout.join(',')) : const [];
  }

  Future<void> install(
    ToolExecutor executor, {
    required String adb,
    required String serial,
    required String apk,
    required bool allowDowngrade,
  }) async {
    final result = await executor.run(
      Command(
        adb,
        adbInstallArguments(serial, apk, allowDowngrade: allowDowngrade),
      ),
    );
    final failure = parseInstallFailure(result.allLines);
    if (failure != null) {
      throw ToolFailure(
        'Install failed: ${failure.code}',
        details: [?failure.hint, ...errorDetails(result)],
      );
    }
    if (!result.succeeded ||
        !result.allLines.any((line) => line.trim() == 'Success')) {
      throw ToolFailure.fromResult('Install failed', result);
    }
  }

  /// Everything the Device panel shows, in one `adb shell` call.
  Future<DeviceInfo> deviceInfo(
    ToolExecutor executor, {
    required String adb,
    required String serial,
  }) async {
    final result = await executor.run(
      Command(adb, ['-s', serial, 'shell', deviceInfoScript()]),
      echoOutput: false,
    );
    final info = parseDeviceInfo(serial, result.stdout);
    if (info.properties.isEmpty) {
      throw ToolFailure.fromResult('Could not read the device', result);
    }
    return info;
  }

  /// [package]'s installed version, or `null` when it isn't installed.
  Future<InstalledPackage?> installedPackage(
    ToolExecutor executor, {
    required String adb,
    required String serial,
    required String package,
  }) async {
    final result = await executor.run(
      Command(adb, ['-s', serial, 'shell', installedPackageScript(package)]),
      echoOutput: false,
    );
    // grep exits 1 when nothing matched: the package isn't installed.
    return parseInstalledPackage(result.stdout);
  }
}
