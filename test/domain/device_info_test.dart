import 'package:apk_forge/domain/devices/device_info.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fakes.dart';

void main() {
  group('parseDeviceInfo', () {
    final info = parseDeviceInfo(
      'emulator-5554',
      fixture('adb_device_info_emulator.txt'),
    );

    test('reads the system properties', () {
      expect(info.properties, hasLength(greaterThan(400)));
      expect(info.manufacturer, 'Google');
      expect(info.brand, 'google');
      expect(info.model, 'sdk_gphone64_arm64');
      expect(info.device, 'emu64a');
      expect(info.androidVersion, '13');
      expect(info.sdk, 33);
      expect(info.securityPatch, '2024-03-01');
      expect(info.buildType, 'user');
      expect(info.buildTags, 'release-keys');
      expect(info.abis, ['arm64-v8a']);
      expect(info.isDebuggable, isFalse);
      expect(info.isEmulator, isTrue);
      expect(info.locale, 'en-US');
      expect(info.timeZone, 'Etc/UTC');
    });

    test('takes the chip from ro.soc.* and skips an empty board', () {
      expect(info.soc, 'AOSP ranchu');
    });

    test('reads the commands after the properties', () {
      expect(info.screenSize, '1080x2400');
      expect(info.screenSizeOverride, isNull);
      expect(info.density, 420);
      expect(info.pageSize, 4096);
      expect(info.memoryKb, 2012184);
      expect(info.dataTotalKb, 6082144);
      expect(info.dataFreeKb, 3631372);
      expect(info.kernel, startsWith('5.15.119-android13'));
      expect(info.battery!.level, 100);
      expect(info.battery!.status, BatteryStatus.charging);
      expect(info.battery!.temperatureC, 25.0);
    });

    test('the display name joins maker and model once', () {
      expect(info.displayName, 'Google sdk_gphone64_arm64');
      expect(
        const DeviceInfo(
          serial: 's',
          properties: {
            'ro.product.manufacturer': 'samsung',
            'ro.product.model': 'SAMSUNG SM-A515F',
          },
        ).displayName,
        'SAMSUNG SM-A515F',
      );
    });

    test('reads overrides, a 16 KB page and a df row split in two', () {
      final custom = parseDeviceInfo('s', [
        '__APK_FORGE__:props',
        '[ro.product.model]: [Tablet]',
        '__APK_FORGE__:wm_size',
        'Physical size: 1200x1920',
        'Override size: 800x1280',
        '__APK_FORGE__:wm_density',
        'Physical density: 240',
        'Override density: 160',
        '__APK_FORGE__:page_size',
        '16384',
        '__APK_FORGE__:df',
        'Filesystem            1K-blocks    Used Available Use% Mounted on',
        '/dev/block/bootdevice/by-name/userdata',
        '                       52357080 8471708  43754300  17% /data',
      ]);

      expect(custom.screenSize, '1200x1920');
      expect(custom.screenSizeOverride, '800x1280');
      expect(custom.densityOverride, 160);
      expect(custom.pageSize, 16384);
      expect(custom.dataTotalKb, 52357080);
      expect(custom.dataFreeKb, 43754300);
    });

    test('a command the device lacks leaves its value empty', () {
      final bare = parseDeviceInfo('s', [
        '__APK_FORGE__:props',
        '[ro.product.model]: [Old]',
        '__APK_FORGE__:page_size',
        '__APK_FORGE__:battery',
      ]);

      expect(bare.model, 'Old');
      expect(bare.pageSize, isNull);
      expect(bare.battery, isNull);
      expect(bare.abis, isEmpty);
    });

    test('the summary lists what is known, one per line', () {
      final summary = deviceInfoSummary(info);

      expect(summary.split('\n').first, 'Device: Google sdk_gphone64_arm64');
      expect(summary, contains('Android: 13 (API 33)'));
      expect(summary, contains('ABIs: arm64-v8a'));
      expect(summary, isNot(contains('null')));
    });
  });

  group('the APK on the device', () {
    test('installOutcome compares versionCodes', () {
      const installed = InstalledPackage(versionCode: 20);

      expect(installOutcome(null, 1), InstallOutcome.fresh);
      expect(installOutcome(installed, 21), InstallOutcome.upgrade);
      expect(installOutcome(installed, 20), InstallOutcome.reinstall);
      expect(installOutcome(installed, 2), InstallOutcome.downgrade);
    });

    test('preferredAbi follows the device\'s order', () {
      expect(
        preferredAbi(
          ['armeabi-v7a', 'arm64-v8a'],
          ['arm64-v8a', 'armeabi-v7a'],
        ),
        'arm64-v8a',
      );
      expect(
        preferredAbi(['armeabi-v7a'], ['arm64-v8a', 'armeabi-v7a']),
        'armeabi-v7a',
      );
      expect(preferredAbi(['x86_64'], ['arm64-v8a']), isNull);
    });

    test('only a package name reaches the device shell', () {
      expect(isValidPackageName('com.on7labs.bancas'), isTrue);
      expect(isValidPackageName('io.example.sample_app'), isTrue);
      expect(isValidPackageName('single'), isFalse);
      expect(isValidPackageName('com.x; reboot'), isFalse);
      expect(isValidPackageName(r'com.x$(id)'), isFalse);
      expect(() => installedPackageScript('a; reboot'), throwsArgumentError);
      expect(
        installedPackageScript('com.example.app'),
        "dumpsys package com.example.app | grep -E 'versionCode=|versionName=|lastUpdateTime='",
      );
    });

    test('reads the installed version of a package', () {
      final installed = parseInstalledPackage(
        fixture('adb_installed_package_settings.txt'),
      );

      expect(installed!.versionCode, 34);
      expect(installed.versionName, '14');
      expect(installed.lastUpdate, '2008-12-31 20:00:00');
    });

    test('a 32-bit-only device runs no 64-bit-only APK', () {
      // Seen on a Dspread D30: a 64-bit chip with 32-bit firmware.
      expect(preferredAbi(['arm64-v8a'], ['armeabi-v7a', 'armeabi']), isNull);
      expect(
        preferredAbi(['arm64-v8a', 'armeabi-v7a'], ['armeabi-v7a', 'armeabi']),
        'armeabi-v7a',
      );
    });

    test('nothing found means not installed', () {
      expect(parseInstalledPackage(const []), isNull);
    });
  });
}
