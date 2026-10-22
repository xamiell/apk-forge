import 'dart:io';

import '../core/files/file_digests.dart';
import '../core/format/format.dart';
import '../core/process/command.dart';
import '../core/system/host.dart';
import '../core/zip/zip_directory.dart';
import '../domain/analysis/apk_report.dart';
import '../domain/failure.dart';
import '../domain/profiles/key_properties.dart';
import '../domain/profiles/profile.dart';
import '../domain/profiles/profile_plan.dart';
import '../domain/profiles/profile_run.dart';
import '../domain/signing/abi_split.dart';
import '../domain/signing/keystore.dart';
import '../domain/signing/signing.dart';
import '../domain/tools/toolchain.dart';
import 'signing_service.dart';
import 'tool_executor.dart';

/// A key opened for one run, from its `key.properties`. It holds the
/// passwords, in memory only; [toString] leaves them out.
class OpenedKey {
  const OpenedKey({
    required this.keyProperties,
    required this.keystorePath,
    required this.alias,
    required this.storePassword,
    required this.keyPassword,
    this.sha256,
  });

  /// The `key.properties` it was read from.
  final String keyProperties;
  final String keystorePath;
  final String alias;
  final String storePassword;
  final String keyPassword;

  /// The certificate's SHA-256, to check each signed APK against.
  final String? sha256;

  List<String> get secrets => [storePassword, keyPassword];

  SigningRequest request({
    required SigningSchemes schemes,
    required String outputDir,
  }) => SigningRequest(
    keystorePath: keystorePath,
    storePassword: storePassword,
    alias: alias,
    keyPassword: keyPassword,
    schemes: schemes,
    outputDir: outputDir,
  );

  @override
  String toString() => 'OpenedKey($keyProperties: $alias in $keystorePath)';
}

/// Opens the keys of a profile's `key.properties` files, before anything is
/// signed.
class ProfileKeyService {
  const ProfileKeyService({
    required this.host,
    this.keystores = const KeystoreService(),
  });

  final Host host;
  final KeystoreService keystores;

  /// What the editor shows about the `key.properties` at [path]. No keytool
  /// runs, and the passwords aren't kept.
  Future<KeyFileSummary> summarize(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return KeyFileSummary(path: path, error: 'The file does not exist.');
    }
    try {
      return summarizeKeyProperties(
        path,
        await file.readAsString(),
        host,
        (path) => File(path).existsSync(),
      );
    } on FileSystemException catch (error) {
      return KeyFileSummary(path: path, error: error.message);
    }
  }

  /// Reads each file, finds its keystore, and opens its key with both
  /// passwords. Fails at the first one that doesn't open, naming the file
  /// and the reason: a run must not sign with some keys and not others.
  Future<Map<String, OpenedKey>> open(
    ToolExecutor executor, {
    required String keytool,
    required List<String> keyFiles,
  }) async {
    final opened = <String, OpenedKey>{};
    for (final path in keyFiles) {
      opened[path] = await _open(executor, keytool, path);
      executor.log.info(
        '$path: key "${opened[path]!.alias}" opens'
        '${opened[path]!.sha256 == null ? '' : ' (SHA-256 ${shortDigest(opened[path]!.sha256!)})'}.',
      );
    }
    return opened;
  }

  Future<OpenedKey> _open(
    ToolExecutor executor,
    String keytool,
    String path,
  ) async {
    ToolFailure cannot(String reason, [List<String> more = const []]) =>
        ToolFailure('Cannot open the key in $path', details: [reason, ...more]);

    final file = File(path);
    if (!await file.exists()) throw cannot('The file does not exist.');
    final KeyProperties keys;
    try {
      keys = parseKeyProperties(await file.readAsString());
    } on FileSystemException catch (error) {
      throw cannot(error.message);
    }
    if (keys.missing.isNotEmpty) {
      throw cannot('It has no ${keys.missing.join(', ')}.');
    }
    final keystore = resolveStoreFile(path, keys.storeFile!.trim(), host);
    if (!await File(keystore).exists()) {
      throw cannot('The keystore $keystore (its storeFile) does not exist.');
    }
    final alias = keys.keyAlias!.trim();

    // The keystore password, the alias, and the certificate to check the
    // signed APKs against.
    final List<KeystoreEntry> entries;
    try {
      entries = await keystores.listEntries(
        executor,
        keytool: keytool,
        keystorePath: keystore,
        password: keys.storePassword!,
      );
    } on ToolFailure catch (failure) {
      throw cannot(failure.title, failure.details);
    }
    KeystoreEntry? entry;
    for (final candidate in entries) {
      if (candidate.alias == alias) entry = candidate;
    }
    if (entry == null) {
      throw cannot('The keystore has no key "$alias" (its keyAlias).');
    }
    if (!entry.canSign) {
      throw cannot('"$alias" is a certificate only: it can\'t sign.');
    }

    // The key password, which -list doesn't check.
    final result = await executor.run(
      Command(
        keytool,
        keytoolCertreqArguments(keystore, alias),
        environment: {
          keystorePasswordVariable: keys.storePassword!,
          keyPasswordVariable: keys.keyPassword!,
        },
        secrets: keys.secrets,
      ),
      echoOutput: false,
    );
    final failure = parseKeyOpenFailure(result.allLines);
    if (failure != null) throw cannot(failure);

    return OpenedKey(
      keyProperties: path,
      keystorePath: keystore,
      alias: alias,
      storePassword: keys.storePassword!,
      keyPassword: keys.keyPassword!,
      sha256: entry.sha256,
    );
  }
}

