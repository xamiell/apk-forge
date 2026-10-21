import 'dart:io';

import '../core/format/format.dart';
import '../core/process/command.dart';
import '../core/system/host.dart';
import '../core/zip/zip_directory.dart';
import '../domain/failure.dart';
import '../domain/signing/abi_split.dart';
import '../domain/signing/bundle.dart';
import '../domain/signing/signing.dart';
import '../domain/tools/toolchain.dart';
import 'tool_executor.dart';

/// The outcome of signing one App Bundle.
class SignedBundle {
  const SignedBundle({required this.path, required this.signer});

  final String path;
  final JarSigner signer;
}

/// Signs an Android App Bundle with jarsigner, which is how a bundle is
/// signed: apksigner can't read one.
class BundleSigningService {
  const BundleSigningService({required this.host, this.temporaryDirectory});

  final Host host;

  /// Where the copy without the old signature is written. The system's by
  /// default.
  final Directory Function()? temporaryDirectory;

  /// Signs a copy of [input] that has no JAR signature, then checks that it
  /// verifies and carries one signer only. [expectedSha256] is the selected
  /// key's certificate digest: the signer must be that one, or this throws.
  ///
  /// The signed bundle goes to `<name>-signed.aab` (`signedFilePath`)
  /// through a `.partial` file, so a failure leaves an earlier one intact.
  Future<SignedBundle> sign(
    ToolExecutor executor, {
    required Toolchain toolchain,
    required String input,
    required SigningRequest request,
    String? expectedSha256,
  }) async {
    final jarsigner = toolchain.jarsigner;
    if (jarsigner == null) throw jarsignerMissing;
    final keytool = toolchain.keytool;
    if (keytool == null) throw keytoolMissing;

    final output = signedFilePath(input, request.outputDir, host);
    await Directory(host.path.dirname(output)).create(recursive: true);
    final partial = '$output.partial';
    final temporary = await (temporaryDirectory?.call() ?? Directory.systemTemp)
        .createTemp('apk_forge_bundle_');

    try {
      // Flutter's bundle is already signed, with the debug key. Signed again
      // on top of that, it no longer verifies: the old signature goes first.
      final unsigned = host.path.join(
        temporary.path,
        host.path.basename(input),
      );
      await copyZipEntries(
        input,
        unsigned,
        keep: (name) => !isJarSignatureFile(name),
      );

      executor.log.info('Signing with key “${request.alias}” → $output');
      final result = await executor.run(
        Command(
          jarsigner,
          jarsignerSignArguments(request, input: unsigned, output: partial),
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

      final verify = await executor.run(
        Command(jarsigner, jarsignerVerifyArguments(partial)),
        echoOutput: false,
      );
      final verification = parseJarsignerVerify(verify.allLines);
      if (verification.verdict != JarVerdict.verified) {
        throw ToolFailure(
          'The signed bundle does not verify',
          details: [
            verification.reason ??
                (verification.verdict == JarVerdict.unsigned
                    ? 'jarsigner finds no signature.'
                    : 'jarsigner gave no reason.'),
          ],
        );
      }

      final certificates = await executor.run(
        Command(keytool, keytoolPrintJarCertificatesArguments(partial)),
        echoOutput: false,
      );
      final signers = parseJarSigners(certificates.allLines);
      if (signers.length != 1) {
        throw ToolFailure(
          'The signed bundle has ${signers.length} signers',
          details: const ['It must carry only the key in Sign.'],
        );
      }
      final signer = signers.single;
      if (expectedSha256 != null && signer.sha256 != expectedSha256) {
        throw ToolFailure(
          'The signed bundle has another signer',
          details: [
            'Expected SHA-256 ${colonDigest(expectedSha256)}',
            'Found    SHA-256 ${signer.sha256 == null ? 'none' : colonDigest(signer.sha256!)}',
          ],
        );
      }

      await File(partial).rename(output);
      executor.log.success(
        'Signed and verified: ${host.path.basename(output)} (JAR signature; '
        'SHA-256 ${signer.sha256 == null ? '?' : shortDigest(signer.sha256!)})',
      );
      return SignedBundle(path: output, signer: signer);
    } finally {
      final leftover = File(partial);
      if (await leftover.exists()) await leftover.delete();
      await temporary.delete(recursive: true);
    }
  }
}
