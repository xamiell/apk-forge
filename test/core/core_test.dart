import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apk_forge/core/format/format.dart';
import 'package:apk_forge/core/process/process_runner.dart';
import 'package:apk_forge/core/system/host.dart';
import 'package:apk_forge/core/system/shell_environment.dart';
import 'package:apk_forge/core/zip/zip_directory.dart';
import 'package:apk_forge/domain/failure.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fakes.dart';

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

  group('copyZipEntries', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('apk_forge_test_'));
    tearDown(() => temp.deleteSync(recursive: true));

    String write(String name, List<int> bytes) {
      final path = p.join(temp.path, name);
      File(path).writeAsBytesSync(bytes);
      return path;
    }

    Uint8List universal() => Uint8List.fromList(
      ZipEncoder().encode(
        Archive()
          ..add(
            ArchiveFile.bytes('lib/arm64-v8a/libapp.so', List.filled(300, 1))
              ..compression = CompressionType.none,
          )
          ..add(
            ArchiveFile.bytes('lib/x86_64/libapp.so', List.filled(300, 2))
              ..compression = CompressionType.none,
          )
          ..add(ArchiveFile.string('AndroidManifest.xml', 'manifest ' * 50)),
      ),
    );

    test('copies the entries it keeps exactly as they were stored', () async {
      final input = write('app.apk', universal());
      final output = p.join(temp.path, 'arm64.apk');

      final kept = await copyZipEntries(
        input,
        output,
        keep: (name) => !name.startsWith('lib/x86_64/'),
      );

      expect(kept, 2);
      final before = {
        for (final entry in await readZipDirectory(input)) entry.name: entry,
      };
      final after = await readZipDirectory(output);
      expect(after.map((e) => e.name), [
        'lib/arm64-v8a/libapp.so',
        'AndroidManifest.xml',
      ]);
      for (final entry in after) {
        expect(entry.isCompressed, before[entry.name]!.isCompressed);
        expect(entry.compressedSize, before[entry.name]!.compressedSize);
      }
      final copy = ZipDecoder().decodeBytes(
        File(output).readAsBytesSync(),
        verify: true,
      );
      expect(
        copy.findFile('lib/arm64-v8a/libapp.so')!.content,
        List.filled(300, 1),
      );
      expect(
        utf8.decode(copy.findFile('AndroidManifest.xml')!.content),
        'manifest ' * 50,
      );
    });

    test('leaves out an APK Signing Block and the comment', () async {
      final zip = ZipEncoder().encode(
        Archive()
          ..add(ArchiveFile.string('classes.dex', 'dex'))
          ..comment = 'built by CI',
      );
      final input = write(
        'signed.apk',
        _withSigningBlock(Uint8List.fromList(zip)),
      );
      final output = p.join(temp.path, 'copy.apk');
      expect((await readZipDirectory(input)).single.name, 'classes.dex');

      await copyZipEntries(input, output, keep: (_) => true);

      final bytes = File(output).readAsBytesSync();
      expect(latin1.decode(bytes), isNot(contains('APK Sig Block 42')));
      expect(latin1.decode(bytes), isNot(contains('built by CI')));
      final copy = ZipDecoder().decodeBytes(bytes, verify: true);
      expect(utf8.decode(copy.findFile('classes.dex')!.content), 'dex');
    });

    test(
      'moves a data descriptor\'s CRC and sizes into the local header',
      () async {
        final data = utf8.encode('streamed by a JAR tool');
        final input = write(
          'streamed.apk',
          _zipWithDataDescriptor('classes.dex', data),
        );
        final output = p.join(temp.path, 'copy.apk');

        await copyZipEntries(input, output, keep: (_) => true);

        final bytes = File(output).readAsBytesSync();
        final local = ByteData.sublistView(bytes);
        expect(local.getUint16(6, Endian.little) & 0x08, 0);
        expect(local.getUint32(14, Endian.little), getCrc32(data));
        expect(local.getUint32(18, Endian.little), data.length);
        expect(local.getUint32(22, Endian.little), data.length);
        // The 16-byte descriptor is gone.
        expect(bytes.length, File(input).lengthSync() - 16);
        final copy = ZipDecoder().decodeBytes(bytes, verify: true);
        expect(copy.findFile('classes.dex')!.content, data);
      },
    );

    test('a broken entry fails and leaves no output', () async {
      final zip = universal();
      final view = ByteData.sublistView(zip);
      // No comment: the end record is the last 22 bytes. The first entry now
      // claims to be longer than the whole file.
      final directory = view.getUint32(zip.length - 22 + 16, Endian.little);
      view.setUint32(directory + 20, 0x7FFFFFFF, Endian.little);
      final input = write('broken.apk', zip);
      final output = p.join(temp.path, 'copy.apk');

      await expectLater(
        copyZipEntries(input, output, keep: (_) => true),
        throwsA(isA<ZipFormatException>()),
      );
      expect(File(output).existsSync(), isFalse);
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

  test(
    'on Windows the app keeps its own environment: no shell to ask',
    () async {
      const host = Host(
        os: HostOs.windows,
        environment: {'Path': r'C:\Windows', 'USERPROFILE': r'C:\Users\dev'},
      );

      expect(await loadShellEnvironment(host), host.environment);
    },
  );

  test('only a .bat or .cmd on Windows starts through the shell', () {
    const windows = Host(os: HostOs.windows, environment: {});
    const mac = Host(os: HostOs.macos, environment: {});

    expect(startsThroughShell(windows, r'C:\flutter\bin\flutter.bat'), isTrue);
    expect(
      startsThroughShell(windows, r'C:\sdk\build-tools\36.0.0\apksigner.CMD'),
      isTrue,
    );
    expect(
      startsThroughShell(windows, r'C:\sdk\platform-tools\adb.exe'),
      isFalse,
    );
    expect(startsThroughShell(mac, '/opt/tools/flutter.bat'), isFalse);
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
    test('formatDateTime shows the moment to the minute', () {
      expect(
        formatDateTime(DateTime(2026, 3, 7, 9, 5, 59)),
        '2026-03-07 09:05',
      );
    });

    test('shortPath keeps the file and its folder', () {
      expect(
        shortPath('/a/long/way/out/phone/app.apk', macHost),
        '…/phone/app.apk',
      );
      expect(shortPath('/out/app.apk', macHost), '/out/app.apk');
      const windows = Host(os: HostOs.windows, environment: {});
      expect(
        shortPath(r'C:\work\out\kiosk\app.apk', windows),
        r'…\kiosk\app.apk',
      );
    });

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

/// [zip] with a stand-in APK Signing Block between its entries and its
/// central directory, where apksigner puts the real one.
Uint8List _withSigningBlock(Uint8List zip) {
  final view = ByteData.sublistView(zip);
  var end = zip.length - 22;
  while (view.getUint32(end, Endian.little) != 0x06054b50) {
    end--;
  }
  final directory = view.getUint32(end + 16, Endian.little);
  final block = BytesBuilder()
    ..add(Uint8List(8))
    ..add(utf8.encode('stand-in signature'))
    ..add(Uint8List(8))
    ..add(utf8.encode('APK Sig Block 42'));
  final blockBytes = block.takeBytes();
  final signed = Uint8List.fromList([
    ...zip.sublist(0, directory),
    ...blockBytes,
    ...zip.sublist(directory),
  ]);
  ByteData.sublistView(signed).setUint32(
    end + blockBytes.length + 16,
    directory + blockBytes.length,
    Endian.little,
  );
  return signed;
}

/// A ZIP with one stored entry whose CRC and sizes come after its data, in
/// a data descriptor, as streaming writers (`jar`, Java's ZipOutputStream)
/// write them.
Uint8List _zipWithDataDescriptor(String name, List<int> data) {
  final nameBytes = utf8.encode(name);
  final crc = getCrc32(data);
  final zip = BytesBuilder()
    ..add(
      (ByteData(30)
            ..setUint32(0, 0x04034b50, Endian.little)
            ..setUint16(4, 20, Endian.little)
            ..setUint16(6, 0x08, Endian.little)
            ..setUint16(26, nameBytes.length, Endian.little))
          .buffer
          .asUint8List(),
    )
    ..add(nameBytes)
    ..add(data)
    ..add(
      (ByteData(16)
            ..setUint32(0, 0x08074b50, Endian.little)
            ..setUint32(4, crc, Endian.little)
            ..setUint32(8, data.length, Endian.little)
            ..setUint32(12, data.length, Endian.little))
          .buffer
          .asUint8List(),
    );
  final directory = zip.length;
  zip
    ..add(
      (ByteData(46)
            ..setUint32(0, 0x02014b50, Endian.little)
            ..setUint16(4, 20, Endian.little)
            ..setUint16(6, 20, Endian.little)
            ..setUint16(8, 0x08, Endian.little)
            ..setUint32(16, crc, Endian.little)
            ..setUint32(20, data.length, Endian.little)
            ..setUint32(24, data.length, Endian.little)
            ..setUint16(28, nameBytes.length, Endian.little))
          .buffer
          .asUint8List(),
    )
    ..add(nameBytes)
    ..add(
      (ByteData(22)
            ..setUint32(0, 0x06054b50, Endian.little)
            ..setUint16(8, 1, Endian.little)
            ..setUint16(10, 1, Endian.little)
            ..setUint32(12, 46 + nameBytes.length, Endian.little)
            ..setUint32(16, directory, Endian.little))
          .buffer
          .asUint8List(),
    );
  return zip.takeBytes();
}