/// Runs a planned profile: cuts each input to its ABI, signs it with its
/// key, and writes it to every target that shares that signing.
class ProfileRunner {
  const ProfileRunner({
    required this.host,
    required this.signing,
    this.temporaryDirectory,
  });

  final Host host;
  final ApkSigningService signing;

  /// Where the splits and the signed copies are made. The system's by
  /// default.
  final Directory Function()? temporaryDirectory;

  /// One result per target and input. A failed target doesn't stop the
  /// others; cancelling stops before the next step, and the targets that
  /// didn't run are skipped. Nothing partial is left behind.
  Future<List<TargetResult>> run(
    ToolExecutor executor, {
    required Toolchain toolchain,
    required ProfileRunPlan plan,
    required Map<String, OpenedKey> keys,
    void Function(TargetProgress progress)? onProgress,
  }) async {
    final results = <TargetResult>[];
    void finish(TargetResult result) {
      results.add(result);
      onProgress?.call(
        TargetProgress(
          target: result.target,
          input: result.input,
          stage: TargetStage.finished,
          result: result,
        ),
      );
    }

    TargetSetup setupOf(
      ProfileTarget target,
      SigningSchemes schemes, {
      bool cut = false,
      String? copiedFrom,
    }) => TargetSetup(
      abi: target.abiName,
      cut: cut,
      keyProperties: target.keyProperties,
      keyAlias: keys[target.keyProperties]?.alias,
      schemes: schemes,
      schemesFromDefaults: target.schemes == null,
      copiedFrom: copiedFrom,
    );

    for (final skipped in plan.skipped) {
      finish(
        TargetResult(
          target: skipped.target.name,
          input: host.path.basename(skipped.input.path),
          status: TargetStatus.skipped,
          reason: skipped.reason,
          setup: setupOf(skipped.target, skipped.schemes),
        ),
      );
    }

    for (final job in plan.jobs) {
      final input = host.path.basename(job.input.path);
      void stage(TargetStage stage, [Iterable<PlannedOutput>? outputs]) {
        for (final output in outputs ?? job.outputs) {
          onProgress?.call(
            TargetProgress(
              target: output.target.name,
              input: input,
              stage: stage,
            ),
          );
        }
      }

      // The first target of a job is signed; the others get a copy.
      TargetSetup setup(PlannedOutput output) => setupOf(
        output.target,
        job.schemes,
        cut: job.abi != null,
        copiedFrom: output == job.outputs.first
            ? null
            : job.outputs.first.target.name,
      );
      TargetResult skippedAs(PlannedOutput output, String reason) =>
          TargetResult(
            target: output.target.name,
            input: input,
            status: TargetStatus.skipped,
            reason: reason,
            setup: setup(output),
          );
      TargetResult failedAs(PlannedOutput output, String reason) =>
          TargetResult(
            target: output.target.name,
            input: input,
            status: TargetStatus.failed,
            reason: reason,
            setup: setup(output),
          );

      if (executor.isCancelled) {
        for (final output in job.outputs) {
          finish(skippedAs(output, 'Cancelled before it ran'));
        }
        continue;
      }
      final key = keys[job.keyProperties];
      if (key == null) {
        for (final output in job.outputs) {
          finish(
            failedAs(output, 'Its key ${job.keyProperties} was not opened.'),
          );
        }
        continue;
      }

      final done = <PlannedOutput>{};
      final directory =
          await (temporaryDirectory?.call() ?? Directory.systemTemp).createTemp(
            'apk_forge_profile_',
          );
      try {
        var source = job.input.path;
        final abi = job.abi;
        if (abi != null) {
          stage(TargetStage.splitting);
          source = host.path.join(
            directory.path,
            abiSplitFileName(job.input.path, abi.abiName, host),
          );
          await copyZipEntries(
            job.input.path,
            source,
            keep: (entry) => keepsEntryForAbi(entry, abi.abiName),
          );
        }

        stage(TargetStage.signing);
        final signed = await signing.sign(
          executor,
          toolchain: toolchain,
          input: source,
          request: key.request(schemes: job.schemes, outputDir: directory.path),
          expectedSha256: key.sha256,
        );
        // Every target of the job gets a copy of the same file.
        final outputSha256 = (await fileDigests(signed.path)).sha256;
        final hasJarSignature = await _hasJarSignature(signed.path);

        for (final output in job.outputs) {
          if (executor.isCancelled) {
            finish(skippedAs(output, 'Cancelled before it was written'));
            done.add(output);
            continue;
          }
          stage(TargetStage.writing, [output]);
          try {
            await _write(signed.path, output.path);
            executor.log.info('${output.target.name}: ${output.path}');
            finish(
              TargetResult(
                target: output.target.name,
                input: input,
                status: TargetStatus.signed,
                outputPath: output.path,
                sizeBytes: await File(output.path).length(),
                signerSha256: signed.signer?.sha256,
                setup: setup(output),
                signerDistinguishedName: signed.signer?.distinguishedName,
                verifiedSchemes: signed.verifiedSchemes,
                hasJarSignature: hasJarSignature,
                outputSha256: outputSha256,
              ),
            );
          } on FileSystemException catch (error) {
            final reason =
                'Could not write ${output.path}: '
                '${error.osError?.message ?? error.message}';
            executor.log.error('${output.target.name}: $reason');
            finish(failedAs(output, reason));
          }
          done.add(output);
        }
      } on ToolFailure catch (failure) {
        final reason = [failure.title, ...failure.details.take(2)].join(': ');
        for (final output in job.outputs.where((o) => !done.contains(o))) {
          finish(failedAs(output, reason));
        }
      } on ZipFormatException catch (error) {
        for (final output in job.outputs.where((o) => !done.contains(o))) {
          finish(failedAs(output, 'Cannot split $input: ${error.message}'));
        }
      } on FileSystemException catch (error) {
        for (final output in job.outputs.where((o) => !done.contains(o))) {
          finish(failedAs(output, error.message));
        }
      } finally {
        await directory.delete(recursive: true);
      }
    }
    return results;
  }

  /// Whether [apk] carries a v1 (JAR) signature, which apksigner doesn't
  /// verify from minSdk 24. `null` when its files can't be read.
  static Future<bool?> _hasJarSignature(String apk) async {
    try {
      return ApkContents.fromEntries(await readZipDirectory(apk))
          .hasJarSignature;
    } on ZipFormatException {
      return null;
    }
  }

  /// Copies [from] to [to], and its v4 `.idsig` when it has one.
  Future<void> _write(String from, String to) async {
    await File(to).parent.create(recursive: true);
    await _copy(from, to);
    if (await File('$from.idsig').exists()) {
      await _copy('$from.idsig', '$to.idsig');
    }
  }

  /// Through `<to>.partial`, so a failure never leaves half a file, and an
  /// earlier file at [to] stays until the copy is whole.
  Future<void> _copy(String from, String to) async {
    final partial = File('$to.partial');
    try {
      await File(from).copy(partial.path);
      final target = File(to);
      // Windows can't rename over an existing file.
      if (host.isWindows && await target.exists()) await target.delete();
      await partial.rename(to);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }
}
