import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../system/host.dart';
import 'command.dart';

enum OutputStream { stdout, stderr }

typedef OutputListener = void Function(OutputStream stream, String line);

/// What a finished [Command] left behind.
class CommandResult {
  const CommandResult({
    required this.exitCode,
    this.stdout = const [],
    this.stderr = const [],
    this.cancelled = false,
  });

  final int exitCode;
  final List<String> stdout;
  final List<String> stderr;

  /// The user stopped it. [exitCode] is whatever the killed process returned.
  final bool cancelled;

  bool get succeeded => exitCode == 0 && !cancelled;

  /// stdout then stderr. Most tools here print their errors to stdout.
  List<String> get allLines => [...stdout, ...stderr];
}

/// Lets the user stop a running command.
class CancelToken {
  final _callbacks = <void Function()>[];
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final callback in List.of(_callbacks)) {
      callback();
    }
    _callbacks.clear();
  }

  /// Runs [callback] on [cancel], or right away if it already happened.
  void onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
    } else {
      _callbacks.add(callback);
    }
  }

  void removeCallback(void Function() callback) => _callbacks.remove(callback);
}

/// The only way the app starts an external program.
///
/// Services take this interface, so tests drive them with a fake and never
/// depend on the tools installed on the machine that runs them.
abstract interface class ProcessRunner {
  /// Runs [command] to the end and streams its lines to [onOutput].
  ///
  /// Never throws for a program that fails or can't start: that comes back
  /// as a non-zero [CommandResult.exitCode] with the reason in `stderr`, so
  /// every failure reaches the log the same way.
  Future<CommandResult> run(
    Command command, {
    OutputListener? onOutput,
    CancelToken? cancelToken,
  });
}

/// Exit code reported when the program couldn't be started at all.
const int startFailureExitCode = 127;

class IoProcessRunner implements ProcessRunner {
  IoProcessRunner(this._host);

  /// Its environment is the one programs start with, usually the login
  /// shell's (see `loadShellEnvironment`): an app opened from Finder only
  /// gets a bare `PATH`, without `flutter`, `java` or the Android SDK.
  final Host _host;

  @override
  Future<CommandResult> run(
    Command command, {
    OutputListener? onOutput,
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      return const CommandResult(exitCode: -1, cancelled: true);
    }

    final Process process;
    try {
      process = await Process.start(
        command.executable,
        command.arguments,
        workingDirectory: command.workingDirectory,
        environment: {..._host.environment, ...command.environment},
        includeParentEnvironment: false,
        runInShell: startsThroughShell(_host, command.executable),
      );
    } on ProcessException catch (error) {
      final reason = 'Could not start ${command.executable}: ${error.message}';
      onOutput?.call(OutputStream.stderr, reason);
      return CommandResult(exitCode: startFailureExitCode, stderr: [reason]);
    }
    // No tool the app runs reads its input. With it closed, one that asks
    // for something (apksigner, for a key password it wasn't given) fails
    // at once instead of waiting forever. A process that already ended
    // makes the close fail: nothing to do then.
    process.stdin.close().ignore();

    final stdoutLines = <String>[];
    final stderrLines = <String>[];
    var cancelled = false;

    void kill() {
      cancelled = true;
      process.kill();
      // A tool that ignores SIGTERM (Gradle's client) still has to stop.
      Timer(
        const Duration(seconds: 5),
        () => process.kill(ProcessSignal.sigkill),
      );
    }

    cancelToken?.onCancel(kill);

    Future<void> pump(
      Stream<List<int>> bytes,
      OutputStream stream,
      List<String> sink,
    ) {
      return bytes
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach((line) {
            sink.add(line);
            onOutput?.call(stream, line);
          });
    }

    await Future.wait([
      pump(process.stdout, OutputStream.stdout, stdoutLines),
      pump(process.stderr, OutputStream.stderr, stderrLines),
    ]);
    final exitCode = await process.exitCode;
    cancelToken?.removeCallback(kill);

    return CommandResult(
      exitCode: exitCode,
      stdout: stdoutLines,
      stderr: stderrLines,
      cancelled: cancelled,
    );
  }
}

/// Whether [executable] has to start through the shell: on Windows, a
/// `.bat` or `.cmd` (flutter.bat, apksigner.bat) only runs through cmd.exe.
bool startsThroughShell(Host host, String executable) {
  final lower = executable.toLowerCase();
  return host.isWindows && (lower.endsWith('.bat') || lower.endsWith('.cmd'));
}
