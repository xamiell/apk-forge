import '../core/logging/log_entry.dart';
import '../core/process/command.dart';
import '../core/process/process_runner.dart';

/// Runs commands for one task: logs each command line, streams its output
/// to the log with the secrets masked, and stops when the task is cancelled.
class ToolExecutor {
  ToolExecutor(this._runner, this.log, {CancelToken? cancelToken})
    : cancelToken = cancelToken ?? CancelToken();

  final ProcessRunner _runner;
  final TaskLog log;
  final CancelToken cancelToken;

  bool get isCancelled => cancelToken.isCancelled;

  /// [echoOutput] off keeps long, routine output (aapt2's badging) out of
  /// the log; the command line and a failure still show.
  Future<CommandResult> run(Command command, {bool echoOutput = true}) {
    log.command(command);
    return _runner.run(
      command,
      cancelToken: cancelToken,
      onOutput: echoOutput
          ? (stream, line) => log.output(stream, line, secrets: command.secrets)
          : null,
    );
  }
}
