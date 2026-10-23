import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/format.dart';
import '../../state/mcp_tools.dart';
import '../../state/providers.dart';
import '../common/widgets.dart';
import '../profiles/run_check.dart';
import '../theme.dart';

/// A run an agent asked for, checked, with Allow and Decline. It closes once
/// the request is answered, here or by the server stopping.
Future<void> showRunRequestDialog(
  BuildContext context,
  McpRunRequest request,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _RunRequestDialog(request: request),
);

class _RunRequestDialog extends ConsumerWidget {
  const _RunRequestDialog({required this.request});

  final McpRunRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(mcpRunRequestProvider, (_, next) {
      if (!identical(next, request)) Navigator.of(context).pop();
    });
    final host = ref.watch(hostProvider);
    final colors = context.status;
    final notifier = ref.read(mcpRunRequestProvider.notifier);
    final check = request.check;

    return AlertDialog(
      title: Text('An agent asks to run “${request.profile.name}”'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'The check passed and every key opened. Nothing is signed '
                'until you allow it.',
                style: TextStyle(fontSize: 12.5, color: colors.muted),
              ),
              const SizedBox(height: 10),
              for (final input in check.inputs)
                InfoRow('Input', shortPath(input.path, host), mono: true),
              const SizedBox(height: 10),
              RunPlanTable(check: check),
              const SizedBox(height: 8),
              Text(
                runPlanSummary(check),
                style: TextStyle(fontSize: 12.5, color: colors.muted),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => notifier.answer(allow: false),
          child: const Text('Decline'),
        ),
        FilledButton.icon(
          onPressed: () => notifier.answer(allow: true),
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Allow'),
        ),
      ],
    );
  }
}
