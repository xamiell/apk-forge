import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/process/command.dart';
import '../../domain/build/build_options.dart';
import '../../domain/build/flutter_build.dart';
import '../../state/actions.dart';
import '../../state/forms.dart';
import '../../state/providers.dart';
import '../../state/task_notifier.dart';
import '../../state/toolchain_notifier.dart';
import '../common/widgets.dart';
import '../theme.dart';

class BuildCard extends ConsumerWidget {
  const BuildCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(buildOptionsProvider);
    final notifier = ref.read(buildOptionsProvider.notifier);
    final host = ref.watch(hostProvider);
    final signingProblem = ref.watch(signingProblemProvider);
    final busy = ref.watch(taskProvider.select((task) => task.isRunning));
    final canBuild = ref.watch(
      toolchainProvider.select((t) => t.value?.canBuild ?? false),
    );

    final problems = [
      if (!canBuild) 'flutter was not found. Set it in Tools.',
      ...buildProblems(options, host, ref.watch(fileProbeProvider)),
      if (options.signAfterBuild && signingProblem != null)
        'Signing: $signingProblem',
    ];
    final release = options.mode == BuildMode.release;

    return SectionCard(
      title: 'Build',
      icon: Icons.construction_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PathField(
            label: 'Flutter project',
            hint: 'Folder with pubspec.yaml',
            value: options.projectDir,
            onChanged: (value) =>
                notifier.update((o) => o.copyWith(projectDir: value)),
            onBrowse: () async {
              final folder = await getDirectoryPath(
                confirmButtonText: 'Choose project',
              );
              if (folder != null) {
                notifier.setProject(
                  folder,
                  defaultSymbolsDir: (project) =>
                      host.path.join(project, 'build', 'symbols'),
                );
              }
            },
          ),
          const SizedBox(height: 14),
          const FieldLabel('Build type'),
          SegmentedButton<BuildMode>(
            segments: [
              for (final mode in BuildMode.values)
                ButtonSegment(value: mode, label: Text(mode.label)),
            ],
            selected: {options.mode},
            showSelectedIcon: false,
            onSelectionChanged: (selection) =>
                notifier.update((o) => o.copyWith(mode: selection.single)),
          ),
          const SizedBox(height: 14),
          const FieldLabel('Architectures'),
          FromDefaults(
            options.abis.isEmpty
                ? 'None chosen: Build needs one.'
                : [
                    for (final abi in AndroidAbi.values)
                      if (options.abis.contains(abi)) abi.abiName,
                  ].join(', '),
            warning: options.abis.isEmpty,
          ),
          const SizedBox(height: 14),
          const FieldLabel('Output'),
          SegmentedButton<ApkPackaging>(
            segments: [
              for (final packaging in ApkPackaging.values)
                ButtonSegment(
                  value: packaging,
                  label: Text(packaging.label),
                  enabled:
                      packaging != ApkPackaging.splitPerAbi || options.canSplit,
                  tooltip:
                      packaging == ApkPackaging.splitPerAbi && !options.canSplit
                      ? 'Choose two or more architectures in Defaults to split'
                      : null,
                ),
            ],
            selected: {options.effectivePackaging},
            showSelectedIcon: false,
            onSelectionChanged: (selection) =>
                notifier.update((o) => o.copyWith(packaging: selection.single)),
          ),
          const SizedBox(height: 6),
          Text(
            _outputSummary(options),
            style: TextStyle(fontSize: 12, color: context.status.muted),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Obfuscate Dart code'),
            subtitle: Text(
              release
                  ? 'Keeps the symbols to read crash stack traces. R8 (Java/Kotlin) is the project\'s Gradle setting.'
                  : 'Release builds only.',
              style: const TextStyle(fontSize: 12),
            ),
            value: options.obfuscate && release,
            onChanged: release
                ? (value) =>
                      notifier.update((o) => o.copyWith(obfuscate: value))
                : null,
          ),
          if (options.effectiveObfuscate) ...[
            const SizedBox(height: 6),
            PathField(
              label: 'Symbols folder (--split-debug-info)',
              value: options.symbolsDir,
              onChanged: (value) =>
                  notifier.update((o) => o.copyWith(symbolsDir: value)),
              onBrowse: () async {
                final folder = await getDirectoryPath(
                  confirmButtonText: 'Choose folder',
                );
                if (folder != null) {
                  notifier.update((o) => o.copyWith(symbolsDir: folder));
                }
              },
            ),
          ],
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Sign the APKs with the key in Sign'),
            subtitle: const Text(
              'Off: they keep Gradle\'s signature (debug key, or the project\'s key.properties).',
              style: TextStyle(fontSize: 12),
            ),
            value: options.signAfterBuild,
            onChanged: (value) => notifier.update(
              (o) => o.copyWith(signAfterBuild: value ?? false),
            ),
          ),
          const SizedBox(height: 8),
          _CommandPreview(options: options),
          const SizedBox(height: 10),
          ProblemText(problems),
          const SizedBox(height: 6),
          FilledButton.icon(
            onPressed: problems.isEmpty && !busy
                ? () => ref.read(actionsProvider).build()
                : null,
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(options.signAfterBuild ? 'Build and sign' : 'Build'),
          ),
        ],
      ),
    );
  }
}

String _outputSummary(BuildOptions options) {
  final count = options.abis.length;
  if (count == 0) return 'Choose an architecture in Defaults.';
  if (options.effectivePackaging == ApkPackaging.splitPerAbi) {
    return 'One APK per architecture: $count APKs.';
  }
  if (count == 1) {
    return 'One APK for ${options.abis.single.abiName}. Split needs two or '
        'more architectures.';
  }
  return count == AndroidAbi.values.length
      ? 'One APK with every architecture.'
      : 'One APK with the $count architectures in Defaults.';
}

/// The exact command the button runs, so nothing happens behind the user's
/// back.
class _CommandPreview extends StatelessWidget {
  const _CommandPreview({required this.options});

  final BuildOptions options;

  @override
  Widget build(BuildContext context) {
    final line = [
      'flutter',
      ...flutterBuildArguments(options),
    ].map(shellQuote).join(' ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.status.logBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: SelectableText(
        line,
        style: monospace.copyWith(color: context.status.command),
      ),
    );
  }
}
