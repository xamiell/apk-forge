import 'dart:io';

import '../core/process/command.dart';
import '../core/system/host.dart';
import '../domain/build/build_options.dart';
import '../domain/build/flutter_build.dart';
import '../domain/failure.dart';
import 'tool_executor.dart';

class FlutterBuildService {
  const FlutterBuildService({required this.host});

  final Host host;

  /// Builds [options] and returns the APKs Flutter reports, in its order.
  Future<List<String>> build(
    ToolExecutor executor, {
    required String flutter,
    required BuildOptions options,
  }) async {
    final project = options.projectDir.trim();
    final result = await executor.run(
      Command(
        flutter,
        flutterBuildArguments(options),
        workingDirectory: project,
      ),
    );
    if (!result.succeeded) {
      throw ToolFailure.fromResult('Build failed', result);
    }
    final apks = parseBuiltApks(
      result.allLines,
      projectDir: project,
      host: host,
    );
    if (apks.isEmpty) {
      throw const ToolFailure(
        'The build finished but reported no APK',
        details: ['No "✓ Built …apk" line in the output.'],
      );
    }
    if (options.effectiveObfuscate && !_hasSymbols(options.symbolsDir.trim())) {
      // Flutter skips the Dart compile when nothing changed, and with it the
      // symbols: a deleted symbols folder stays empty.
      executor.log.warning(
        'No .symbols files in ${options.symbolsDir.trim()}: Flutter reused a cached '
        'build. Without them an obfuscated crash trace can\'t be read. Run '
        '"flutter clean" in the project and build again.',
      );
    }
    return apks;
  }
}

bool _hasSymbols(String directory) {
  final folder = Directory(directory);
  return folder.existsSync() &&
      folder.listSync().any((entry) => entry.path.endsWith('.symbols'));
}

/// `flutter --version --machine` → `3.47.5`. `null` when it can't tell.
Future<String?> readFlutterVersion(
  ToolExecutor executor,
  String flutter,
) async {
  final result = await executor.run(
    Command(flutter, const ['--version', '--machine']),
    echoOutput: false,
  );
  if (!result.succeeded) return null;
  final match = RegExp(r'"frameworkVersion"\s*:\s*"([^"]+)"')
      .firstMatch(result.stdout.join('\n'));
  return match?.group(1);
}
