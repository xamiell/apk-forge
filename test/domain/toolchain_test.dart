import 'package:apk_forge/core/system/host.dart';
import 'package:apk_forge/domain/tools/toolchain.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fakes.dart';

void main() {
  const sdk = '/Users/dev/Library/Android/sdk';

  FakeFileProbe macSdk({
    List<String> buildTools = const ['34.0.0', '36.0.0'],
  }) => FakeFileProbe(
    directories: {
      sdk,
      '$sdk/build-tools',
      for (final version in buildTools) '$sdk/build-tools/$version',
    },
    files: {
      for (final version in buildTools) ...{
        '$sdk/build-tools/$version/apksigner',
        '$sdk/build-tools/$version/zipalign',
        '$sdk/build-tools/$version/aapt2',
      },
      '$sdk/platform-tools/adb',
      '/usr/bin/keytool',
      '/opt/flutter/bin/flutter',
    },
  );

  test('finds the default macOS SDK and the newest build-tools', () {
    const host = Host(
      os: HostOs.macos,
      environment: {'HOME': '/Users/dev', 'PATH': '/usr/bin:/opt/flutter/bin'},
    );
    final toolchain = ToolchainLocator(
      host: host,
      probe: macSdk(),
    ).locate(const ToolOverrides());

    expect(toolchain.androidSdk, sdk);
    expect(toolchain.buildToolsVersion, '36.0.0');
    expect(toolchain.apksigner, '$sdk/build-tools/36.0.0/apksigner');
    expect(toolchain.adb, '$sdk/platform-tools/adb');
    expect(toolchain.keytool, '/usr/bin/keytool');
    expect(toolchain.flutter, '/opt/flutter/bin/flutter');
    expect(toolchain.zipalignSupportsPageSize, isTrue);
  });

  test('jarsigner is the one next to keytool, from the same JDK', () {
    const host = Host(
      os: HostOs.macos,
      environment: {'HOME': '/Users/dev', 'PATH': '/usr/bin'},
    );
    final withIt = macSdk()..files.add('/usr/bin/jarsigner');

    expect(
      ToolchainLocator(
        host: host,
        probe: withIt,
      ).locate(const ToolOverrides()).jarsigner,
      '/usr/bin/jarsigner',
    );
    expect(
      ToolchainLocator(
        host: host,
        probe: macSdk(),
      ).locate(const ToolOverrides()).jarsigner,
      isNull,
    );
  });

  test('ANDROID_HOME and the overrides win over the default folder', () {
    final probe = macSdk()
      ..directories.addAll({'/custom/sdk', '/override/sdk'});
    const host = Host(
      os: HostOs.macos,
      environment: {'HOME': '/Users/dev', 'ANDROID_HOME': '/custom/sdk'},
    );
    final locator = ToolchainLocator(host: host, probe: probe);

    expect(locator.locate(const ToolOverrides()).androidSdk, '/custom/sdk');
    expect(
      locator
          .locate(const ToolOverrides(androidSdk: '/override/sdk'))
          .androidSdk,
      '/override/sdk',
    );
  });

  test('a Flutter SDK override is used over PATH', () {
    final probe = macSdk()..files.add('/fvm/3.47.5/bin/flutter');
    const host = Host(
      os: HostOs.macos,
      environment: {'HOME': '/Users/dev', 'PATH': '/opt/flutter/bin'},
    );

    expect(
      ToolchainLocator(
        host: host,
        probe: probe,
      ).locate(const ToolOverrides(flutterSdk: '/fvm/3.47.5')).flutter,
      '/fvm/3.47.5/bin/flutter',
    );
  });

  test('build-tools before 35 have no 16 KB page alignment', () {
    const host = Host(os: HostOs.macos, environment: {'HOME': '/Users/dev'});
    final toolchain = ToolchainLocator(
      host: host,
      probe: macSdk(buildTools: ['34.0.0']),
    ).locate(const ToolOverrides());

    expect(toolchain.buildToolsVersion, '34.0.0');
    expect(toolchain.zipalignSupportsPageSize, isFalse);
  });

  test('uses Windows names and folders', () {
    const local = r'C:\Users\dev\AppData\Local';
    const windowsSdk = '$local\\Android\\Sdk';
    final probe = FakeFileProbe(
      directories: {
        windowsSdk,
        '$windowsSdk\\build-tools',
        '$windowsSdk\\build-tools\\36.0.0',
      },
      files: {
        '$windowsSdk\\build-tools\\36.0.0\\apksigner.bat',
        '$windowsSdk\\build-tools\\36.0.0\\zipalign.exe',
        '$windowsSdk\\platform-tools\\adb.exe',
        r'C:\flutter\bin\flutter.bat',
      },
    );
    const host = Host(
      os: HostOs.windows,
      environment: {
        'USERPROFILE': r'C:\Users\dev',
        'LOCALAPPDATA': local,
        'Path': r'C:\Windows;C:\flutter\bin',
      },
    );
    final toolchain = ToolchainLocator(
      host: host,
      probe: probe,
    ).locate(const ToolOverrides());

    expect(toolchain.androidSdk, windowsSdk);
    expect(
      toolchain.apksigner,
      '$windowsSdk\\build-tools\\36.0.0\\apksigner.bat',
    );
    expect(
      toolchain.zipalign,
      '$windowsSdk\\build-tools\\36.0.0\\zipalign.exe',
    );
    expect(toolchain.adb, '$windowsSdk\\platform-tools\\adb.exe');
    expect(toolchain.flutter, r'C:\flutter\bin\flutter.bat');
  });

  test('nothing installed: every tool is null', () {
    const host = Host(
      os: HostOs.linux,
      environment: {'HOME': '/home/dev', 'PATH': '/usr/bin'},
    );
    final toolchain = ToolchainLocator(
      host: host,
      probe: FakeFileProbe(),
    ).locate(const ToolOverrides());

    expect(toolchain.androidSdk, isNull);
    expect(
      toolchain.canBuild ||
          toolchain.canSign ||
          toolchain.canInstall ||
          toolchain.canReadKeystore,
      isFalse,
    );
  });

  test(
    'compareVersions orders by number, a pre-release before its release',
    () {
      final versions = ['36.0.0', '35.0.0-rc1', '9.0.0', '35.0.0', '35.0.1']
        ..sort(compareVersions);

      expect(versions, ['9.0.0', '35.0.0-rc1', '35.0.0', '35.0.1', '36.0.0']);
    },
  );
}
