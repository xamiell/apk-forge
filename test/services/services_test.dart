import 'dart:convert';
import 'dart:io';

import 'package:apk_forge/core/files/file_digests.dart';
import 'package:apk_forge/core/process/command.dart';
import 'package:apk_forge/core/process/process_runner.dart';
import 'package:apk_forge/core/system/host.dart';
import 'package:apk_forge/core/zip/zip_directory.dart';
import 'package:apk_forge/domain/analysis/apk_report.dart';
import 'package:apk_forge/domain/build/build_options.dart';
import 'package:apk_forge/domain/profiles/key_properties.dart';
import 'package:apk_forge/domain/profiles/profile.dart';
import 'package:apk_forge/domain/profiles/profile_plan.dart';
import 'package:apk_forge/domain/profiles/profile_run.dart';
import 'package:apk_forge/domain/devices/device_info.dart';
import 'package:apk_forge/domain/failure.dart';
import 'package:apk_forge/domain/signing/keystore.dart';
import 'package:apk_forge/domain/signing/new_key.dart';
import 'package:apk_forge/domain/signing/signing.dart';
import 'package:apk_forge/domain/tools/toolchain.dart';
import 'package:apk_forge/services/adb_service.dart';
import 'package:apk_forge/services/apk_analyzer.dart';
import 'package:apk_forge/services/apk_split_service.dart';
import 'package:apk_forge/services/bundle_signing_service.dart';
import 'package:apk_forge/services/flutter_build_service.dart';
import 'package:apk_forge/services/installed_apk_service.dart';
import 'package:apk_forge/services/new_key_service.dart';
import 'package:apk_forge/services/profile_runner.dart';
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

    test(
      'a key that does not open says which password, and what to do',
      () async {
        final cases = {
          'apksigner_sign_key_password_missing.txt':
              KeyLoadFailure.keyPasswordMissing,
          'apksigner_sign_wrong_key_password.txt':
              KeyLoadFailure.keyPasswordWrong,
          'apksigner_sign_wrong_store_password.txt':
              KeyLoadFailure.storePasswordWrong,
          'apksigner_sign_wrong_key_password_pkcs12.txt':
              KeyLoadFailure.keyPasswordWrong,
          'apksigner_sign_wrong_store_password_pkcs12.txt':
              KeyLoadFailure.storePasswordWrong,
        };
        for (final MapEntry(key: name, value: expected) in cases.entries) {
          final runner = FakeProcessRunner()
            ..whenFirstArg('sign', failed(2, stderr: fixture(name)));

          final future = service().sign(
            ToolExecutor(runner, RecordingLog()),
            toolchain: _toolchain,
            input: p.join(temp.path, 'a.apk'),
            request: request,
          );

          await expectLater(
            future,
            throwsA(
              isA<ToolFailure>()
                  .having((f) => f.title, 'title', expected.problem)
                  .having((f) => f.details, 'details', [expected.fix]),
            ),
            reason: name,
          );
          expect(runner.callsWithFirstArg('verify'), isEmpty, reason: name);
        }
      },
    );

    test('another failure keeps apksigner\'s reason, masked', () async {
      runner.whenFirstArg(
        'sign',
        failed(1, stderr: ['ERROR: could not write out.apk for hunter2']),
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
                (f) => f.details.single,
                'reason',
                'ERROR: could not write out.apk for ••••',
              ),
        ),
      );
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

    test(
      'a v4 signing is verified with its .idsig, which goes along',
      () async {
        final input = p.join(temp.path, 'app.apk');
        runner
          ..when((c) => c.arguments.first == 'sign', (c) {
            final out = c.arguments[c.arguments.indexOf('--out') + 1];
            File(out).writeAsStringSync('signed');
            File('$out.idsig').writeAsStringSync('v4');
            return ok();
          })
          ..whenFirstArg(
            'verify',
            ok(fixture('apksigner_verify_all_schemes.txt')),
          );

        final signed = await service().sign(
          executor,
          toolchain: _toolchain,
          input: input,
          request: const SigningRequest(
            keystorePath: '/k.jks',
            storePassword: 'hunter2',
            alias: 'upload',
            schemes: SigningSchemes(v1: true, v2: true, v3: true, v4: true),
          ),
        );

        final verify = runner.callsWithFirstArg('verify').single.arguments;
        final idsig = verify[verify.indexOf('--v4-signature-file') + 1];
        expect(idsig, '${verify.last}.idsig');
        expect(signed.verifiedSchemes['v4'], isTrue);
        expect(signed.verifiedSchemes['v1'], isFalse);
        expect(File('${signed.path}.idsig').readAsStringSync(), 'v4');
      },
    );

    test('without an .idsig, verify is not told of one', () async {
      runner.whenFirstArg(
        'verify',
        ok(fixture('apksigner_verify_test_key.txt')),
      );

      final signed = await service().sign(
        executor,
        toolchain: _toolchain,
        input: p.join(temp.path, 'app.apk'),
        request: request,
      );

      expect(
        runner.callsWithFirstArg('verify').single.arguments,
        isNot(contains('--v4-signature-file')),
      );
      expect(signed.verifiedSchemes, containsPair('v4', false));
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

  group('BundleSigningService', () {
    const tools = Toolchain(
      keytool: '/jdk/keytool',
      jarsigner: '/jdk/jarsigner',
    );

    /// The key in `keytool_printcert_jarfile.txt`.
    const bundleKeySha =
        '818fd329733db2f528cddae7e7bfb0382e7cf9121277667e3d9e496202f9ed37';
    const request = SigningRequest(
      keystorePath: '/k.jks',
      storePassword: 'hunter2',
      alias: 'upload',
    );
    late String input;
    late List<String> signedEntries;

    setUp(() {
      // A bundle as Flutter writes it: signed with the debug key.
      input = p.join(temp.path, 'app-release.aab');
      final archive = Archive()
        ..add(ArchiveFile.string('META-INF/MANIFEST.MF', 'manifest'))
        ..add(ArchiveFile.string('META-INF/ANDROIDD.SF', 'signature'))
        ..add(ArchiveFile.string('META-INF/ANDROIDD.RSA', 'certificate'))
        ..add(ArchiveFile.string('base/manifest/AndroidManifest.xml', 'pb'))
        ..add(ArchiveFile.string('base/root/META-INF/library.version', '1'))
        ..add(ArchiveFile.string('base/lib/arm64-v8a/libapp.so', 'app'));
      File(input).writeAsBytesSync(ZipEncoder().encode(archive));
      signedEntries = [];
    });

    /// jarsigner answers by writing the signed copy, as the real one does,
    /// after noting what it was given.
    void jarsignerSigns() => runner.when(
      (c) =>
          c.executable == '/jdk/jarsigner' &&
          c.arguments.contains('-signedjar'),
      (c) {
        final unsigned = c.arguments[c.arguments.length - 2];
        signedEntries = [
          for (final file in ZipDecoder().decodeBytes(
            File(unsigned).readAsBytesSync(),
          ))
            file.name,
        ];
        final output = c.arguments[c.arguments.indexOf('-signedjar') + 1];
        File(unsigned).copySync(output);
        return ok();
      },
    );

    void verifies({String verify = 'jarsigner_verify_bundle.txt'}) => runner
      ..when(
        (c) =>
            c.executable == '/jdk/jarsigner' && c.arguments.contains('-verify'),
        (_) => ok(fixture(verify)),
      )
      ..when(
        (c) => c.executable == '/jdk/keytool',
        (_) => ok(fixture('keytool_printcert_jarfile.txt')),
      );

    Future<SignedBundle> sign({String? expectedSha256 = bundleKeySha}) =>
        BundleSigningService(
          host: macHost,
          temporaryDirectory: () => temp,
        ).sign(
          executor,
          toolchain: tools,
          input: input,
          request: request,
          expectedSha256: expectedSha256,
        );

    test('signs a copy without the debug signature, then checks it carries '
        'the key', () async {
      jarsignerSigns();
      verifies();
      final before = File(input).readAsBytesSync();

      final signed = await sign();

      expect(signed.path, p.join(temp.path, 'app-release-signed.aab'));
      expect(signed.signer.sha256, bundleKeySha);
      expect(File(signed.path).existsSync(), isTrue);
      expect(File('${signed.path}.partial').existsSync(), isFalse);
      expect(File(input).readAsBytesSync(), before);
      // The old JAR signature is gone; the app's own META-INF files stay.
      expect(signedEntries, [
        'base/manifest/AndroidManifest.xml',
        'base/root/META-INF/library.version',
        'base/lib/arm64-v8a/libapp.so',
      ]);
      final jarsigner = runner.calls.first;
      expect(jarsigner.environment, {keystorePasswordVariable: 'hunter2'});
      expect(jarsigner.arguments.join(' '), isNot(contains('hunter2')));
      expect(
        log.lines,
        contains(
          startsWith(
            'success: Signed and verified: '
            'app-release-signed.aab (JAR signature; SHA-256 81:8F:D3',
          ),
        ),
      );
      expect(log.lines.join('\n'), isNot(contains('hunter2')));
      // Only the signed bundle is left: no unsigned copy, no .partial.
      expect(temp.listSync().map((entry) => p.basename(entry.path)).toSet(), {
        'app-release.aab',
        'app-release-signed.aab',
      });
    });

    test(
      'a key that does not open says which password, and what to do',
      () async {
        final cases = {
          'jarsigner_sign_wrong_store_password_pkcs12.txt':
              KeyLoadFailure.storePasswordWrong,
          'jarsigner_sign_wrong_key_password.txt':
              KeyLoadFailure.keyPasswordWrong,
          'jarsigner_sign_key_password_missing.txt':
              KeyLoadFailure.keyPasswordMissing,
        };
        for (final MapEntry(key: name, value: expected) in cases.entries) {
          runner = FakeProcessRunner()
            ..when(
              (c) => c.executable == '/jdk/jarsigner',
              (_) => failed(1, stdout: fixture(name)),
            );
          executor = ToolExecutor(runner, log);

          await expectLater(
            sign(),
            throwsA(
              isA<ToolFailure>()
                  .having((f) => f.title, 'title', expected.problem)
                  .having((f) => f.details, 'details', [expected.fix]),
            ),
            reason: name,
          );
          expect(
            File(p.join(temp.path, 'app-release-signed.aab')).existsSync(),
            isFalse,
            reason: name,
          );
        }
      },
    );

    test('a bundle that does not verify is not kept', () async {
      jarsignerSigns();
      verifies(verify: 'jarsigner_verify_signed_over_debug.txt');

      await expectLater(
        sign(),
        throwsA(
          isA<ToolFailure>()
              .having(
                (f) => f.title,
                'title',
                'The signed bundle does not verify',
              )
              .having((f) => f.details.single, 'reason', contains('invalid')),
        ),
      );
      expect(
        File(p.join(temp.path, 'app-release-signed.aab')).existsSync(),
        isFalse,
      );
    });

    test('a second signer, such as the debug key, is not kept', () async {
      jarsignerSigns();
      runner
        ..when(
          (c) =>
              c.executable == '/jdk/jarsigner' &&
              c.arguments.contains('-verify'),
          (_) => ok(fixture('jarsigner_verify_bundle.txt')),
        )
        ..when(
          (c) => c.executable == '/jdk/keytool',
          (_) => ok(fixture('keytool_printcert_jarfile_two_signers.txt')),
        );

      await expectLater(
        sign(),
        throwsA(
          isA<ToolFailure>().having(
            (f) => f.title,
            'title',
            'The signed bundle has 2 signers',
          ),
        ),
      );
      expect(
        File(p.join(temp.path, 'app-release-signed.aab')).existsSync(),
        isFalse,
      );
    });

    test('another signer than the key in Sign is not kept', () async {
      jarsignerSigns();
      verifies();

      await expectLater(
        sign(
          expectedSha256: 'b34c9445c5e411b045884f499034b5592ab109ec5cd1ca9cb584e54f582dcfa8',
        ),
        throwsA(
          isA<ToolFailure>().having(
            (f) => f.title,
            'title',
            'The signed bundle has another signer',
          ),
        ),
      );
      expect(
        File(p.join(temp.path, 'app-release-signed.aab')).existsSync(),
        isFalse,
      );
    });

    test('without jarsigner, nothing runs and it says how to get it', () async {
      await expectLater(
        BundleSigningService(host: macHost).sign(
          executor,
          toolchain: const Toolchain(keytool: '/jdk/keytool'),
          input: input,
          request: request,
        ),
        throwsA(same(jarsignerMissing)),
      );
      expect(runner.calls, isEmpty);
    });
  });

  group('NewKeyService', () {
    late NewKeyRequest request;
    const service = NewKeyService(host: macHost);

    setUp(() {
      request = NewKeyForm(
        folder: temp.path,
        storePassword: 'hunter22',
        confirmStorePassword: 'hunter22',
        commonName: 'Jane Doe',
      ).toRequest(macHost, DateTime(2026, 10, 21));
    });

    /// keytool answers by writing the keystore, as the real one does.
    void keytoolWritesTheKeystore() =>
        runner.when((c) => c.executable == '/jdk/keytool', (c) {
          final keystore = c.arguments[c.arguments.indexOf('-keystore') + 1];
          File(keystore).writeAsStringSync('keystore');
          return ok();
        });

    Future<void> create() =>
        service.create(executor, keytool: '/jdk/keytool', request: request);

    test('makes the keystore with keytool, then a key.properties that '
        'Gradle and profiles read', () async {
      keytoolWritesTheKeystore();

      await create();

      final keytool = runner.calls.first;
      expect(keytool.executable, '/jdk/keytool');
      expect(
        keytool.arguments,
        keytoolGenerateKeyArguments(
          request.keystorePath,
          'upload',
          distinguishedName: 'CN=Jane Doe',
          validityDays: 9131,
        ),
      );
      expect(keytool.environment, {
        keystorePasswordVariable: 'hunter22',
        keyPasswordVariable: 'hunter22',
      });
      final keys = parseKeyProperties(
        File(request.keyPropertiesPath).readAsStringSync(),
      );
      expect(keys.storeFile, request.keystorePath);
      expect(keys.keyAlias, 'upload');
      expect(keys.storePassword, 'hunter22');
      expect(keys.keyPassword, 'hunter22');
    });

    test('key.properties is made owner-only while it is still empty', () async {
      keytoolWritesTheKeystore();
      int? sizeWhenPrivate;
      runner.when((c) => c.executable == '/bin/chmod', (c) {
        sizeWhenPrivate = File(c.arguments.last).lengthSync();
        return ok();
      });

      await create();

      expect(runner.calls.last.arguments, ['600', request.keyPropertiesPath]);
      expect(sizeWhenPrivate, 0);
    });

    test('no password in an argument or the log', () async {
      keytoolWritesTheKeystore();

      await create();

      for (final call in runner.calls) {
        expect(call.arguments.join(' '), isNot(contains('hunter22')));
      }
      expect(log.lines.join('\n'), isNot(contains('hunter22')));
    });

    test('a keystore or key.properties already there: keytool never runs, '
        'and nothing changes', () async {
      for (final existing in [
        request.keystorePath,
        request.keyPropertiesPath,
      ]) {
        File(existing).writeAsStringSync('earlier');

        await expectLater(
          create(),
          throwsA(
            isA<ToolFailure>()
                .having((f) => f.title, 'title', 'Nothing was written')
                .having((f) => f.details, 'details', [
                  '$existing already exists.',
                ]),
          ),
        );
        expect(runner.calls, isEmpty);
        expect(File(existing).readAsStringSync(), 'earlier');
        File(existing).deleteSync();
      }
    });

    test('keytool fails: its reason, and no key.properties', () async {
      runner.when(
        (c) => c.executable == '/jdk/keytool',
        (_) => failed(
          1,
          stdout: fixture('keytool_genkeypair_read_only_folder.txt'),
        ),
      );

      await expectLater(
        create(),
        throwsA(
          isA<ToolFailure>()
              .having((f) => f.title, 'title', 'keytool could not make the key')
              .having((f) => f.details, 'details', [
                'ro/x.jks (Permission denied)',
              ]),
        ),
      );
      expect(File(request.keyPropertiesPath).existsSync(), isFalse);
      expect(runner.calls.where((c) => c.executable == '/bin/chmod'), isEmpty);
    });

    test(
      'key.properties can\'t be made private: neither file is left',
      () async {
        keytoolWritesTheKeystore();
        runner.when((c) => c.executable == '/bin/chmod', (_) => failed(1));

        await expectLater(
          create(),
          throwsA(
            isA<ToolFailure>().having(
              (f) => f.title,
              'title',
              startsWith('Could not make ${request.keyPropertiesPath} private'),
            ),
          ),
        );
        expect(File(request.keystorePath).existsSync(), isFalse);
        expect(File(request.keyPropertiesPath).existsSync(), isFalse);
      },
    );

    test('on Windows, which has no file modes, chmod doesn\'t run', () async {
      keytoolWritesTheKeystore();
      const windows = NewKeyService(
        host: Host(os: HostOs.windows, environment: {}),
      );

      await windows.create(executor, keytool: '/jdk/keytool', request: request);

      expect(runner.calls.map((c) => c.executable), ['/jdk/keytool']);
      expect(File(request.keyPropertiesPath).existsSync(), isTrue);
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

    test('only the ABIs asked for, with what is left out in the log', () async {
      final input = apk('app.apk', universal());

      final splits = await service().withSplits(
        executor,
        input: input,
        abis: {'arm64-v8a', 'armeabi-v7a', 'riscv64'},
        use: (splits) async => splits,
      );

      expect(splits.map((s) => s.abi), ['arm64-v8a', 'armeabi-v7a']);
      expect(
        log.lines,
        containsAll([
          'warning: app.apk has no riscv64: no APK for it.',
          'info: Left out x86_64: not chosen.',
        ]),
      );
      expect(splitDirectories(), isEmpty);
    });

    test('an APK with none of the ABIs asked for fails', () async {
      final input = apk('app.apk', universal());

      await expectLater(
        service().withSplits(
          executor,
          input: input,
          abis: {'riscv64'},
          use: (splits) async => splits,
        ),
        throwsA(
          isA<ToolFailure>()
              .having(
                (f) => f.title,
                'title',
                'app.apk has none of the architectures chosen',
              )
              .having(
                (f) => f.details.single,
                'details',
                'It has arm64-v8a, armeabi-v7a, x86_64; chosen: riscv64.',
              ),
        ),
      );
    });

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

  group('ProfileKeyService', () {
    const store = 'st0re pass';
    const key = 'k3y pass';
    const testKeySha =
        'b34c9445c5e411b045884f499034b5592ab109ec5cd1ca9cb584e54f582dcfa8';
    late String properties;

    void writeProperties(String content) =>
        File(properties).writeAsStringSync(content);

    setUp(() {
      final folder = Directory(p.join(temp.path, 'keys'))..createSync();
      File(p.join(folder.path, 'release.jks')).writeAsStringSync('keystore');
      properties = p.join(folder.path, 'key.properties');
      writeProperties(
        'storePassword=$store\nkeyPassword=$key\n'
        'keyAlias=forge-test\nstoreFile=release.jks\n',
      );
    });

    bool isList(Command c) => c.arguments.contains('-list');
    bool isCertreq(Command c) => c.arguments.contains('-certreq');

    Future<Map<String, OpenedKey>> open() =>
        const ProfileKeyService(host: macHost)
            .open(executor, keytool: '/jdk/keytool', keyFiles: [properties]);

    Future<void> expectCannot(String reason) => expectLater(
      open(),
      throwsA(
        isA<ToolFailure>()
            .having(
              (f) => f.title,
              'title',
              'Cannot open the key in $properties',
            )
            .having((f) => f.details.join('\n'), 'details', contains(reason)),
      ),
    );

    test(
      'opens a key with both passwords, from the environment only',
      () async {
        runner
          ..when(isList, (_) => ok(fixture('keytool_list.txt')))
          ..when(isCertreq, (_) => ok(fixture('keytool_certreq_ok.txt')));

        final opened = (await open())[properties]!;

        expect(opened.alias, 'forge-test');
        expect(opened.keystorePath, p.join(temp.path, 'keys', 'release.jks'));
        expect(opened.sha256, testKeySha);
        expect([opened.storePassword, opened.keyPassword], [store, key]);
        final certreq = runner.calls.singleWhere(isCertreq);
        expect(certreq.environment, {
          keystorePasswordVariable: store,
          keyPasswordVariable: key,
        });
        for (final call in runner.calls) {
          expect(call.arguments.join(' '), isNot(contains('pass ')));
        }
        expect(
          log.lines.join('\n'),
          isNot(anyOf(contains(store), contains(key))),
        );
        expect('$opened', isNot(anyOf(contains(store), contains(key))));
      },
    );

    test('a wrong key password stops it, naming the file', () async {
      runner
        ..when(isList, (_) => ok(fixture('keytool_list.txt')))
        ..when(
          isCertreq,
          (_) => failed(
            1,
            stdout: fixture('keytool_certreq_wrong_key_password.txt'),
          ),
        );

      await expectCannot('The key password (keyPassword) is wrong.');
    });

    test(
      'a wrong keystore password: keytool\'s reason, and no key check',
      () async {
        runner.when(
          isList,
          (_) => failed(1, stdout: fixture('keytool_list_wrong_password.txt')),
        );

        await expectCannot('password was incorrect');
        expect(runner.calls.where(isCertreq), isEmpty);
      },
    );

    test('an alias the keystore lacks', () async {
      writeProperties(
        'storePassword=$store\nkeyPassword=$key\n'
        'keyAlias=upload\nstoreFile=release.jks\n',
      );
      runner.when(isList, (_) => ok(fixture('keytool_list.txt')));

      await expectCannot('The keystore has no key "upload" (its keyAlias).');
    });

    test('a missing file, field or keystore, before keytool runs', () async {
      writeProperties('storeFile=release.jks\nstorePassword=$store\n');
      await expectCannot('It has no keyAlias, keyPassword.');

      writeProperties(
        'storePassword=$store\nkeyPassword=$key\n'
        'keyAlias=forge-test\nstoreFile=gone.jks\n',
      );
      await expectCannot('gone.jks (its storeFile) does not exist');

      File(properties).deleteSync();
      await expectCannot('The file does not exist.');
      expect(runner.calls, isEmpty);
    });
  });

  group('ProfileRunner', () {
    const testKeySha =
        'b34c9445c5e411b045884f499034b5592ab109ec5cd1ca9cb584e54f582dcfa8';
    const key = OpenedKey(
      keyProperties: '/keys/key.properties',
      keystorePath: '/keys/release.jks',
      alias: 'forge-test',
      storePassword: 'hunter2',
      keyPassword: 'hunter3',
      sha256: testKeySha,
    );

    ProfileRunner service() => ProfileRunner(
      host: macHost,
      signing: ApkSigningService(host: macHost, temporaryDirectory: () => temp),
      temporaryDirectory: () => temp,
    );

    /// A universal Flutter APK with arm64-v8a and armeabi-v7a.
    Future<ApkReport> universal() async {
      final archive = Archive()
        ..add(ArchiveFile.string('AndroidManifest.xml', 'manifest'))
        ..add(ArchiveFile.string('classes.dex', 'dex'));
      for (final abi in ['arm64-v8a', 'armeabi-v7a']) {
        archive
          ..add(ArchiveFile.string('lib/$abi/libflutter.so', 'engine'))
          ..add(ArchiveFile.string('lib/$abi/libapp.so', 'app'));
      }
      final path = p.join(temp.path, 'app-release.apk');
      File(path).writeAsBytesSync(ZipEncoder().encode(archive));
      return ApkReport(
        path: path,
        sizeBytes: File(path).lengthSync(),
        md5: 'm',
        sha256: 's',
        contents: ApkContents.fromEntries(await readZipDirectory(path)),
      );
    }

    /// apksigner writes what it signs to `--out`, and it verifies with the
    /// test key.
    void answerSigning() => runner
      ..when((c) => c.arguments.first == 'sign', (c) {
        final out = c.arguments[c.arguments.indexOf('--out') + 1];
        File(out).writeAsStringSync('signed ${p.basename(c.arguments.last)}');
        return ok();
      })
      ..whenFirstArg('verify', ok(fixture('apksigner_verify_test_key.txt')));

    ProfileTarget target(
      String name,
      AndroidAbi abi, {
      SigningSchemes? schemes,
    }) => ProfileTarget(
      id: name,
      name: name,
      abi: abi,
      keyProperties: '/keys/key.properties',
      schemes: schemes,
      outputDir: p.join(temp.path, 'out', name.toLowerCase()),
    );

    ProfileRunPlan plan(
      ApkReport input,
      List<ProfileTarget> targets, {
      SigningSchemes defaults = const SigningSchemes.automatic(),
    }) => planProfileRun(
      SigningProfile(id: 'p', name: 'Release', targets: targets),
      [input],
      defaultSchemes: defaults,
      host: macHost,
      // The runner makes the folders; the plan only checks they exist.
      probe: FakeFileProbe(
        files: {for (final t in targets) t.keyProperties},
        directories: {for (final t in targets) t.outputDir},
      ),
      date: DateTime(2026, 10, 18),
    );

    Iterable<String> leftovers() => temp
        .listSync(recursive: true)
        .map((entity) => p.basename(entity.path))
        .where(
          (name) => name.startsWith('apk_forge_') || name.endsWith('.partial'),
        );

    test(
      'cuts, signs once per shared signing, and writes every target',
      () async {
        answerSigning();
        final input = await universal();
        final progress = <String>[];

        final results = await service().run(
          executor,
          toolchain: _toolchain,
          plan: plan(input, [
            target('Phone', AndroidAbi.arm64V8a),
            target('Tablet', AndroidAbi.arm64V8a),
            target('Kiosk', AndroidAbi.armeabiV7a),
          ]),
          keys: {key.keyProperties: key},
          onProgress: (p) => progress.add('${p.target} ${p.stage.name}'),
        );

        expect(results.map((r) => '${r.target} ${r.status.name}'), [
          'Phone signed',
          'Tablet signed',
          'Kiosk signed',
        ]);
        // Phone and Tablet share the arm64-v8a signing.
        final signs = runner.callsWithFirstArg('sign').toList();
        expect(signs.map((c) => p.basename(c.arguments.last)), [
          'app-release-arm64-v8a.apk',
          'app-release-armeabi-v7a.apk',
        ]);
        expect(signs.first.environment[keystorePasswordVariable], 'hunter2');
        expect(signs.first.environment[keyPasswordVariable], 'hunter3');
        final phone = File(results.first.outputPath!);
        expect(
          phone.path,
          p.join(temp.path, 'out', 'phone', 'app-release-Phone.apk'),
        );
        expect(phone.readAsStringSync(), 'signed app-release-arm64-v8a.apk');
        expect(
          File(results[1].outputPath!).readAsStringSync(),
          phone.readAsStringSync(),
        );
        expect(results.first.signerSha256, testKeySha);
        expect(results.first.sizeBytes, phone.lengthSync());
        expect(
          progress,
          containsAllInOrder([
            'Phone splitting',
            'Phone signing',
            'Phone writing',
            'Phone finished',
          ]),
        );
        expect(leftovers(), isEmpty);
        expect(log.lines.join('\n'), isNot(contains('hunter')));
        // The input is never touched.
        expect(input.path, endsWith('app-release.apk'));
        expect(File(input.path).lengthSync(), input.sizeBytes);
      },
    );

    test('each result says how its target was signed and what apksigner '
        'verified, and holds no password', () async {
      // The key that signed the fixture's APK.
      const schemesKey = OpenedKey(
        keyProperties: '/keys/key.properties',
        keystorePath: '/keys/release.jks',
        alias: 'upload',
        storePassword: 'hunter2',
        keyPassword: 'hunter3',
        sha256:
            'b8679d21059e8cb277c82ad59d5325bc8efc1d1a726313d762c3461f16022b8c',
      );
      // apksigner writes a v1-signed copy of what it signs, and its .idsig.
      runner
        ..when((c) => c.arguments.first == 'sign', (c) {
          final out = c.arguments[c.arguments.indexOf('--out') + 1];
          final archive = Archive()
            ..add(ArchiveFile.string('AndroidManifest.xml', 'manifest'))
            ..add(ArchiveFile.string('META-INF/MANIFEST.MF', 'jar'))
            ..add(ArchiveFile.string('META-INF/UPLOAD.RSA', 'block'))
            ..add(ArchiveFile.string('from', p.basename(c.arguments.last)));
          File(out).writeAsBytesSync(ZipEncoder().encode(archive));
          File('$out.idsig').writeAsStringSync('v4');
          return ok();
        })
        ..whenFirstArg(
          'verify',
          ok(fixture('apksigner_verify_all_schemes.txt')),
        );
      const defaults = SigningSchemes(v2: true, v3: true);
      const own = SigningSchemes(v1: true, v2: true, v3: true, v4: true);
      final input = await universal();

      final results = await service().run(
        executor,
        toolchain: _toolchain,
        plan: plan(input, [
          target('Phone', AndroidAbi.arm64V8a),
          target('Tablet', AndroidAbi.arm64V8a),
          target('Kiosk', AndroidAbi.armeabiV7a, schemes: own),
          target('Emulator', AndroidAbi.x8664),
        ], defaults: defaults),
        keys: {schemesKey.keyProperties: schemesKey},
      );

      final [emulator, phone, tablet, kiosk] = results;
      expect(phone.setup!.abi, 'arm64-v8a');
      expect(phone.setup!.cut, isTrue);
      expect(phone.setup!.keyProperties, '/keys/key.properties');
      expect(phone.setup!.keyAlias, 'upload');
      expect(phone.setup!.schemes, defaults);
      expect(phone.setup!.schemesFromDefaults, isTrue);
      expect(phone.setup!.copiedFrom, isNull);
      expect(tablet.setup!.copiedFrom, 'Phone');
      expect(kiosk.setup!.schemes, own);
      expect(kiosk.setup!.schemesFromDefaults, isFalse);
      expect(emulator.status, TargetStatus.skipped);
      expect(emulator.setup!.abi, 'x86_64');
      expect(emulator.setup!.schemes, defaults);

      // apksigner doesn't check v1 from minSdk 24; the files say it's there.
      expect(phone.verifiedSchemes, {
        'v1': false,
        'v2': true,
        'v3': true,
        'v3.1': false,
        'v4': true,
      });
      expect(phone.hasJarSignature, isTrue);
      expect(
        phone.signerDistinguishedName,
        'CN=APK Forge Schemes, O=Example, C=US',
      );
      expect(phone.outputSha256, (await fileDigests(phone.outputPath!)).sha256);
      expect(tablet.outputSha256, phone.outputSha256);
      expect(kiosk.outputSha256, isNot(phone.outputSha256));
      expect(File('${kiosk.outputPath}.idsig').existsSync(), isTrue);

      final saved = jsonEncode([for (final result in results) result.toJson()]);
      expect(saved, isNot(contains('hunter')));
    });

    test('a failed target does not stop the others', () async {
      // The first matching answer wins: Kiosk's signing fails.
      runner.when(
        (c) =>
            c.arguments.first == 'sign' &&
            c.arguments.last.endsWith('armeabi-v7a.apk'),
        (_) => failed(1, stderr: ['Failed to load signer "signer #1"']),
      );
      answerSigning();
      // Tablet's folder can't be made: a file is in the way.
      final input = await universal();
      final blocked = target('Tablet', AndroidAbi.arm64V8a);
      File(blocked.outputDir)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('not a folder');

      final results = await service().run(
        executor,
        toolchain: _toolchain,
        plan: plan(input, [
          target('Phone', AndroidAbi.arm64V8a),
          blocked,
          target('Kiosk', AndroidAbi.armeabiV7a),
        ]),
        keys: {key.keyProperties: key},
      );

      expect(results.map((r) => '${r.target} ${r.status.name}'), [
        'Phone signed',
        'Tablet failed',
        'Kiosk failed',
      ]);
      expect(results[1].reason, startsWith('Could not write'));
      expect(results[2].reason, startsWith('Signing failed'));
      expect(leftovers(), isEmpty);
    });

    test('skipped targets are listed with the reason', () async {
      answerSigning();
      final input = await universal();

      final results = await service().run(
        executor,
        toolchain: _toolchain,
        plan: plan(input, [
          target('Phone', AndroidAbi.arm64V8a),
          target('Emulator', AndroidAbi.x8664),
        ]),
        keys: {key.keyProperties: key},
      );

      expect(results.first.target, 'Emulator');
      expect(results.first.status, TargetStatus.skipped);
      expect(results.first.reason, 'No native code for x86_64');
      expect(results.last.status, TargetStatus.signed);
    });

    test('cancelled: what did not run is skipped, nothing partial', () async {
      answerSigning();
      final input = await universal();
      final cancelled = ToolExecutor(
        runner,
        log,
        cancelToken: CancelToken()..cancel(),
      );

      final results = await service().run(
        cancelled,
        toolchain: _toolchain,
        plan: plan(input, [target('Phone', AndroidAbi.arm64V8a)]),
        keys: {key.keyProperties: key},
      );

      expect(results.single.status, TargetStatus.skipped);
      expect(results.single.reason, 'Cancelled before it ran');
      expect(runner.calls, isEmpty);
      expect(leftovers(), isEmpty);
    });
  });

  group('InstalledApkService', () {
    InstalledApkService service() =>
        InstalledApkService(host: macHost, temporaryDirectory: () => temp);

    List<int> zip(List<String> entries) {
      final archive = Archive();
      for (final entry in entries) {
        archive.add(ArchiveFile.string(entry, 'content of $entry'));
      }
      return ZipEncoder().encode(archive);
    }

    bool isPmPath(Command c) =>
        c.arguments.contains('pm') && c.arguments.contains('path');
    bool isPull(Command c) =>
        c.arguments.length > 2 && c.arguments[2] == 'pull';

    /// adb pull writes each file from [files] (by name) where it's asked to;
    /// a name in [failing] fails as adb does for a missing file.
    void answerPulls(
      Map<String, List<String>> files, {
      Set<String> failing = const {},
    }) => runner.when(isPull, (c) {
      final remote = c.arguments[3];
      final name = p.posix.basename(remote);
      if (failing.contains(name)) {
        return failed(
          1,
          stderr: [
            "adb: error: failed to stat remote object '$remote': "
                'No such file or directory',
          ],
        );
      }
      File(c.arguments[4]).writeAsBytesSync(zip(files[name]!));
      return ok();
    });

    Iterable<String> copies() => temp
        .listSync()
        .map((entity) => p.basename(entity.path))
        .where((name) => name.startsWith('apk_forge_installed_'));

    Future<InstalledApk?> read(String package) => service().read(
      executor,
      toolchain: _toolchain,
      serial: 'SER1',
      package: package,
    );

    test('a single-APK install is copied, read, then deleted', () async {
      runner.when(isPmPath, (_) => ok(fixture('adb_pm_path_single.txt')));
      answerPulls({
        'base.apk': ['AndroidManifest.xml', 'classes.dex'],
      });

      final installed = await read('com.google.android.apps.meetings');

      final pulls = runner.calls.where(isPull).toList();
      expect(pulls, hasLength(1));
      expect(pulls.single.arguments.take(3), ['-s', 'SER1', 'pull']);
      expect(pulls.single.arguments[3], endsWith('/base.apk'));
      expect(installed!.files.isSplit, isFalse);
      expect(installed.report.contents.nativeLibraries, isEmpty);
      // The report was read from the copy, before it was deleted.
      expect(runner.callsWithFirstArg('dump'), hasLength(1));
      expect(copies(), isEmpty);
    });

    test('an App Bundle install: the native code of its ABI split, and the '
        'density split left on the device', () async {
      runner.when(isPmPath, (_) => ok(fixture('adb_pm_path_bundle.txt')));
      answerPulls({
        'base.apk': ['AndroidManifest.xml', 'classes.dex'],
        'split_config.arm64_v8a.apk': [
          'AndroidManifest.xml',
          'lib/arm64-v8a/libapp.so',
          'lib/arm64-v8a/libflutter.so',
        ],
      });

      final installed = await read('com.github.android');

      expect(
        runner.calls.where(isPull).map((c) => p.posix.basename(c.arguments[3])),
        ['base.apk', 'split_config.arm64_v8a.apk'],
      );
      final report = installed!.report;
      expect(installed.files.isSplit, isTrue);
      expect(installed.files.notPulledNames, 'split_config.xhdpi.apk');
      expect(report.contents.nativeLibraries, {
        'arm64-v8a': ['libapp.so', 'libflutter.so'],
      });
      expect(report.contentsError, isNull);
      expect(
        report.sizeBytes,
        zip(['AndroidManifest.xml', 'classes.dex']).length +
            zip([
              'AndroidManifest.xml',
              'lib/arm64-v8a/libapp.so',
              'lib/arm64-v8a/libflutter.so',
            ]).length,
      );
      expect(copies(), isEmpty);
    });

    test('a package that is not installed: null, and nothing copied', () async {
      runner.when(isPmPath, (_) => failed(1));

      expect(await read('com.example.app'), isNull);
      expect(runner.calls.where(isPull), isEmpty);
      expect(copies(), isEmpty);
    });

    test('a base that cannot be copied fails, and nothing is left', () async {
      runner.when(isPmPath, (_) => ok(fixture('adb_pm_path_single.txt')));
      answerPulls(const {}, failing: {'base.apk'});

      await expectLater(
        read('com.google.android.apps.meetings'),
        throwsA(
          isA<ToolFailure>()
              .having(
                (f) => f.title,
                'title',
                'Could not copy com.google.android.apps.meetings from the '
                    'device',
              )
              .having(
                (f) => f.details.join('\n'),
                'details',
                contains('failed to stat remote object'),
              ),
        ),
      );
      expect(copies(), isEmpty);
    });

    test(
      'an ABI split that cannot be copied leaves the native code unread',
      () async {
        runner.when(isPmPath, (_) => ok(fixture('adb_pm_path_bundle.txt')));
        answerPulls(
          {
            'base.apk': ['AndroidManifest.xml', 'classes.dex'],
          },
          failing: {'split_config.arm64_v8a.apk'},
        );

        final installed = await read('com.github.android');

        expect(
          installed!.report.contentsError,
          startsWith('Could not copy split_config.arm64_v8a.apk: '),
        );
        expect(installed.report.contentsError, contains('No such file'));
        expect(copies(), isEmpty);
      },
    );

    test('a package name that is not one never reaches the device', () async {
      await expectLater(read('com.x; reboot'), throwsArgumentError);
      expect(runner.calls, isEmpty);
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

    group('v4', () {
      late String idsig;
      setUp(() => idsig = '$apk.idsig');

      Future<ApkReport> analyze() => const ApkAnalyzer().analyze(
        executor,
        toolchain: _toolchain,
        path: apk,
      );

      List<List<String>> verifyCalls() => [
        for (final call in runner.callsWithFirstArg('verify')) call.arguments,
      ];

      test('verify is given the .idsig next to the APK', () async {
        File(idsig).writeAsStringSync('v4');
        runner.whenFirstArg(
          'verify',
          ok(fixture('apksigner_verify_all_schemes.txt')),
        );

        final report = await analyze();

        expect(verifyCalls(), [
          [
            'verify',
            '--verbose',
            '--print-certs',
            '--v4-signature-file',
            idsig,
            apk,
          ],
        ]);
        expect(report.signature!.v4SignatureFile, idsig);
        expect(report.signature!.scheme('v4'), isTrue);
      });

      test('without an .idsig, verify reads the APK alone, as an app '
          'copied from a device', () async {
        runner.whenFirstArg(
          'verify',
          ok(fixture('apksigner_verify_test_key.txt')),
        );

        final report = await analyze();

        expect(verifyCalls(), [
          ['verify', '--verbose', '--print-certs', apk],
        ]);
        expect(report.signature!.v4SignatureFile, isNull);
        expect(report.signature!.v4Problem, isNull);
      });

      test('an .idsig that does not match keeps the verdict, and v4 says '
          'why', () async {
        File(idsig).writeAsStringSync('another APK\'s');
        runner.whenFirstArg(
          'verify',
          ok(fixture('apksigner_verify_v4_idsig_mismatch.txt')),
        );

        final report = await analyze();

        expect(verifyCalls(), hasLength(1));
        expect(report.signature!.verifies, isTrue);
        expect(report.signature!.v4Problem, contains("doesn't match"));
      });

      test('a corrupt .idsig keeps the rest of the signature, with the '
          'reason', () async {
        File(idsig).writeAsBytesSync([1, 2, 3]);
        runner
          ..when(
            (c) => c.arguments.contains('--v4-signature-file'),
            (_) => failed(
              1,
              stderr: fixture('apksigner_verify_v4_idsig_corrupt.txt'),
            ),
          )
          ..whenFirstArg(
            'verify',
            ok(fixture('apksigner_verify_test_key.txt')),
          );

        final report = await analyze();

        expect(verifyCalls(), [
          [
            'verify',
            '--verbose',
            '--print-certs',
            '--v4-signature-file',
            idsig,
            apk,
          ],
          ['verify', '--verbose', '--print-certs', apk],
        ]);
        expect(report.signatureError, isNull);
        expect(report.signature!.verifies, isTrue);
        expect(
          report.signature!.v4SignatureError,
          'Invalid signature version.',
        );
        expect(report.signature!.v4Problem, contains("couldn't be read"));
      });
    });

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
