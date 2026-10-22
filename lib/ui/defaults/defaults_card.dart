import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/build/build_options.dart';
import '../../state/forms.dart';
import '../common/widgets.dart';
import '../theme.dart';

/// What Build and Sign share: the architectures and the signature schemes.
/// Set once, it folds into one line.
class DefaultsCard extends ConsumerWidget {
  const DefaultsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final defaults = ref.watch(defaultsProvider);
    final notifier = ref.read(defaultsProvider.notifier);
    final colors = context.status;

    if (defaults.folded) {
      return _FoldedDefaults(
        summary: defaultsSummary(defaults),
        onOpen: () => notifier.update((d) => d.copyWith(folded: false)),
      );
    }

    return SectionCard(
      title: 'Defaults',
      icon: Icons.tune_rounded,
      trailing: IconButton(
        tooltip: 'Fold into one line',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.unfold_less_rounded, size: 20),
        onPressed: () => notifier.update((d) => d.copyWith(folded: true)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Used by Build and by Sign. Set them once; each card says when '
            'it uses them.',
            style: TextStyle(fontSize: 12.5, color: colors.muted),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Expanded(child: FieldLabel('Architectures')),
              TextButton(
                onPressed: () => notifier.update(
                  (d) => d.copyWith(abis: AndroidAbi.values.toSet()),
                ),
                child: const Text('All'),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final abi in AndroidAbi.values)
                Tooltip(
                  message: abi.description,
                  child: FilterChip(
                    label: Text(abi.abiName),
                    selected: defaults.abis.contains(abi),
                    onSelected: (_) => notifier.toggleAbi(abi),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (defaults.abis.isEmpty)
            const ProblemText(['Choose at least one: Build needs it.'])
          else
            Text(
              'Build targets them. Split per ABI and sign writes one APK '
              'for each.',
              style: TextStyle(fontSize: 12, color: colors.muted),
            ),
          const SizedBox(height: 14),
          const FieldLabel('Signature schemes'),
          SchemesField(
            schemes: defaults.schemes,
            onChanged: (schemes) =>
                notifier.update((d) => d.copyWith(schemes: schemes)),
          ),
        ],
      ),
    );
  }
}

/// "arm64-v8a · schemes v2, v3".
String defaultsSummary(WorkbenchDefaults defaults) {
  final abis = switch (defaults.abis.length) {
    0 => 'No architecture',
    final n when n == AndroidAbi.values.length => 'All architectures',
    _ => defaults.abiNames.join(', '),
  };
  return '$abis · schemes ${defaults.schemes.label}';
}

class _FoldedDefaults extends StatelessWidget {
  const _FoldedDefaults({required this.summary, required this.onOpen});

  final String summary;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 10, 0),
            child: Row(
              children: [
                Icon(
                  Icons.tune_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Defaults',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: context.status.muted,
                    ),
                  ),
                ),
                Tooltip(
                  message: 'Open',
                  child: Icon(
                    Icons.unfold_more_rounded,
                    size: 20,
                    color: context.status.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
