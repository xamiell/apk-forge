import '../../core/system/host.dart';
import 'build_options.dart';

/// Why [options] can't be built yet, in the order the form shows them.
/// Empty when it can.
List<String> buildProblems(BuildOptions options, Host host, FileProbe probe) {
  final problems = <String>[];
  final project = options.projectDir.trim();
  if (project.isEmpty) {
    problems.add('Choose the Flutter project folder.');
  } else if (!probe.fileExists(host.path.join(project, 'pubspec.yaml'))) {
    problems.add(
      'The folder has no pubspec.yaml: it is not a Flutter project.',
    );
  } else if (!probe.directoryExists(host.path.join(project, 'android'))) {
    problems.add('The project has no android/ folder.');
  }
  if (options.abis.isEmpty) {
    problems.add('Choose at least one architecture in Defaults.');
  }
  if (options.effectiveObfuscate && options.symbolsDir.trim().isEmpty) {
    problems.add('Obfuscation needs a folder for the symbols.');
  }
  return problems;
}

/// The `flutter` arguments for [options].
///
/// `--target-platform` is always passed, even with every ABI selected, so
/// the log shows exactly what was built. ABIs keep the enum's order so the
/// same selection always gives the same command.
List<String> flutterBuildArguments(BuildOptions options) {
  final targets = AndroidAbi.values
      .where(options.abis.contains)
      .map((abi) => abi.flutterTarget)
      .join(',');
  return [
    'build',
    'apk',
    options.mode == BuildMode.release ? '--release' : '--debug',
    '--target-platform',
    targets,
    if (options.effectivePackaging == ApkPackaging.splitPerAbi)
      '--split-per-abi',
    if (options.effectiveObfuscate) ...[
      '--obfuscate',
      '--split-debug-info=${options.symbolsDir.trim()}',
    ],
  ];
}

final _builtLine = RegExp(r'Built\s+(.+?\.apk)(?:\s+\([^)]*\))?\s*$');

/// The APKs a `flutter build apk` run reports, as absolute paths.
///
/// Flutter prints one line per APK, relative to the project:
/// `✓ Built build/app/outputs/flutter-apk/app-release.apk (12.1MB)`.
/// Reading them, instead of guessing names, also covers flavors and custom
/// output names.
List<String> parseBuiltApks(
  Iterable<String> lines, {
  required String projectDir,
  required Host host,
}) {
  final apks = <String>[];
  for (final line in lines) {
    final match = _builtLine.firstMatch(line);
    if (match == null) continue;
    final path = match.group(1)!.trim();
    apks.add(
      host.path.normalize(
        host.path.isAbsolute(path) ? path : host.path.join(projectDir, path),
      ),
    );
  }
  return apks;
}
