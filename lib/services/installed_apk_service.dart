import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/process/command.dart';
import '../core/system/host.dart';
import '../core/zip/zip_directory.dart';
import '../domain/analysis/apk_report.dart';
import '../domain/devices/installed_apk.dart';
import '../domain/failure.dart';
import '../domain/tools/toolchain.dart';
import 'apk_analyzer.dart';
import 'tool_executor.dart';

/// An app as it is installed on a device, read like any APK.
class InstalledApk {
  const InstalledApk({required this.report, required this.files});

  /// `base.apk`'s report, with the native code of the ABI splits. Its size
  /// is what was pulled; its hashes are `base.apk`'s.
  final ApkReport report;
  final InstalledApkFiles files;
}

/// Copies an installed app's APK files from a device to a temporary folder,
/// reads them, and deletes them.
class InstalledApkService {
  const InstalledApkService({
    required this.host,
    this.analyzer = const ApkAnalyzer(),
    this.temporaryDirectory,
  });

  final Host host;
  final ApkAnalyzer analyzer;

  /// Where the files are copied. The system's by default.
  final Directory Function()? temporaryDirectory;

  /// [package] as installed on [serial], or `null` when it isn't.
  ///
  /// A `base.apk` that can't be copied fails. An ABI split that can't be
  /// copied leaves the native code unread, with the reason.
  Future<InstalledApk?> read(
    ToolExecutor executor, {
    required Toolchain toolchain,
    required String serial,
    required String package,
  }) async {
    final adb = toolchain.adb;
    if (adb == null) {
      throw const ToolFailure(
        'adb was not found',
        details: ['Install the Android SDK platform-tools.'],
      );
    }
    final listed = await executor.run(
      Command(adb, adbPackagePathArguments(serial, package)),
      echoOutput: false,
    );
    final paths = parsePackagePaths(listed.stdout);
    if (paths.isEmpty) {
      // pm prints nothing and exits 1 for a package that isn't installed.
      if (listed.exitCode == 1 && listed.allLines.isEmpty) return null;
      throw ToolFailure.fromResult('Could not list $package\'s files', listed);
    }
    final files = InstalledApkFiles.from(paths);

    final directory = await (temporaryDirectory?.call() ?? Directory.systemTemp)
        .createTemp('apk_forge_installed_');
    try {
      final base = await _pull(executor, adb, serial, files.base, directory);
      if (base.path == null) {
        throw ToolFailure(
          'Could not copy $package from the device',
          details: [p.posix.basename(files.base), ...base.failure],
        );
      }
      final report = await analyzer.analyze(
        executor,
        toolchain: toolchain,
        path: base.path!,
      );
      if (files.abiSplits.isEmpty || report.contentsError != null) {
        return InstalledApk(report: report, files: files);
      }
      return InstalledApk(
        report: await _withSplits(
          executor,
          adb,
          serial,
          report,
          files.abiSplits,
          directory,
        ),
        files: files,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  }

  /// [report] with the native code of [abiSplits], or the reason it
  /// couldn't be read.
  Future<ApkReport> _withSplits(
    ToolExecutor executor,
    String adb,
    String serial,
    ApkReport report,
    List<String> abiSplits,
    Directory directory,
  ) async {
    final splits = <String>[];
    for (final remote in abiSplits) {
      final split = await _pull(executor, adb, serial, remote, directory);
      if (split.path == null) {
        return report.withContents(
          report.contents,
          contentsError:
              'Could not copy ${p.posix.basename(remote)}: '
              '${split.failure.join(' ')}',
        );
      }
      splits.add(split.path!);
    }
    try {
      return report.withContents(
        installedContents(await readZipDirectory(report.path), [
          for (final split in splits) await readZipDirectory(split),
        ]),
        sizeBytes: splits.fold<int>(
          report.sizeBytes,
          (sum, split) => sum + File(split).lengthSync(),
        ),
      );
    } on ZipFormatException catch (error) {
      return report.withContents(report.contents, contentsError: error.message);
    }
  }

  /// Copies [remote] into [directory]: its local path, or why adb couldn't.
  Future<({String? path, List<String> failure})> _pull(
    ToolExecutor executor,
    String adb,
    String serial,
    String remote,
    Directory directory,
  ) async {
    final local = host.path.join(directory.path, p.posix.basename(remote));
    final result = await executor.run(
      Command(adb, adbPullArguments(serial, remote, local)),
      echoOutput: false,
    );
    if (result.succeeded && File(local).existsSync()) {
      return (path: local, failure: const <String>[]);
    }
    return (path: null, failure: errorDetails(result));
  }
}
