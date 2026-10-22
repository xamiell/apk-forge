import 'package:flutter/material.dart';

/// The Run dialog's frame: a title bar, a body that scrolls, and a row of
/// buttons.
class RunDialogFrame extends StatelessWidget {
  const RunDialogFrame({
    super.key,
    required this.title,
    required this.body,
    required this.footer,
    this.onClose,
  });

  final String title;
  final Widget body;
  final List<Widget> footer;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
        child: Row(
          children: [
            Icon(
              Icons.play_arrow_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
            if (onClose != null)
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close_rounded),
                onPressed: onClose,
              ),
          ],
        ),
      ),
      const Divider(),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: body,
        ),
      ),
      const Divider(),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
        child: Row(children: footer),
      ),
    ],
  );
}
