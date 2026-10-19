import 'dart:io';

import 'package:apk_forge/core/process/command.dart';
import 'package:apk_forge/core/process/process_runner.dart';
import 'package:apk_forge/core/zip/zip_directory.dart';
import 'package:apk_forge/domain/build/build_options.dart';
import 'package:apk_forge/domain/devices/device_info.dart';
import 'package:apk_forge/domain/failure.dart';
import 'package:apk_forge/domain/signing/keystore.dart';
import 'package:apk_forge/domain/signing/signing.dart';
import 'package:apk_forge/domain/tools/toolchain.dart';
import 'package:apk_forge/services/adb_service.dart';
import 'package:apk_forge/services/apk_analyzer.dart';
import 'package:apk_forge/services/apk_split_service.dart';
import 'package:apk_forge/services/flutter_build_service.dart';
import 'package:apk_forge/services/signing_service.dart';
import 'package:apk_forge/services/tool_executor.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/fakes.dart';

const _toolchain = Toolchain(
  apksigner: '/bt/apksigner',
  zipalign: '/bt/zipalign',
  aapt2: '/bt/aapt2',
  buildToolsVersion: '36.0.0',
  adb: '/pt/adb',
  keytool: '/jdk/keytool',
);

void main() {
  late FakeProcessRunner runner;
  late RecordingLog log;
  late ToolExecutor executor;
  late Directory temp;

  setUp(() {
    runner = FakeProcessRunner();
    log = RecordingLog();
    executor = ToolExecutor(runner, log);
    temp = Directory.systemTemp.createTempSync('apk_forge_services_');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  group('ApkSigningService', () {
    const request = SigningRequest(
      keystorePath: '/k.jks',
      storePassword: 'hunter2',
      alias: 'forge-test',
    );
    const testKeySha =
        'b34c9445c5e411b045884f499034b5592ab109ec5cd1ca9cb584e54f582dcfa8';

    ApkSigningService service() =>
        ApkSigningService(host: macHost, temporaryDirectory: () => temp);

    test(
      'checks the alignment, signs a copy and verifies the signer',
      () async {
        runner.whenFirstArg(
          'verify',
          ok(fixture('apksigner_verify_test_key.txt')),
        );
        final input = p.join(temp.path, 'app-release.apk');

        final signed = await service().sign(
          executor,
          toolchain: _toolchain,
          input: input,
          request: request,
          expectedSha256: testKeySha,
        );

        expect(signed.path, p.join(temp.path, 'app-release-signed.apk'));
        expect(signed.signer!.sha256, testKeySha);
        expect(
          runner.calls.map((c) => '${c.executable} ${c.arguments.first}'),
          ['/bt/zipalign -c', '/bt/apksigner sign', '/bt/apksigner verify'],
        );
        final sign = runner.callsWithFirstArg('sign').single;
        expect(sign.environment[keystorePasswordVariable], 'hunter2');
        expect(sign.arguments.last, input);
        expect(log.lines.join('\n'), isNot(contains('hunter2')));
        expect(
          log.lines.last,
          startsWith('success: Signed and verified: app-release-signed.apk'),
        );
      },
    );

    test('aligns into a temporary copy first when the check fails, and cleans it up', () async {
      runner
        ..when(
          (c) => c.arguments.first == '-c',
          (_) => failed(1, stdout: ['Verification FAILED']),
        )
        ..whenFirstArg('verify', ok(fixture('apksigner_verify_test_key.txt')));
      final input = p.join(temp.path, 'edited.apk');

      await service().sign(
        executor,
        toolchain: _toolchain,
        input: input,
        request: request,
      );

      final align = runner.calls.firstWhere((c) => c.arguments.first == '-f');
      expect(align.arguments, ['-f', '-P', '16', '4', input, isNot(input)]);
      final aligned = align.arguments.last;
      expect(runner.callsWithFirstArg('sign').single.arguments.last, aligned);
      expect(File(aligned).parent.existsSync(), isFalse);
    });

    test('a wrong password fails with apksigner\'s reason, masked', () async {
      runner.whenFirstArg(
        'sign',
        failed(
          1,
          stderr: [
            'Failed to load signer "signer #1"',
            'java.io.IOException: Keystore was tampered with, or password was incorrect',
          ],
        ),
      );

      final future = service().sign(
        executor,
        toolchain: _toolchain,
        input: p.join(temp.path, 'a.apk'),
        request: request,
      );

      await expectLater(
        future,
        throwsA(
          isA<ToolFailure>()
              .having((f) => f.title, 'title', 'Signing failed (exit code 1)')
              .having(
                (f) => f.details.last,
                'reason',
                contains('password was incorrect'),
              ),
        ),
      );
      expect(runner.callsWithFirstArg('verify'), isEmpty);
    });

    test('a failed signing leaves an earlier signed APK intact and no partial file', () async {
      final input = p.join(temp.path, 'app.apk');
      final earlier = File(p.join(temp.path, 'app-signed.apk'))
        ..writeAsStringSync('earlier');
      runner.when((c) => c.arguments.first == 'sign', (c) {
        // apksigner got as far as writing part of its output.
        File(c.arguments[c.arguments.indexOf('--out') + 1])
            .writeAsStringSync('half');
        return failed(2, stderr: ['Failed to load signer "signer #1"']);
      });

      await expectLater(
        service().sign(
          executor,
          toolchain: _toolchain,
          input: input,
          request: request,
        ),
        throwsA(isA<ToolFailure>()),
      );

      expect(earlier.readAsStringSync(), 'earlier');
      expect(File('${earlier.path}.partial').existsSync(), isFalse);
    });

    test('a signing that verifies replaces the earlier signed APK', () async {
      final input = p.join(temp.path, 'app.apk');
      final earlier = File(p.join(temp.path, 'app-signed.apk'))
        ..writeAsStringSync('earlier');
      runner
        ..when((c) => c.arguments.first == 'sign', (c) {
          File(c.arguments[c.arguments.indexOf('--out') + 1])
              .writeAsStringSync('new');
          return ok();
        })
        ..whenFirstArg('verify', ok(fixture('apksigner_verify_test_key.txt')));

      final signed = await service().sign(
        executor,
        toolchain: _toolchain,
        input: input,
        request: request,
      );

      expect(signed.path, earlier.path);
      expect(earlier.readAsStringSync(), 'new');
      expect(File('${earlier.path}.partial').existsSync(), isFalse);
    });

    test('fails when the signed APK carries another signer', () async {
      runner.whenFirstArg(
        'verify',
        ok(fixture('apksigner_verify_debug_key.txt')),
      );

      await expectLater(
        service().sign(
          executor,
          toolchain: _toolchain,
          input: p.join(temp.path, 'a.apk'),
          request: request,
          expectedSha256: testKeySha,
        ),
        throwsA(
          isA<ToolFailure>().having(
            (f) => f.title,
            'title',
            'The signed APK has another signer',
          ),
        ),
      );
    });

    test('without zipalign it warns and signs anyway', () async {
      runner.whenFirstArg(
        'verify',
        ok(fixture('apksigner_verify_test_key.txt')),
      );
      const noZipalign = Toolchain(apksigner: '/bt/apksigner');

      await service().sign(
        executor,
        toolchain: noZipalign,
        input: p.join(temp.path, 'a.apk'),
        request: request,
      );

      expect(log.lines, contains(startsWith('warning: zipalign not found')));
    });
  });

  group('KeystoreService', () {
    test('lists the keys without echoing the certificates', () async {
      runner.when(
        (c) => c.executable == '/jdk/keytool',
        (_) => ok(fixture('keytool_list.txt')),
      );

      final entries = await const KeystoreService().listEntries(
        executor,
        keytool: '/jdk/keytool',
        keystorePath: '/k.jks',
        password: 'hunter2',
      );

      expect(entries.map((e) => e.alias), ['forge-test', 'second-key']);
      expect(runner.calls.single.environment, {
        keystorePasswordVariable: 'hunter2',
      });
      expect(log.lines.where((l) => l.startsWith('stdout')), isEmpty);
    });

    test('a wrong password says so', () async {
      runner.when(
        (c) => c.executable == '/jdk/keytool',
        (_) => failed(
          1,
          stdout: [
            'keytool error: java.io.IOException: Keystore was tampered with, or password was incorrect',
          ],
        ),
      );

      await expectLater(
        const KeystoreService().listEntries(
          executor,
          keytool: '/jdk/keytool',
          keystorePath: '/k.jks',
          password: 'x',
        ),
        throwsA(
          isA<ToolFailure>().having(
            (f) => f.details.single,
            'reason',
            contains('password was incorrect'),
          ),
        ),
      );
    });
  });

  group('FlutterBuildService', () {
    test('runs in the project and returns the APKs it reports', () async {
      runner.whenFirstArg('build', ok(fixture('flutter_build_split.txt')));

      final apks = await const FlutterBuildService(host: macHost).build(
        executor,
        flutter: '/flutter/bin/flutter',
        options: const BuildOptions(
          projectDir: '/work/app',
          packaging: ApkPackaging.splitPerAbi,
        ),
      );

      expect(apks, hasLength(3));
      expect(runner.calls.single.workingDirectory, '/work/app');
      expect(
        log.lines,
        contains(
          'stdout: ✓ Built build/app/outputs/flutter-apk/app-arm64-v8a-release.apk (15.0MB)',
        ),
      );
    });

    test('warns when an obfuscated build left no symbols', () async {
      runner.whenFirstArg('build', ok(fixture('flutter_build_split.txt')));
      final symbols = Directory(p.join(temp.path, 'symbols'))..createSync();

      Future<void> build() => const FlutterBuildService(host: macHost).build(
        executor,
        flutter: 'flutter',
        options: BuildOptions(
          projectDir: '/work/app',
          obfuscate: true,
          symbolsDir: symbols.path,
        ),
      );

      await build();
      expect(log.lines, contains(startsWith('warning: No .symbols files')));

      log.lines.clear();
      File(p.join(symbols.path, 'app.android-arm64.symbols'))
          .writeAsStringSync('');
      await build();
      expect(log.lines.where((l) => l.startsWith('warning')), isEmpty);
    });

    test('a failed build shows Gradle\'s reason', () async {
      runner.whenFirstArg(
        'build',
        failed(
          1,
          stdout: [
            'FAILURE: Build failed with an exception.',
            '* What went wrong:',
            'Execution failed for task \':app:compileFlutterBuildRelease\'.',
            '* Try:',
          ],
        ),
      );

      await expectLater(
        const FlutterBuildService(host: macHost).build(
          executor,
          flutter: 'flutter',
          options: const BuildOptions(projectDir: '/work/app'),
        ),
        throwsA(
          isA<ToolFailure>()
              .having((f) => f.title, 'title', 'Build failed (exit code 1)')
              .having((f) => f.details, 'details', [
                'Execution failed for task \':app:compileFlutterBuildRelease\'.',
              ]),
        ),
      );
    });

    test('a flutter that cannot start says so', () async {
      runner.whenFirstArg(
        'build',
        failed(
          startFailureExitCode,
          stderr: ['Could not start flutter: No such file'],
        ),
      );

      await expectLater(
        const FlutterBuildService(host: macHost).build(
          executor,
          flutter: 'flutter',
          options: const BuildOptions(projectDir: '/w'),
        ),
        throwsA(
          isA<ToolFailure>().having(
            (f) => f.title,
            'title',
            'Build failed (could not start)',
          ),
        ),
      );
    });

    test('readFlutterVersion reads the machine output', () async {
      runner.when(
        (c) => c.arguments.contains('--machine'),
        (_) => ok([
          '{',
          '  "frameworkVersion": "3.47.5",',
          '  "channel": "stable"',
          '}',
        ]),
      );

      expect(await readFlutterVersion(executor, 'flutter'), '3.47.5');
    });
  });

  group('AdbService', () {
    test('lists devices and reads the ABIs of the ready ones only', () async {
      runner
        ..whenFirstArg(
          'devices',
          ok([
            'List of devices attached',
            'SER1 device model:K10',
            'SER2 unauthorized',
          ]),
        )
        ..when(
          (c) => c.arguments.contains('getprop'),
          (_) => ok(['arm64-v8a,armeabi-v7a,armeabi']),
        );

      final devices = await const AdbService().devices(
        executor,
        adb: '/pt/adb',
      );

      expect(devices.first.abis, ['arm64-v8a', 'armeabi-v7a', 'armeabi']);
      expect(devices.last.abis, isEmpty);
      expect(
        runner.calls.where((c) => c.arguments.contains('getprop')),
        hasLength(1),
      );
    });

    test('an install failure names the code and the fix', () async {
      runner.when(
        (c) => c.arguments.contains('install'),
        (_) => failed(
          1,
          stdout: [
            'adb: failed to install a.apk: Failure [INSTALL_FAILED_VERSION_DOWNGRADE]',
          ],
        ),
      );

      await expectLater(
        const AdbService().install(
          executor,
          adb: '/pt/adb',
          serial: 'S',
          apk: '/a.apk',
          allowDowngrade: false,
        ),
        throwsA(
          isA<ToolFailure>()
              .having(
                (f) => f.title,
                'title',
                'Install failed: INSTALL_FAILED_VERSION_DOWNGRADE',
              )
              .having(
                (f) => f.details.first,
                'hint',
                contains('Allow downgrade'),
              ),
        ),
      );
    });

    test('reads the device in one shell call', () async {
      runner.when(
        (c) => c.arguments.contains('shell'),
        (_) => ok(fixture('adb_device_info_emulator.txt')),
      );

      final info = await const AdbService().deviceInfo(
        executor,
        adb: '/pt/adb',
        serial: 'emulator-5554',
      );

      expect(info.sdk, 33);
      expect(runner.calls.single.arguments.take(3), [
        '-s',
        'emulator-5554',
        'shell',
      ]);
      expect(runner.calls.single.arguments.last, deviceInfoScript());
    });

    test('a device that answers nothing is an error', () async {
      runner.when(
        (c) => c.arguments.contains('shell'),
        (_) => failed(1, stderr: ['error: device offline']),
      );

      await expectLater(
        const AdbService().deviceInfo(executor, adb: '/pt/adb', serial: 'S'),
        throwsA(
          isA<ToolFailure>().having((f) => f.details, 'details', [
            'error: device offline',
          ]),
        ),
      );
    });

    test('a package grep finds nothing when it is not installed', () async {
      runner.when((c) => c.arguments.contains('shell'), (_) => failed(1));

      expect(
        await const AdbService().installedPackage(
          executor,
          adb: '/pt/adb',
          serial: 'S',
          package: 'com.example.app',
        ),
        isNull,
      );
    });

    test('an install needs adb\'s "Success"', () async {
      runner.when(
        (c) => c.arguments.contains('install'),
        (_) => ok(['Performing Streamed Install', 'Success']),
      );

      await const AdbService().install(
        executor,
        adb: '/pt/adb',
        serial: 'S',
        apk: '/a.apk',
        allowDowngrade: true,
      );

      expect(runner.calls.single.arguments, [
        '-s',
        'S',
        'install',
        '-r',
        '-d',
        '/a.apk',
      ]);
    });
  });

  group('ApkSplitService', () {
    ApkSplitService service() =>
        ApkSplitService(host: macHost, temporaryDirectory: () => temp);

    String apk(String name, List<String> entries) {
      final archive = Archive();
      for (final entry in entries) {
        archive.add(
          ArchiveFile.string(entry, 'content of $entry')
            ..compression = entry.endsWith('.so')
                ? CompressionType.none
                : CompressionType.deflate,
        );
      }
      final path = p.join(temp.path, name);
      File(path).writeAsBytesSync(ZipEncoder().encode(archive));
      return path;
    }

    const shared = [
      'AndroidManifest.xml',
      'classes.dex',
      'resources.arsc',
      'META-INF/services/l0',
    ];
    const flutterAbis = ['arm64-v8a', 'armeabi-v7a', 'x86_64'];
    List<String> universal() => [
      for (final abi in flutterAbis) ...[
        'lib/$abi/libapp.so',
        'lib/$abi/libflutter.so',
      ],
      ...shared,
      // Left by an earlier v1 signing; the splits must not carry them.
      'META-INF/MANIFEST.MF',
      'META-INF/CERT.SF',
      'META-INF/CERT.RSA',
    ];

    Iterable<String> splitDirectories() => temp
        .listSync()
        .map((entity) => p.basename(entity.path))
        .where((name) => name.startsWith('apk_forge_split_'));

    test(
      'writes one APK per ABI with only its native code, then deletes them',
      () async {
        final input = apk('app-release.apk', universal());
        final seen = <String, List<String>>{};

        final splits = await service().withSplits(
          executor,
          input: input,
          use: (splits) async {
            for (final split in splits) {
              seen[p.basename(split.path)] = [
                for (final entry in await readZipDirectory(split.path))
                  entry.name,
              ];
            }
            return splits;
          },
        );

        expect(splits.map((s) => s.abi), flutterAbis);
        expect(seen.keys, [
          'app-release-arm64-v8a.apk',
          'app-release-armeabi-v7a.apk',
          'app-release-x86_64.apk',
        ]);
        expect(seen['app-release-x86_64.apk'], [
          'lib/x86_64/libapp.so',
          'lib/x86_64/libflutter.so',
          ...shared,
        ]);
        expect(runner.calls, isEmpty);
        expect(splitDirectories(), isEmpty);
        expect(
          log.lines,
          contains(
            startsWith('info: Split arm64-v8a: app-release-arm64-v8a.apk'),
          ),
        );
      },
    );

    test('one ABI is nothing to split', () async {
      final input = apk('app.apk', [
        'lib/arm64-v8a/libflutter.so',
        'lib/arm64-v8a/libapp.so',
        ...shared,
      ]);

      final splits = await service().withSplits(
        executor,
        input: input,
        use: (splits) async => splits,
      );

      expect(splits, isEmpty);
      expect(
        log.lines,
        contains('info: app.apk only has arm64-v8a: nothing to split.'),
      );
      expect(splitDirectories(), isEmpty);
    });

    test(
      'an ABI without the Flutter engine is left out, with a warning',
      () async {
        final input = apk('app.apk', [...universal(), 'lib/x86/libplugin.so']);

        final splits = await service().withSplits(
          executor,
          input: input,
          use: (splits) async => splits,
        );

        expect(splits.map((s) => s.abi), flutterAbis);
        expect(log.lines, contains(startsWith('warning: Left out x86')));
      },
    );

    test('the splits are deleted when using them fails', () async {
      final input = apk('app.apk', universal());

      await expectLater(
        service().withSplits(
          executor,
          input: input,
          use: (_) async => throw const ToolFailure('Signing failed'),
        ),
        throwsA(isA<ToolFailure>()),
      );
      expect(splitDirectories(), isEmpty);
    });

    test('a file that is not an APK fails with the reason', () async {
      final input = p.join(temp.path, 'junk.apk');
      File(input).writeAsBytesSync(List.filled(100, 7));

      await expectLater(
        service().withSplits(
          executor,
          input: input,
          use: (splits) async => splits,
        ),
        throwsA(
          isA<ToolFailure>()
              .having((f) => f.title, 'title', 'Cannot read junk.apk')
              .having(
                (f) => f.details.single,
                'reason',
                startsWith('Not a ZIP'),
              ),
        ),
      );
    });
  });

  group('ApkAnalyzer', () {
    late String apk;

    setUp(() {
      final archive = Archive()
        ..add(ArchiveFile.string('lib/arm64-v8a/libflutter.so', 'engine'))
        ..add(ArchiveFile.string('lib/arm64-v8a/libapp.so', 'app'))
        ..add(ArchiveFile.string('AndroidManifest.xml', 'manifest'));
      apk = p.join(temp.path, 'app.apk');
      File(apk).writeAsBytesSync(ZipEncoder().encode(archive));
    });

    test('reads the key rotation of a v3 signature', () async {
      runner
        ..whenFirstArg('dump', ok(fixture('aapt2_badging_release.txt')))
        ..whenFirstArg('verify', ok(fixture('apksigner_verify_rotated_v3.txt')))
        ..whenFirstArg('lineage', ok(fixture('apksigner_lineage_rotated.txt')));

      final report = await const ApkAnalyzer().analyze(
        executor,
        toolchain: _toolchain,
        path: apk,
      );

      expect(runner.callsWithFirstArg('lineage').single.arguments, [
        'lineage',
        '--in',
        apk,
        '--print-certs',
      ]);
      expect(report.signature!.lineage.map((s) => s.distinguishedName), [
        'CN=APK Forge Old Key, O=Example, C=US',
        'CN=APK Forge New Key, O=Example, C=US',
      ]);
    });

    test('a key that never rotated leaves the signature as it is', () async {
      runner
        ..whenFirstArg('verify', ok(fixture('apksigner_verify_old_key.txt')))
        ..whenFirstArg(
          'lineage',
          failed(1, stdout: fixture('apksigner_lineage_none.txt')),
        );

      final report = await const ApkAnalyzer().analyze(
        executor,
        toolchain: _toolchain,
        path: apk,
      );

      expect(runner.callsWithFirstArg('lineage'), hasLength(1));
      expect(report.signature!.lineage, isEmpty);
      expect(report.signature!.verifies, isTrue);
      expect(report.signatureError, isNull);
    });

    test('a v2-only signature cannot rotate: no lineage is read', () async {
      runner.whenFirstArg(
        'verify',
        ok(fixture('apksigner_verify_debug_key.txt')),
      );

      await const ApkAnalyzer().analyze(
        executor,
        toolchain: _toolchain,
        path: apk,
      );

      expect(runner.callsWithFirstArg('lineage'), isEmpty);
    });

    test(
      'combines the hashes, the files, the manifest and the signature',
      () async {
        runner
          ..whenFirstArg('dump', ok(fixture('aapt2_badging_release.txt')))
          ..whenFirstArg(
            'verify',
            ok(fixture('apksigner_verify_debug_key.txt')),
          );

        final report = await const ApkAnalyzer().analyze(
          executor,
          toolchain: _toolchain,
          path: apk,
        );

        expect(report.sizeBytes, File(apk).lengthSync());
        expect(report.md5, hasLength(32));
        expect(report.sha256, hasLength(64));
        expect(report.contents.nativeLibraries.keys, ['arm64-v8a']);
        expect(report.badging!.packageName, 'io.example.sample_app');
        expect(report.isDebuggable, isFalse);
        expect(report.signature!.signers.single.isAndroidDebugKey, isTrue);
        // The command lines are logged; aapt2's long output is not.
        expect(log.lines.where((l) => l.startsWith(r'$')), hasLength(2));
        expect(log.lines.where((l) => l.startsWith('stdout')), isEmpty);
      },
    );

    test('a missing tool leaves its part empty with the reason', () async {
      final report = await const ApkAnalyzer().analyze(
        executor,
        toolchain: const Toolchain(),
        path: apk,
      );

      expect(report.badging, isNull);
      expect(report.badgingError, contains('aapt2'));
      expect(report.signature, isNull);
      expect(report.signatureError, contains('apksigner'));
      expect(report.contents.isFlutterApp, isTrue);
    });

    test('an apksigner crash is an error, not a "does not verify"', () async {
      runner.whenFirstArg(
        'verify',
        failed(1, stderr: fixture('apksigner_verify_not_zip.txt')),
      );

      final report = await const ApkAnalyzer().analyze(
        executor,
        toolchain: _toolchain,
        path: apk,
      );

      expect(report.signature, isNull);
      expect(
        report.signatureError,
        startsWith('Malformed APK: not a ZIP archive'),
      );
    });

    test('a missing file fails', () async {
      await expectLater(
        const ApkAnalyzer().analyze(
          executor,
          toolchain: _toolchain,
          path: p.join(temp.path, 'gone.apk'),
        ),
        throwsA(
          isA<ToolFailure>().having((f) => f.title, 'title', 'File not found'),
        ),
      );
    });
  });

  test('ToolExecutor masks the command\'s secrets in its output', () async {
    runner.when((_) => true, (_) => ok(['password is hunter2']));

    await executor.run(const Command('tool', ['x'], secrets: ['hunter2']));

    expect(log.lines, [r'$ tool x', 'stdout: password is ••••']);
  });
}
