import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// A titled panel.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
    this.expand = false,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  /// Fill the height the parent gives (the right-hand panels).
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: 48, child: header),
          const Divider(),
          if (expand)
            Expanded(child: child)
          else
            Padding(padding: const EdgeInsets.all(16), child: child),
        ],
      ),
    );
  }
}

/// A text field kept in sync with [value], which can also change from
/// outside (a Browse button, a saved setting).
class SyncedTextField extends StatefulWidget {
  const SyncedTextField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.hint,
    this.obscure = false,
    this.onSubmitted,
    this.suffix,
    this.enabled = true,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String? label;
  final String? hint;
  final bool obscure;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffix;
  final bool enabled;

  @override
  State<SyncedTextField> createState() => _SyncedTextFieldState();
}

class _SyncedTextFieldState extends State<SyncedTextField> {
  late final _controller = TextEditingController(text: widget.value);
  bool _revealed = false;

  @override
  void didUpdateWidget(SyncedTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reveal = widget.obscure
        ? IconButton(
            tooltip: _revealed ? 'Hide' : 'Show',
            icon: Icon(
              _revealed
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 18,
            ),
            onPressed: () => setState(() => _revealed = !_revealed),
          )
        : null;
    return TextField(
      controller: _controller,
      enabled: widget.enabled,
      obscureText: widget.obscure && !_revealed,
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        suffixIcon: (reveal == null && widget.suffix == null)
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [?reveal, ?widget.suffix],
              ),
      ),
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
    );
  }
}

/// A path typed or picked with a Browse button.
class PathField extends StatelessWidget {
  const PathField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.onBrowse,
    this.hint,
    this.enabled = true,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback onBrowse;
  final String? hint;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SyncedTextField(
      label: label,
      hint: hint,
      value: value,
      enabled: enabled,
      onChanged: onChanged,
      suffix: IconButton(
        tooltip: 'Browse…',
        icon: const Icon(Icons.folder_open_outlined, size: 18),
        onPressed: enabled ? onBrowse : null,
      ),
    );
  }
}

class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: context.status.muted),
    ),
  );
}

/// Why a button is disabled, in the warning color.
class ProblemText extends StatelessWidget {
  const ProblemText(this.problems, {super.key});

  final List<String> problems;

  @override
  Widget build(BuildContext context) {
    if (problems.isEmpty) return const SizedBox.shrink();
    final color = context.status.warning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final problem in problems)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 14, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    problem,
                    style: TextStyle(fontSize: 12, color: color),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class CopyButton extends StatelessWidget {
  const CopyButton(this.text, {super.key, this.tooltip = 'Copy'});

  final String text;
  final String tooltip;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    iconSize: 16,
    icon: const Icon(Icons.copy_rounded),
    onPressed: () async {
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Copied'),
          duration: Duration(seconds: 1),
          width: 160,
          behavior: SnackBarBehavior.floating,
        ),
      );
    },
  );
}

/// A small colored label: "Release", "Verifies", "Built".
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, required this.color, this.icon});

  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: 0.45)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    ),
  );
}

/// A label and a selectable value, side by side.
class InfoRow extends StatelessWidget {
  const InfoRow(
    this.label,
    this.value, {
    super.key,
    this.mono = false,
    this.trailing,
  });

  final String label;
  final String value;
  final bool mono;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: TextStyle(fontSize: 12.5, color: context.status.muted),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: mono ? monospace : const TextStyle(fontSize: 13),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}
