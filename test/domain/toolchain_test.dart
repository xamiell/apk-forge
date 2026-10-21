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
      ..directories.addAll({
        '/custom/sdk',
        '/custom/sdk/build-tools',
        '/override/sdk',
        '/override/sdk/platform-tools',
      });
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

  group('what Tools sets', () {
    const host = Host(
      os: HostOs.macos,
      environment: {'HOME': '/Users/dev', 'PATH': '/usr/bin:/opt/flutter/bin'},
    );
    Toolchain locate(ToolOverrides overrides, {FakeFileProbe? probe}) =>
        ToolchainLocator(
          host: host,
          probe: probe ?? macSdk(),
        ).locate(overrides);

    test('a build-tools version, from the ones installed', () {
      final toolchain = locate(
        const ToolOverrides(buildToolsVersion: '34.0.0'),
      );

      expect(toolchain.availableBuildTools, ['34.0.0', '36.0.0']);
      expect(toolchain.buildToolsVersion, '34.0.0');
      expect(toolchain.apksigner, '$sdk/build-tools/34.0.0/apksigner');
      expect(toolchain.problems, isEmpty);
    });

    test('a build-tools version that is gone says so, and uses no other', () {
      final toolchain = locate(
        const ToolOverrides(buildToolsVersion: '33.0.0'),
      );

      expect(toolchain.apksigner, isNull);
      expect(toolchain.problems, [
        'build-tools 33.0.0 is not in the Android SDK.',
      ]);
    });

    test('a JDK folder: keytool, jarsigner and java from its bin', () {
      final probe = macSdk()
        ..files.addAll({
          '/jdk/21/bin/keytool',
          '/jdk/21/bin/jarsigner',
          '/jdk/21/bin/java',
        });

      final toolchain = locate(
        const ToolOverrides(jdkHome: '/jdk/21'),
        probe: probe,
      );

      expect(toolchain.keytool, '/jdk/21/bin/keytool');
      expect(toolchain.jarsigner, '/jdk/21/bin/jarsigner');
      expect(toolchain.java, '/jdk/21/bin/java');
    });

    test('a JDK folder without keytool says so, and uses no other', () {
      final toolchain = locate(const ToolOverrides(jdkHome: '/nowhere'));

      // /usr/bin/keytool is there, but it's not the one asked for.
      expect(toolchain.keytool, isNull);
      expect(toolchain.problems, [
        'The JDK folder /nowhere has no bin/keytool.',
      ]);
    });

    test('an SDK folder that is gone says so, and uses no other', () {
      final toolchain = locate(
        const ToolOverrides(
          androidSdk: '/gone/sdk',
          flutterSdk: '/gone/flutter',
        ),
      );

      expect(toolchain.androidSdk, isNull);
      expect(toolchain.flutter, isNull);
      expect(toolchain.problems, [
        'The Android SDK folder /gone/sdk does not exist.',
        'The Flutter SDK folder /gone/flutter has no bin/flutter.',
      ]);
    });

    test('a bundletool jar runs with the JDK\'s java', () {
      final probe = macSdk()
        ..files.addAll({'/usr/bin/java', '/tools/bundletool-all-1.18.3.jar'});

      final toolchain = locate(
        const ToolOverrides(bundletool: '/tools/bundletool-all-1.18.3.jar'),
        probe: probe,
      );

      expect(toolchain.java, '/usr/bin/java');
      expect(toolchain.bundletool, '/tools/bundletool-all-1.18.3.jar');
      final launch = toolchain.bundletoolLaunch!;
      expect(launch.executable, '/usr/bin/java');
      expect(launch.arguments, ['-jar', '/tools/bundletool-all-1.18.3.jar']);
    });

    test('a bundletool jar without java can\'t run, and says why', () {
      final probe = macSdk()..files.add('/tools/bundletool.jar');

      final toolchain = locate(
        const ToolOverrides(bundletool: '/tools/bundletool.jar'),
        probe: probe,
      );

      expect(toolchain.bundletoolLaunch, isNull);
      expect(toolchain.problems.single, contains('no java was found'));
    });

    test('a bundletool that is gone says so', () {
      final toolchain = locate(const ToolOverrides(bundletool: '/old/bt.jar'));

      expect(toolchain.bundletool, isNull);
      expect(toolchain.problems, ['bundletool /old/bt.jar does not exist.']);
    });

    test('without one set, bundletool is found on PATH, then in Homebrew', () {
      final onPath = macSdk()..files.add('/usr/bin/bundletool');
      final homebrew = macSdk()..files.add('/opt/homebrew/bin/bundletool');

      final launch = locate(
        const ToolOverrides(),
        probe: onPath,
      ).bundletoolLaunch!;
      expect(launch.executable, '/usr/bin/bundletool');
      expect(launch.arguments, isEmpty);
      expect(
        locate(const ToolOverrides(), probe: homebrew).bundletool,
        '/opt/homebrew/bin/bundletool',
      );
      expect(locate(const ToolOverrides()).bundletool, isNull);
    });

    test('a file that gives no version is not bundletool, and says so', () {
      final probe = macSdk()
        ..files.addAll({'/usr/bin/java', '/tools/venv/pyvenv.cfg'});
      final found = locate(
        const ToolOverrides(bundletool: '/tools/venv/pyvenv.cfg'),
        probe: probe,
      );

      // It exists, so it's found; asked its version, it gives none.
      expect(found.bundletool, '/tools/venv/pyvenv.cfg');
      final checked = found.withVersions(
        flutter: '3.47.5',
        java: '21.0.10',
        bundletool: null,
      );

      expect(checked.bundletool, isNull);
      expect(checked.bundletoolLaunch, isNull);
      expect(checked.problems, [
        '/tools/venv/pyvenv.cfg is not bundletool: it gave no version. '
            'Choose the bundletool jar, or the bundletool command.',
      ]);
    });

    test('a bundletool that gives its version is kept', () {
      final probe = macSdk()
        ..files.addAll({'/usr/bin/java', '/tools/bundletool-all-1.18.3.jar'});

      final checked = locate(
        const ToolOverrides(bundletool: '/tools/bundletool-all-1.18.3.jar'),
        probe: probe,
      ).withVersions(flutter: '3.47.5', java: '21.0.10', bundletool: '1.18.3');

      expect(checked.bundletool, '/tools/bundletool-all-1.18.3.jar');
      expect(checked.bundletoolVersion, '1.18.3');
      expect(checked.problems, isEmpty);
    });

    test('a folder that exists but is not an Android SDK says so, and is '
        'not used', () {
      final probe = macSdk()
        ..directories.add('/Users/dev/Desktop')
        ..files.add('/usr/bin/adb');

      final toolchain = locate(
        const ToolOverrides(androidSdk: '/Users/dev/Desktop'),
        probe: probe,
      );

      expect(toolchain.androidSdk, isNull);
      expect(toolchain.apksigner, isNull);
      // adb is on PATH, but the SDK set is the one to take it from.
      expect(toolchain.adb, isNull);
      expect(toolchain.problems, [
        '/Users/dev/Desktop is not an Android SDK: it has no build-tools or '
            'platform-tools folder.',
      ]);
    });

    test('an ANDROID_HOME that is not an Android SDK is skipped', () {
      final probe = macSdk()..directories.add('/wrong/home');

      final toolchain = ToolchainLocator(
        host: const Host(
          os: HostOs.macos,
          environment: {'HOME': '/Users/dev', 'ANDROID_HOME': '/wrong/home'},
        ),
        probe: probe,
      ).locate(const ToolOverrides());

      expect(toolchain.androidSdk, sdk);
    });

    test('a bin/flutter that gives no version is not Flutter, and says so', () {
      final checked = locate(const ToolOverrides())
          .withVersions(flutter: null, java: null);

      expect(checked.flutter, isNull);
      expect(checked.canBuild, isFalse);
      expect(checked.problems, [
        '/opt/flutter/bin/flutter is not Flutter: it gave no version. Choose '
            'the Flutter SDK folder, the one with bin/flutter.',
      ]);
    });

    test('a macOS JDK bundle (.jdk) is a JDK folder', () {
      const bundle = '/Library/Java/JavaVirtualMachines/jdk-18.jdk';
      final probe = macSdk()
        ..files.addAll({
          '$bundle/Contents/Home/bin/keytool',
          '$bundle/Contents/Home/bin/jarsigner',
          '$bundle/Contents/Home/bin/java',
        });

      final toolchain = locate(
        const ToolOverrides(jdkHome: bundle),
        probe: probe,
      );

      expect(toolchain.keytool, '$bundle/Contents/Home/bin/keytool');
      expect(toolchain.jarsigner, '$bundle/Contents/Home/bin/jarsigner');
      expect(toolchain.java, '$bundle/Contents/Home/bin/java');
      expect(toolchain.problems, isEmpty);
    });

    test('a JDK whose java gives no version is not a JDK: its tools, and a '
        'bundletool jar that needs it, are dropped', () {
      final probe = macSdk()
        ..files.addAll({
          '/fake/jdk/bin/keytool',
          '/fake/jdk/bin/jarsigner',
          '/fake/jdk/bin/java',
          '/tools/bundletool.jar',
        });

      final checked = locate(
        const ToolOverrides(
          jdkHome: '/fake/jdk',
          bundletool: '/tools/bundletool.jar',
        ),
        probe: probe,
      ).withVersions(flutter: '3.47.5', java: null, bundletool: null);

      expect(checked.keytool, isNull);
      expect(checked.jarsigner, isNull);
      expect(checked.java, isNull);
      expect(checked.bundletool, isNull);
      expect(checked.problems, [
        '/fake/jdk/bin/java is not a JDK\'s java: it gave no version. Choose a '
            'JDK folder, the one with bin/keytool.',
        'bundletool is a jar, which runs with the JDK\'s java: fix the JDK '
            'folder first.',
      ]);
    });

    test('tools that give their versions are all kept', () {
      final probe = macSdk()
        ..files.addAll({'/usr/bin/java', '/usr/bin/jarsigner'});

      final checked = locate(
        const ToolOverrides(),
        probe: probe,
      ).withVersions(flutter: '3.47.5', java: '21.0.10');

      expect(checked.flutter, '/opt/flutter/bin/flutter');
      expect(checked.keytool, '/usr/bin/keytool');
      expect(checked.java, '/usr/bin/java');
      expect(checked.javaVersion, '21.0.10');
      expect(checked.problems, isEmpty);
    });

    test('what Tools sets is saved and comes back, blanks as not set', () {
      const typed = ToolOverrides(
        flutterSdk: ' ',
        buildToolsVersion: '',
        jdkHome: ' /jdk/21 ',
        bundletool: '/tools/bt.jar',
      );

      final saved = typed.cleaned().toJson();

      expect(saved, {
        'flutterSdk': null,
        'androidSdk': null,
        'buildToolsVersion': null,
        'jdkHome': '/jdk/21',
        'bundletool': '/tools/bt.jar',
      });
      expect(ToolOverrides.fromJson(saved).toJson(), saved);
    });
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
