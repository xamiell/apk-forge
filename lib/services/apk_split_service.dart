import 'dart:io';

import '../core/format/format.dart';
import '../core/system/host.dart';
import '../core/zip/zip_directory.dart';
import '../domain/analysis/apk_report.dart';
import '../domain/failure.dart';
import '../domain/signing/abi_split.dart';
import 'tool_executor.dart';

/// One APK cut out of a universal one: only [abi]'s native code inside.
class AbiSplitApk {
  const AbiSplitApk({required this.abi, required this.path});

  final String abi;
  final String path;
}

/// Splits a universal APK into one APK per ABI, in Dart: the entries are
/// copied as they are, without the other ABIs' `lib/` folders. No tool
/// runs, and the splits are unsigned and unaligned, ready for
/// `ApkSigningService.sign`, which aligns them first.
class ApkSplitService {
  const ApkSplitService({required this.host, this.temporaryDirectory});

  final Host host;

  /// Where the splits are written. The system's by default.
  final Directory Function()? temporaryDirectory;

  /// Splits [input] into a temporary folder, runs [use] with the splits,
  /// then deletes them. With [abis], only those ABIs get an APK.
  ///
  /// [use] gets an empty list when [input] has native code for one ABI or
  /// none: there is nothing to split. It fails when [input] has none of
  /// [abis].
  Future<T> withSplits<T>(
    ToolExecutor executor, {
    required String input,
    Set<String>? abis,
    required Future<T> Function(List<AbiSplitApk> splits) use,
  }) async {
    final name = host.path.basename(input);
    final List<ZipEntry> entries;
    try {
      entries = await readZipDirectory(input);
    } on ZipFormatException catch (error) {
      throw ToolFailure('Cannot read $name', details: [error.message]);
    } on FileSystemException catch (error) {
      throw ToolFailure('Cannot read $name', details: [error.message]);
    }

    final plan = planAbiSplit(ApkContents.fromEntries(entries), only: abis);
    if (plan.withoutEngine.isNotEmpty) {
      executor.log.warning(
        'Left out ${plan.withoutEngine.join(', ')}: native code but no '
        'Flutter engine, so that APK would crash at launch.',
      );
    }
    if (plan.noneChosen) {
      throw ToolFailure(
        '$name has none of the architectures chosen',
        details: [
          'It has ${plan.notChosen.join(', ')}; '
              'chosen: ${plan.missing.isEmpty ? 'none' : plan.missing.join(', ')}.',
        ],
      );
    }
    if (plan.missing.isNotEmpty) {
      executor.log.warning(
        '$name has no ${plan.missing.join(', ')}: no APK for '
        '${plan.missing.length == 1 ? 'it' : 'them'}.',
      );
    }
    if (plan.notChosen.isNotEmpty) {
      executor.log.info('Left out ${plan.notChosen.join(', ')}: not chosen.');
    }
    if (!plan.canSplit) {
      executor.log.info(
        plan.abis.isEmpty
            ? '$name has no native code: nothing to split.'
            : '$name only has ${plan.abis.single}: nothing to split.',
      );
      return use(const []);
    }

    final directory = await (temporaryDirectory?.call() ?? Directory.systemTemp)
        .createTemp('apk_forge_split_');
    try {
      final splits = <AbiSplitApk>[];
      for (final abi in plan.abis) {
        if (executor.isCancelled) break;
        final output = host.path.join(
          directory.path,
          abiSplitFileName(input, abi, host),
        );
        try {
          await copyZipEntries(
            input,
            output,
            keep: (entry) => keepsEntryForAbi(entry, abi),
          );
        } on ZipFormatException catch (error) {
          throw ToolFailure('Cannot split $name', details: [error.message]);
        } on FileSystemException catch (error) {
          throw ToolFailure('Cannot split $name', details: [error.message]);
        }
        executor.log.info(
          'Split $abi: ${host.path.basename(output)} '
          '(${formatBytes(await File(output).length())})',
        );
        splits.add(AbiSplitApk(abi: abi, path: output));
      }
      return await use(splits);
    } finally {
      await directory.delete(recursive: true);
    }
  }
}
