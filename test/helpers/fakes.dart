import 'dart:io';

import 'package:apk_forge/core/logging/log_entry.dart';
import 'package:apk_forge/core/process/command.dart';
import 'package:apk_forge/core/process/process_runner.dart';
import 'package:apk_forge/core/system/host.dart';
import 'package:apk_forge/domain/failure.dart';
import 'package:apk_forge/services/tool_executor.dart';
import 'package:apk_forge/state/apks.dart';
import 'package:apk_forge/state/task_notifier.dart';
import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:path/path.dart' as p;

/// Real tool output captured from build-tools 36.0.0, Flutter 3.47.5 and a
/// throwaway keystore (see test/fixtures/README.md).
List<String> fixture(String name) =>
    File(p.join('test', 'fixtures', name)).readAsLinesSync();

CommandResult ok([List<String> stdout = const []]) =>
    CommandResult(exitCode: 0, stdout: stdout);

CommandResult failed(
  int code, {
  List<String> stdout = const [],
  List<String> stderr = const [],
}) => CommandResult(exitCode: code, stdout: stdout, stderr: stderr);

/// Answers commands from a script and records every call.
class FakeProcessRunner implements ProcessRunner {
  final calls = <Command>[];
  final _rules = <(bool Function(Command), CommandResult Function(Command))>[];

  /// The first rule that matches answers. Unmatched commands succeed with
  /// no output.
  void when(
    bool Function(Command command) matches,
    CommandResult Function(Command command) respond,
  ) => _rules.add((matches, respond));

  /// Matches by the first argument (`sign`, `verify`, `build`, `-c`…).
  void whenFirstArg(String argument, CommandResult result) => when(
    (c) => c.arguments.isNotEmpty && c.arguments.first == argument,
    (_) => result,
  );

  Iterable<Command> callsWithFirstArg(String argument) => calls.where(
    (c) => c.arguments.isNotEmpty && c.arguments.first == argument,
  );

  @override
  Future<CommandResult> run(
    Command command, {
    OutputListener? onOutput,
    CancelToken? cancelToken,
  }) async {
    calls.add(command);
    for (final (matches, respond) in _rules) {
      if (!matches(command)) continue;
      final result = respond(command);
      for (final line in result.stdout) {
        onOutput?.call(OutputStream.stdout, line);
      }
      for (final line in result.stderr) {
        onOutput?.call(OutputStream.stderr, line);
      }
      return result;
    }
    return ok();
  }
}

class RecordingLog implements TaskLog {
  final lines = <String>[];

  @override
  void step(String text) => lines.add('step: $text');

  @override
  void command(Command command) =>
      lines.add('\$ ${maskSecrets(command.displayLine, command.secrets)}');

  @override
  void output(
    OutputStream stream,
    String line, {
    List<String> secrets = const [],
  }) => lines.add('${stream.name}: ${maskSecrets(line, secrets)}');

  @override
  void info(String text) => lines.add('info: $text');

  @override
  void warning(String text) => lines.add('warning: $text');

  @override
  void success(String text) => lines.add('success: $text');

  @override
  void error(String text) => lines.add('error: $text');
}

/// A file system made of the paths it's given.
class FakeFileProbe implements FileProbe {
  FakeFileProbe({
    Set<String> files = const {},
    Set<String> directories = const {},
  }) : files = {...files},
       directories = {...directories};

  final Set<String> files;
  final Set<String> directories;

  @override
  bool fileExists(String path) => files.contains(path);

  @override
  bool directoryExists(String path) => directories.contains(path);

  @override
  List<String> directoryNames(String path) {
    final prefix = path.endsWith('/') || path.endsWith(r'\')
        ? path
        : '$path${path.contains(r'\') ? r'\' : '/'}';
    return directories
        .where((dir) => dir.startsWith(prefix))
        .map((dir) => dir.substring(prefix.length))
        .where(
          (rest) =>
              rest.isNotEmpty && !rest.contains('/') && !rest.contains(r'\'),
        )
        .toList();
  }
}

const macHost = Host(
  os: HostOs.macos,
  environment: {'HOME': '/Users/dev', 'PATH': '/usr/bin:/bin'},
);

/// Runs each task's body at once, over [runner], and keeps the failure that
/// TaskNotifier would show.
class FakeTaskRunner implements TaskRunner {
  FakeTaskRunner(this.runner);

  final ProcessRunner runner;
  final log = RecordingLog();
  final cancelToken = CancelToken();

  /// The tasks that ran, in order.
  final labels = <String>[];
  ToolFailure? failure;

  /// Set it to pretend another task is running.
  @override
  bool isRunning = false;

  @override
  Future<T?> run<T>(
    String label,
    Future<T> Function(ToolExecutor executor) body,
  ) async {
    if (isRunning) return null;
    labels.add(label);
    try {
      return await body(ToolExecutor(runner, log, cancelToken: cancelToken));
    } on ToolFailure catch (failure) {
      this.failure = failure;
      return null;
    }
  }
}

/// Records what the actions list and select, in order.
class RecordingApkSink implements ApkSink {
  final added = <({String path, ApkOrigin origin, bool select})>[];
  final selected = <String>[];

  @override
  void add(String path, ApkOrigin origin, {bool select = true}) =>
      added.add((path: path, origin: origin, select: select));

  @override
  void select(String path) => selected.add(path);
}

/// Writes an APK at [path] with a Flutter engine and app for each of
/// [abis], and returns [path].
String writeApk(String path, List<String> abis) {
  final archive = Archive()
    ..add(ArchiveFile.string('AndroidManifest.xml', 'manifest'));
  for (final abi in abis) {
    archive
      ..add(ArchiveFile.string('lib/$abi/libflutter.so', 'engine'))
      ..add(ArchiveFile.string('lib/$abi/libapp.so', 'app'));
  }
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(ZipEncoder().encode(archive));
  return path;
}
