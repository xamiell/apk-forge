import 'dart:io';

import '../core/format/format.dart';
import '../core/process/command.dart';
import '../core/system/host.dart';
import '../domain/analysis/signature.dart';
import '../domain/failure.dart';
import '../domain/signing/keystore.dart';
import '../domain/signing/signing.dart';
import '../domain/tools/toolchain.dart';
import 'tool_executor.dart';

class KeystoreService {
  const KeystoreService();

  /// The keys in [keystorePath], read with keytool.
  Future<List<KeystoreEntry>> listEntries(
    ToolExecutor executor, {
    required String keytool,
    required String keystorePath,
    required String password,
  }) async {
    final command = Command(
      keytool,
      keytoolListArguments(keystorePath),
      environment: {keystorePasswordVariable: password},
      secrets: [password],
    );
    // Not echoed: `-v` prints whole certificates. A summary follows instead.
    final result = await executor.run(command, echoOutput: false);
    if (!result.succeeded) {
      throw ToolFailure.fromResult(
        'Could not open the keystore',
        result,
        secrets: [password],
      );
    }
    final entries = parseKeytoolList(result.allLines);
    if (entries.isEmpty) {
      throw const ToolFailure('The keystore has no keys');
    }
    return entries;
  }
}

/// The outcome of signing one APK.
class SignedApk {
  const SignedApk({
    required this.path,
    required this.signer,
    this.verifiedSchemes = const {},
  });

  final String path;
  final SignerCertificate? signer;

  /// What `apksigner verify` said of each scheme (`v2` → true). See
  /// [SignatureReport.schemes] for why v1 can be false while it's there.
  final Map<String, bool> verifiedSchemes;
}

class ApkSigningService {
  const ApkSigningService({required this.host, this.temporaryDirectory});

  final Host host;

  /// Where an aligned copy is written before signing. The system's by
  /// default.
  final Directory Function()? temporaryDirectory;

  /// Aligns [input] if it needs it, signs a copy, then verifies that copy.
  ///
  /// [expectedSha256] is the selected key's certificate digest: the signed
  /// APK must carry exactly that signer, or this throws.
  Future<SignedApk> sign(
    ToolExecutor executor, {
    required Toolchain toolchain,
    required String input,
    required SigningRequest request,
    String? expectedSha256,
  }) async {
    final apksigner = toolchain.apksigner;
    if (apksigner == null) {
      throw const ToolFailure(
        'apksigner was not found',
        details: ['Install the Android SDK build-tools.'],
      );
    }
    final output = signedApkPath(input, request.outputDir, host);
    await Directory(host.path.dirname(output)).create(recursive: true);
    // apksigner writes here; only a copy that verifies replaces [output]. A
    // failed signing over an earlier `-signed.apk` must not leave half a file.
    final partial = '$output.partial';

    try {
      final toSign = await _alignedSource(executor, toolchain, input);
      try {
        executor.log.info('Signing with key “${request.alias}” → $output');
        final result = await executor.run(
          Command(
            apksigner,
            apksignerSignArguments(request, input: toSign, output: partial),
            environment: request.environment,
            secrets: request.secrets,
          ),
        );
        if (!result.succeeded) {
          final key = result.cancelled
              ? null
              : parseKeyLoadFailure(result.allLines);
          if (key != null) throw ToolFailure(key.problem, details: [key.fix]);
          throw ToolFailure.fromResult(
            'Signing failed',
            result,
            secrets: request.secrets,
          );
        }
      } finally {
        if (toSign != input) {
          await File(toSign).parent.delete(recursive: true);
        }
      }

      final idsig = '$partial.idsig';
      final verify = await executor.run(
        Command(
          apksigner,
          apksignerVerifyArguments(
            partial,
            v4SignatureFile: await File(idsig).exists() ? idsig : null,
          ),
        ),
        echoOutput: false,
      );
      final report = parseApksignerVerify(verify.allLines);
      if (!report.verifies) {
        throw ToolFailure(
          'The signed APK does not verify',
          details: report.errors.isEmpty ? errorDetails(verify) : report.errors,
        );
      }
      final signer = report.signers.isEmpty ? null : report.signers.first;
      if (expectedSha256 != null && signer?.sha256 != expectedSha256) {
        throw ToolFailure(
          'The signed APK has another signer',
          details: [
            'Expected SHA-256 ${colonDigest(expectedSha256)}',
            'Found    SHA-256 ${signer?.sha256 == null ? 'none' : colonDigest(signer!.sha256!)}',
          ],
        );
      }

      await _replace(partial, output);
      // v4 writes its signature next to the APK, named after it.
      await _replace(idsig, '$output.idsig');

      final schemes = report.schemes.entries
          .where((entry) => entry.value)
          .map((entry) => entry.key)
          .join(', ');
      executor.log.success(
        'Signed and verified: ${host.path.basename(output)} '
        '(schemes: ${schemes.isEmpty ? 'none' : schemes}; '
        'SHA-256 ${signer?.sha256 == null ? '?' : shortDigest(signer!.sha256!)})',
      );
      return SignedApk(
        path: output,
        signer: signer,
        verifiedSchemes: report.schemes,
      );
    } finally {
      for (final leftover in [partial, '$partial.idsig']) {
        final file = File(leftover);
        if (await file.exists()) await file.delete();
      }
    }
  }

  /// Moves [from] over [to] when [from] exists.
  static Future<void> _replace(String from, String to) async {
    final file = File(from);
    if (await file.exists()) await file.rename(to);
  }

  /// [input] when it's already aligned, otherwise an aligned temporary copy.
  ///
  /// Gradle's APKs are aligned. One that was edited (or re-zipped) isn't, and
  /// an APK with targetSdk 30+ and an unaligned resources.arsc won't install.
  Future<String> _alignedSource(
    ToolExecutor executor,
    Toolchain toolchain,
    String input,
  ) async {
    final zipalign = toolchain.zipalign;
    if (zipalign == null) {
      executor.log.warning(
        'zipalign not found: signing without checking the alignment.',
      );
      return input;
    }
    final pageSize = toolchain.zipalignSupportsPageSize;
    final check = await executor.run(
      Command(zipalign, zipalignArguments(input, supportsPageSize: pageSize)),
      echoOutput: false,
    );
    if (check.succeeded) {
      executor.log.info('Alignment OK.');
      return input;
    }

    executor.log.info('Not aligned: writing an aligned copy first.');
    final directory = await (temporaryDirectory?.call() ?? Directory.systemTemp)
        .createTemp('apk_forge_');
    final aligned = host.path.join(directory.path, host.path.basename(input));
    final align = await executor.run(
      Command(
        zipalign,
        zipalignArguments(input, output: aligned, supportsPageSize: pageSize),
      ),
      echoOutput: false,
    );
    if (!align.succeeded) {
      await directory.delete(recursive: true);
      throw ToolFailure.fromResult('zipalign failed', align);
    }
    return aligned;
  }
}
