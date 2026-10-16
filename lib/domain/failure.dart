import '../core/logging/log_entry.dart';
import '../core/process/command.dart';
import '../core/process/process_runner.dart';

/// A step that couldn't finish. [details] are the tool lines that explain
/// why, shown under the title in the error panel.
class ToolFailure implements Exception {
  const ToolFailure(this.title, {this.details = const []});

  factory ToolFailure.fromResult(
    String title,
    CommandResult result, {
    List<String> secrets = const [],
  }) {
    final details = errorDetails(result)
        .map((line) => maskSecrets(line, secrets))
        .toList();
    final code = result.cancelled
        ? 'cancelled'
        : result.exitCode == startFailureExitCode
        ? 'could not start'
        : 'exit code ${result.exitCode}';
    return ToolFailure('$title ($code)', details: details);
  }

  final String title;
  final List<String> details;

  @override
  String toString() => [title, ...details].join('\n');
}

const _maxDetailLines = 40;

/// The lines that explain why [result] failed.
///
/// - Gradle's "* What went wrong:" block, without the "* Try:" advice.
/// - Otherwise the lines that look like errors, with the line after each
///   (tools often put the reason there).
/// - Otherwise the last lines of output.
List<String> errorDetails(CommandResult result) {
  final lines = result.allLines;

  final wrong = lines.indexWhere((line) => line.trim() == '* What went wrong:');
  if (wrong >= 0) {
    final block = <String>[];
    for (final line in lines.skip(wrong + 1)) {
      final trimmed = line.trim();
      if (trimmed.startsWith('* Try:') ||
          trimmed.startsWith('* Get more help')) {
        break;
      }
      if (trimmed.isNotEmpty) block.add(line);
    }
    if (block.isNotEmpty) return _cap(block);
  }

  final picked = <String>[];
  for (var index = 0; index < lines.length; index++) {
    if (!looksLikeError(lines[index])) continue;
    picked.add(lines[index]);
    final next = index + 1 < lines.length ? lines[index + 1] : null;
    if (next != null && _explains(next)) picked.add(next);
  }
  if (picked.isNotEmpty) return _cap(picked.toSet().toList());

  final nonEmpty = lines.where((line) => line.trim().isNotEmpty).toList();
  return nonEmpty.length <= 15
      ? nonEmpty
      : nonEmpty.sublist(nonEmpty.length - 15);
}

/// A line worth showing after an error line: not empty, not another error
/// (it gets its own turn) and not a Java stack frame.
bool _explains(String line) {
  final trimmed = line.trim();
  return trimmed.isNotEmpty &&
      !looksLikeError(line) &&
      !trimmed.startsWith('at ') &&
      !trimmed.startsWith('... ');
}

List<String> _cap(List<String> lines) =>
    lines.length <= _maxDetailLines ? lines : lines.sublist(0, _maxDetailLines);
