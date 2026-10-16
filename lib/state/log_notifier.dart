import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/logging/log_entry.dart';
import '../core/process/command.dart';
import '../core/process/process_runner.dart';
import 'providers.dart';

/// The log panel's lines.
///
/// [entries] is one list that only grows (up to [maxEntries]); [revision]
/// changes on every write so the panel rebuilds without copying thousands
/// of lines per output line.
class LogState {
  const LogState(this.entries, this.revision);

  final List<LogEntry> entries;
  final int revision;
}

const maxEntries = 5000;

final logProvider = NotifierProvider<LogNotifier, LogState>(LogNotifier.new);

class LogNotifier extends Notifier<LogState> implements TaskLog {
  final _entries = <LogEntry>[];

  @override
  LogState build() => LogState(_entries, 0);

  void clear() {
    _entries.clear();
    state = LogState(_entries, state.revision + 1);
  }

  /// The log as plain text, for the clipboard.
  String asText() => _entries.map((entry) => entry.text).join('\n');

  void _add(LogKind kind, String text) {
    _entries.add(
      LogEntry(time: ref.read(clockProvider)(), kind: kind, text: text),
    );
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    state = LogState(_entries, state.revision + 1);
  }

  @override
  void step(String text) => _add(LogKind.step, text);

  @override
  void command(Command command) => _add(
    LogKind.command,
    '\$ ${maskSecrets(command.displayLine, command.secrets)}',
  );

  @override
  void output(
    OutputStream stream,
    String line, {
    List<String> secrets = const [],
  }) {
    final masked = maskSecrets(line, secrets);
    final kind = looksLikeError(masked)
        ? LogKind.error
        : looksLikeWarning(masked)
        ? LogKind.warning
        : stream == OutputStream.stderr
        ? LogKind.stderr
        : LogKind.stdout;
    _add(kind, masked);
  }

  @override
  void info(String text) => _add(LogKind.info, text);

  @override
  void warning(String text) => _add(LogKind.warning, text);

  @override
  void success(String text) => _add(LogKind.success, text);

  @override
  void error(String text) => _add(LogKind.error, text);
}
