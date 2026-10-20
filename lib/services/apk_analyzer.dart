import 'dart:io';

import '../core/files/file_digests.dart';
import '../core/process/command.dart';
import '../core/process/process_runner.dart';
import '../core/zip/zip_directory.dart';
import '../domain/analysis/apk_report.dart';
import '../domain/analysis/badging.dart';
import '../domain/analysis/signature.dart';
import '../domain/failure.dart';
import '../domain/signing/signing.dart';
import '../domain/tools/toolchain.dart';
import 'tool_executor.dart';

/// Builds an [ApkReport]: hashes and the file list in Dart, the manifest
/// with aapt2, and the signature (and a v3 key rotation) with apksigner.
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
    final digests = await fileDigests(path);

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
      Future<CommandResult> verify({String? v4SignatureFile}) => executor.run(
        Command(
          apksigner,
          apksignerVerifyArguments(path, v4SignatureFile: v4SignatureFile),
        ),
        echoOutput: false,
      );

      // A v4 signature is in `<apk>.idsig`, which apksigner checks only
      // when it's given.
      final idsig = '$path.idsig';
      final hasIdsig = await File(idsig).exists();
      var result = await verify(v4SignatureFile: hasIdsig ? idsig : null);
      String? idsigError;
      if (hasIdsig && !_sawVerdict(result)) {
        // A corrupt `.idsig` stops apksigner before its verdict: the rest of
        // the signature is read without it.
        idsigError = _errorOf(result);
        result = await verify();
      }
      final parsed = parseApksignerVerify(result.allLines);
      if (_sawVerdict(result)) {
        signature = hasIdsig
            ? parsed.withV4SignatureFile(idsig, error: idsigError)
            : parsed;
        // Only v3 can carry a key rotation, and `verify` doesn't print it.
        // No lineage (exit 1, "does not contain a valid lineage") or a
        // failure leaves the report as it is.
        if (parsed.scheme('v3')) {
          final lineage = await executor.run(
            Command(apksigner, apksignerLineageArguments(path)),
            echoOutput: false,
          );
          final certificates = parseApksignerLineage(lineage.stdout);
          if (certificates.isNotEmpty) {
            signature = signature.withLineage(certificates);
          }
        }
      } else {
        signatureError = _errorOf(result);
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
}

/// Whether `apksigner verify` got as far as its verdict, instead of
/// crashing.
bool _sawVerdict(CommandResult result) => result.allLines.any(
  (line) => line.trim() == 'Verifies' || line.trim() == 'DOES NOT VERIFY',
);

/// Why `apksigner verify` gave no verdict.
String _errorOf(CommandResult result) {
  final errors = parseApksignerVerify(result.allLines).errors;
  return errors.isNotEmpty
      ? errors.join('\n')
      : errorDetails(result).join('\n');
}
