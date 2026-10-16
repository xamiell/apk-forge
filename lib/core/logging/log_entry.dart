import '../process/command.dart';
import '../process/process_runner.dart';

enum LogKind {
  /// The start of a task ("Build", "Sign app-release.apk").
  step,

  /// A command line about to run.
  command,
  stdout,
  stderr,
  info,
  warning,
  success,
  error,
}

class LogEntry {
  const LogEntry({required this.time, required this.kind, required this.text});

  final DateTime time;
  final LogKind kind;
  final String text;
}

/// Where services write what they do. The log panel implements it; tests
/// record it.
abstract interface class TaskLog {
  void step(String text);
  void command(Command command);

  /// One output line of a running command, with [secrets] masked.
  void output(
    OutputStream stream,
    String line, {
    List<String> secrets = const [],
  });
  void info(String text);
  void warning(String text);
  void success(String text);
  void error(String text);
}

/// Tool lines that are warnings even though they come on stdout.
bool looksLikeWarning(String line) {
  final trimmed = line.trimLeft();
  return trimmed.startsWith('Warning:') ||
      trimmed.startsWith('WARNING:') ||
      trimmed.startsWith('w: ');
}

/// Tool lines that are errors even though they come on stdout.
bool looksLikeError(String line) {
  final trimmed = line.trimLeft();
  return trimmed.startsWith('ERROR:') ||
      trimmed.startsWith('Error:') ||
      trimmed.startsWith('error:') ||
      trimmed.startsWith('e: ') ||
      trimmed.startsWith('FAILURE:') ||
      trimmed.startsWith('adb: failed') ||
      trimmed.contains('Failure [') ||
      trimmed.startsWith('keytool error:') ||
      trimmed.contains('Exception:') ||
      trimmed.startsWith('Failed to ');
}
