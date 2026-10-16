import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/process/process_runner.dart';
import '../domain/failure.dart';
import '../services/tool_executor.dart';
import 'log_notifier.dart';
import 'providers.dart';

/// The one task that can run at a time (build, sign, install…), and the
/// last failure until the user dismisses it.
class TaskState {
  const TaskState({this.running, this.failure});

  /// What runs now, for the status line ("Build", "Sign 2 APKs").
  final String? running;
  final ToolFailure? failure;

  bool get isRunning => running != null;
}

final taskProvider = NotifierProvider<TaskNotifier, TaskState>(
  TaskNotifier.new,
);

class TaskNotifier extends Notifier<TaskState> {
  CancelToken? _cancelToken;

  @override
  TaskState build() => const TaskState();

  /// Runs [body] as the current task and returns its value, or `null` if
  /// another task is running, it failed, or the user cancelled it.
  ///
  /// A [ToolFailure] becomes the error panel; anything else thrown is a bug,
  /// shown the same way so it isn't lost.
  Future<T?> run<T>(
    String label,
    Future<T> Function(ToolExecutor executor) body,
  ) async {
    if (state.isRunning) return null;
    final token = CancelToken();
    _cancelToken = token;
    state = TaskState(running: label);

    final log = ref.read(logProvider.notifier);
    log.step(label);
    final executor = ToolExecutor(
      ref.read(processRunnerProvider),
      log,
      cancelToken: token,
    );

    try {
      final value = await body(executor);
      if (token.isCancelled) {
        log.warning('$label: cancelled.');
        state = const TaskState();
        return null;
      }
      state = const TaskState();
      return value;
    } on ToolFailure catch (failure) {
      if (token.isCancelled) {
        log.warning('$label: cancelled.');
        state = const TaskState();
        return null;
      }
      _report(failure);
      return null;
    } catch (error) {
      _report(ToolFailure('Unexpected error in $label', details: ['$error']));
      return null;
    } finally {
      if (identical(_cancelToken, token)) _cancelToken = null;
    }
  }

  void _report(ToolFailure failure) {
    final log = ref.read(logProvider.notifier);
    log.error(failure.title);
    for (final line in failure.details) {
      log.error('  $line');
    }
    state = TaskState(failure: failure);
  }

  void cancel() => _cancelToken?.cancel();

  void dismissFailure() {
    if (state.failure != null) state = TaskState(running: state.running);
  }
}
