import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/log_entry.dart';
import '../../domain/failure.dart';
import '../../state/log_notifier.dart';
import '../../state/task_notifier.dart';
import '../common/widgets.dart';
import '../theme.dart';

class LogPanel extends ConsumerStatefulWidget {
  const LogPanel({super.key});

  @override
  ConsumerState<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends ConsumerState<LogPanel> {
  final _scroll = ScrollController();

  /// Follow new lines while the user is at the bottom; stop when they
  /// scroll up to read.
  bool _follow = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final atBottom =
          _scroll.position.pixels >= _scroll.position.maxScrollExtent - 24;
      if (atBottom != _follow) setState(() => _follow = atBottom);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final log = ref.watch(logProvider);
    final task = ref.watch(taskProvider);
    final colors = context.status;
    if (_follow) _jumpToEnd();

    return SectionCard(
      title: 'Log',
      icon: Icons.terminal_rounded,
      expand: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (task.isRunning) ...[
            const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(task.running!, style: const TextStyle(fontSize: 12.5)),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => ref.read(taskProvider.notifier).cancel(),
              icon: const Icon(Icons.stop_rounded, size: 16),
              label: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
          ],
          if (!_follow)
            IconButton(
              tooltip: 'Follow new lines',
              icon: const Icon(Icons.vertical_align_bottom_rounded, size: 18),
              onPressed: () {
                setState(() => _follow = true);
                _jumpToEnd();
              },
            ),
          IconButton(
            tooltip: 'Copy log',
            icon: const Icon(Icons.copy_all_rounded, size: 18),
            onPressed: () => Clipboard.setData(
              ClipboardData(text: ref.read(logProvider.notifier).asText()),
            ),
          ),
          IconButton(
            tooltip: 'Clear log',
            icon: const Icon(Icons.delete_sweep_outlined, size: 18),
            onPressed: () => ref.read(logProvider.notifier).clear(),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (task.failure != null) _FailureBanner(failure: task.failure!),
          Expanded(
            child: Container(
              color: colors.logBackground,
              child: SelectionArea(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  itemCount: log.entries.length,
                  itemBuilder: (context, index) =>
                      _LogLine(entry: log.entries[index]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final color = context.status.forLog(entry.kind);
    if (entry.kind == LogKind.step) {
      return Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2),
        child: Text(
          '▶ ${entry.text}  ${_time(entry.time)}',
          style: monospace.copyWith(color: color, fontWeight: FontWeight.w700),
        ),
      );
    }
    return Text(
      entry.text,
      style: monospace.copyWith(
        color: color,
        fontWeight: entry.kind == LogKind.error || entry.kind == LogKind.success
            ? FontWeight.w600
            : null,
      ),
    );
  }

  static String _time(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
}

/// The last failure, above the log, until the user closes it.
class _FailureBanner extends ConsumerWidget {
  const _FailureBanner({required this.failure});

  final ToolFailure failure;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = context.status.error;
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border(bottom: BorderSide(color: color.withValues(alpha: 0.4))),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: SingleChildScrollView(
              child: SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      failure.title,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (failure.details.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        failure.details.join('\n'),
                        style: monospace.copyWith(color: color),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          CopyButton(
            [failure.title, ...failure.details].join('\n'),
            tooltip: 'Copy error',
          ),
          IconButton(
            tooltip: 'Dismiss',
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: () => ref.read(taskProvider.notifier).dismissFailure(),
          ),
        ],
      ),
    );
  }
}
