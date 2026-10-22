import 'package:apk_forge/core/zip/zip_directory.dart';
import 'package:apk_forge/domain/analysis/apk_report.dart';
import 'package:apk_forge/domain/devices/installed_apk.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fakes.dart';

List<ZipEntry> _entries(List<String> names) => [
  for (final name in names)
    ZipEntry(
      name: name,
      compressedSize: 1,
      uncompressedSize: 1,
      isCompressed: false,
    ),
];

void main() {
  group('installed APK', () {
    test('pm path lists the one APK of a single-APK install', () {
      final paths = parsePackagePaths(fixture('adb_pm_path_single.txt'));

      expect(paths, hasLength(1));
      expect(paths.single, startsWith('/data/app/'));
      expect(paths.single, endsWith('/base.apk'));

      final files = InstalledApkFiles.from(paths);
      expect(files.isSplit, isFalse);
      expect(files.abiSplits, isEmpty);
      expect(files.pulledNames, 'base.apk');
    });

    test('an App Bundle install: the base and the ABI split are pulled', () {
      final files = InstalledApkFiles.from(
        parsePackagePaths(fixture('adb_pm_path_bundle.txt')),
      );

      expect(files.isSplit, isTrue);
      expect(files.base, endsWith('/base.apk'));
      expect(files.pulledNames, 'base.apk + split_config.arm64_v8a.apk');
      // A density split is resources only: it stays on the device.
      expect(files.notPulledNames, 'split_config.xhdpi.apk');
    });

    test('nothing listed: not installed', () {
      expect(parsePackagePaths(const []), isEmpty);
      expect(parsePackagePaths(const ['Error: unknown package']), isEmpty);
    });

    test('isAbiSplit: the config splits of an ABI only', () {
      expect(isAbiSplit('/d/split_config.arm64_v8a.apk'), isTrue);
      expect(isAbiSplit('/d/split_config.armeabi_v7a.apk'), isTrue);
      expect(isAbiSplit('/d/split_config.x86_64.apk'), isTrue);
      expect(isAbiSplit('/d/split_config.xhdpi.apk'), isFalse);
      expect(isAbiSplit('/d/split_config.es.apk'), isFalse);
      expect(isAbiSplit('/d/split_feature.apk'), isFalse);
      expect(isAbiSplit('/d/base.apk'), isFalse);
    });

    test('the installed contents take the native code from the splits', () {
      final contents = installedContents(
        _entries(['AndroidManifest.xml', 'classes.dex', 'META-INF/CERT.RSA']),
        [
          _entries([
            'AndroidManifest.xml',
            'lib/arm64-v8a/libapp.so',
            'lib/arm64-v8a/libflutter.so',
          ]),
        ],
      );

      expect(contents.nativeLibraries, {
        'arm64-v8a': ['libapp.so', 'libflutter.so'],
      });
      expect(contents.flutter, FlutterCompilation.aot);
      // The split's own manifest isn't counted again.
      expect(contents.entryCount, 5);
    });

    test('adb arguments, and only a package name reaches the shell', () {
      expect(adbPackagePathArguments('SER1', 'com.example.app'), [
        '-s',
        'SER1',
        'shell',
        'pm',
        'path',
        'com.example.app',
      ]);
      expect(
        () => adbPackagePathArguments('SER1', 'com.x; reboot'),
        throwsArgumentError,
      );
      expect(
        adbPullArguments('SER1', '/data/app/x/base.apk', '/tmp/base.apk'),
        ['-s', 'SER1', 'pull', '/data/app/x/base.apk', '/tmp/base.apk'],
      );
    });
  });
}
