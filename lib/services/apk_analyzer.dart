import 'dart:io';

import 'package:crypto/crypto.dart';

import '../core/process/command.dart';
import '../core/zip/zip_directory.dart';
import '../domain/analysis/apk_report.dart';
import '../domain/analysis/badging.dart';
import '../domain/analysis/signature.dart';
import '../domain/failure.dart';
import '../domain/signing/signing.dart';
import '../domain/tools/toolchain.dart';
import 'tool_executor.dart';

/// Builds an [ApkReport]: hashes and the file list in Dart, the manifest
/// with aapt2, and the signature with apksigner.
///
/// A missing tool or a tool error leaves its part empty with the reason,
/// instead of failing the whole report.
class ApkAnalyzer {
  const ApkAnalyzer();

  Future<ApkReport> analyze(
    ToolExecutor executor, {
    required Toolchain toolchain,
    required String path,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw ToolFailure('File not found', details: [path]);
    }
    final size = await file.length();
    final digests = await _digests(file);

    ApkContents contents = const ApkContents();
    String? contentsError;
    try {
      contents = ApkContents.fromEntries(await readZipDirectory(path));
    } on ZipFormatException catch (error) {
      contentsError = error.message;
    } on FileSystemException catch (error) {
      contentsError = error.message;
    }

    Badging? badging;
    String? badgingError;
    final aapt2 = toolchain.aapt2;
    if (aapt2 == null) {
      badgingError = 'aapt2 was not found (Android SDK build-tools).';
    } else {
      final result = await executor.run(
        Command(aapt2, ['dump', 'badging', path]),
        echoOutput: false,
      );
      // aapt2 can exit non-zero over one odd resource and still print the
      // manifest; only a missing `package:` line means it read nothing.
      if (result.stdout.any((line) => line.startsWith('package:'))) {
        badging = parseBadging(result.stdout);
      } else {
        badgingError = errorDetails(result).join('\n');
      }
    }

    SignatureReport? signature;
    String? signatureError;
    final apksigner = toolchain.apksigner;
    if (apksigner == null) {
      signatureError = 'apksigner was not found (Android SDK build-tools).';
    } else {
      final result = await executor.run(
        Command(apksigner, apksignerVerifyArguments(path)),
        echoOutput: false,
      );
      final parsed = parseApksignerVerify(result.allLines);
      final sawVerdict = result.allLines.any(
        (line) => line.trim() == 'Verifies' || line.trim() == 'DOES NOT VERIFY',
      );
      if (sawVerdict) {
        signature = parsed;
      } else {
        signatureError = parsed.errors.isNotEmpty
            ? parsed.errors.join('\n')
            : errorDetails(result).join('\n');
      }
    }

    return ApkReport(
      path: path,
      sizeBytes: size,
      md5: digests.md5,
      sha256: digests.sha256,
      contents: contents,
      contentsError: contentsError,
      badging: badging,
      badgingError: badgingError,
      signature: signature,
      signatureError: signatureError,
    );
  }

  /// MD5 (what TMS and store consoles show) and SHA-256, in one read.
  static Future<({String md5, String sha256})> _digests(File file) async {
    final md5Sink = _DigestSink();
    final sha256Sink = _DigestSink();
    final md5Input = md5.startChunkedConversion(md5Sink);
    final sha256Input = sha256.startChunkedConversion(sha256Sink);
    await for (final chunk in file.openRead()) {
      md5Input.add(chunk);
      sha256Input.add(chunk);
    }
    md5Input.close();
    sha256Input.close();
    return (md5: md5Sink.value.toString(), sha256: sha256Sink.value.toString());
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
