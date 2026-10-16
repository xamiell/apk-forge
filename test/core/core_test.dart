import 'dart:io';

import 'package:apk_forge/core/format/format.dart';
import 'package:apk_forge/core/process/process_runner.dart';
import 'package:apk_forge/core/system/shell_environment.dart';
import 'package:apk_forge/core/zip/zip_directory.dart';
import 'package:apk_forge/domain/failure.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('readZipDirectory', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('apk_forge_test_'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('lists the entries with their sizes and compression', () async {
      final archive = Archive()
        ..add(
          ArchiveFile.bytes('lib/arm64-v8a/libapp.so', List.filled(300, 7))
            ..compression = CompressionType.none,
        )
        ..add(ArchiveFile.string('AndroidManifest.xml', 'x' * 500));
      final path = p.join(temp.path, 'app.apk');
      File(path).writeAsBytesSync(ZipEncoder().encode(archive));

      final entries = await readZipDirectory(path);

      expect(entries.map((e) => e.name), [
        'lib/arm64-v8a/libapp.so',
        'AndroidManifest.xml',
      ]);
      expect(entries.first.uncompressedSize, 300);
      expect(entries.first.isCompressed, isFalse);
      expect(entries.last.isCompressed, isTrue);
      expect(entries.last.compressedSize, lessThan(500));
    });

    test('finds the directory behind a ZIP comment', () async {
      final archive = Archive()
        ..add(ArchiveFile.string('a.txt', 'a'))
        ..comment = 'c' * 1000;
      final path = p.join(temp.path, 'commented.apk');
      File(path).writeAsBytesSync(ZipEncoder().encode(archive));

      expect((await readZipDirectory(path)).single.name, 'a.txt');
    });

    test('rejects a file that is not a ZIP', () async {
      final path = p.join(temp.path, 'junk.apk');
      File(path).writeAsBytesSync(List.generate(200, (i) => i % 251));

      await expectLater(
        readZipDirectory(path),
        throwsA(isA<ZipFormatException>()),
      );
    });
  });

  test('parseEnvOutput keeps only the lines between the markers', () {
    const output =
        'Welcome to zsh!\n'
        '__APK_FORGE_ENV_START__\n'
        'PATH=/opt/flutter/bin:/usr/bin\n'
        'JAVA_HOME=/jdk\n'
        'EMPTY=\n'
        '__APK_FORGE_ENV_END__\n'
        'bye\n';

    expect(parseEnvOutput(output), {
      'PATH': '/opt/flutter/bin:/usr/bin',
      'JAVA_HOME': '/jdk',
      'EMPTY': '',
    });
    expect(parseEnvOutput('no markers'), isEmpty);
  });

  group('errorDetails', () {
    test('takes Gradle\'s "What went wrong" block without the advice', () {
      const result = CommandResult(
        exitCode: 1,
        stdout: [
          'FAILURE: Build failed with an exception.',
          '',
          '* What went wrong:',
          'Execution failed for task \':app:mergeReleaseNativeLibs\'.',
          '> Conflicting configuration : \'armeabi-v7a\' in ndk abiFilters cannot be present when splits abi filters are set',
          '',
          '* Try:',
          '> Run with --stacktrace option to get the stack trace.',
        ],
      );

      expect(errorDetails(result), [
        'Execution failed for task \':app:mergeReleaseNativeLibs\'.',
        '> Conflicting configuration : \'armeabi-v7a\' in ndk abiFilters cannot be present when splits abi filters are set',
      ]);
    });

    test('takes error-looking lines and the line after each', () {
      const result = CommandResult(
        exitCode: 1,
        stderr: [
          'Failed to load signer "signer #1"',
          'java.io.IOException: Keystore was tampered with, or password was incorrect',
          '\tat java.base/…',
        ],
      );

      expect(errorDetails(result), [
        'Failed to load signer "signer #1"',
        'java.io.IOException: Keystore was tampered with, or password was incorrect',
      ]);
    });

    test('otherwise the last lines', () {
      final result = CommandResult(
        exitCode: 2,
        stdout: [for (var i = 0; i < 30; i++) 'line $i'],
      );

      expect(errorDetails(result), hasLength(15));
      expect(errorDetails(result).last, 'line 29');
    });

    test(
      'ToolFailure.fromResult masks the secrets and names the exit code',
      () {
        const result = CommandResult(
          exitCode: 1,
          stderr: ['Error: bad password hunter2'],
        );
        final failure = ToolFailure.fromResult(
          'Signing failed',
          result,
          secrets: ['hunter2'],
        );

        expect(failure.title, 'Signing failed (exit code 1)');
        expect(failure.details, ['Error: bad password ••••']);
      },
    );
  });

  group('format', () {
    test('formatBytes', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(15728640), '15.0 MB');
    });

    test('digests compare and print in either form', () {
      expect(normalizeDigest('B3:4C:94'), 'b34c94');
      expect(colonDigest('b34c94'), 'B3:4C:94');
      expect(
        shortDigest(
          'b34c9445c5e411b045884f499034b5592ab109ec5cd1ca9cb584e54f582dcfa8',
        ),
        'B3:4C:94:45…58:2D:CF:A8',
      );
    });
  });
}
