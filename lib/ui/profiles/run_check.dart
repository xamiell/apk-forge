import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/format.dart';
import '../../domain/analysis/apk_report.dart';
import '../../domain/profiles/profile.dart';
import '../../state/apks.dart';
import '../../state/profiles.dart';
import '../../state/providers.dart';
import '../../state/task_notifier.dart';
import '../common/file_types.dart';
import '../theme.dart';
import 'run_frame.dart';

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8, top: 4),
    child: Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        letterSpacing: 0.8,
        fontWeight: FontWeight.w700,
        color: context.status.muted,
      ),
    ),
  );
}

/// One line of the checks: passed, failed or under way.
class _CheckLine extends StatelessWidget {
  const _CheckLine({required this.ok, required this.text, this.detail});

  /// `null` while it's being checked.
  final bool? ok;
  final String text;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final colors = context.status;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: switch (ok) {
              true => Icon(Icons.check_rounded, size: 18, color: colors.ok),
              false => Icon(Icons.close_rounded, size: 18, color: colors.error),
              null => const Padding(
                padding: EdgeInsets.all(3),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    color: ok == false ? colors.error : null,
                  ),
                ),
                if (detail != null)
                  SelectableText(
                    detail!,
                    style: TextStyle(fontSize: 12, color: colors.muted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Before anything is signed: the inputs, the checks and the plan.
class RunCheckView extends ConsumerWidget {
  const RunCheckView({
    super.key,
    required this.profile,
    required this.inputs,
    required this.onInputs,
    required this.onRun,
  });

  final SigningProfile profile;
  final List<String> inputs;
  final ValueChanged<List<String>> onInputs;
  final ValueChanged<ProfileRunCheck> onRun;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(hostProvider);
    final colors = context.status;
    final busy = ref.watch(taskProvider.select((task) => task.isRunning));
    final selected = ref.watch(apkListProvider.select((l) => l.selectedPath));
    final check = inputs.isEmpty
        ? null
        : ref.watch(
            profileRunCheckProvider((
              profileId: profile.id,
              inputs: inputs.join('\n'),
            )),
          );
    final value = check?.value;

    Future<void> addApks() async {
      final files = await openFiles(acceptedTypeGroups: const [apkTypes]);
      onInputs([
        ...inputs,
        for (final file in files)
          if (!inputs.contains(file.path)) file.path,
      ]);
    }

    final footer = switch (check) {
      null => 'Pick the APK to run the profile on.',
      AsyncData(:final value) when value.canRun =>
        'Every key opened. Nothing is signed until you press Run.',
      AsyncData() => 'The run can\'t start yet: see the checks.',
      AsyncError(:final error) => '$error',
      _ => 'Checking…',
    };

    return RunDialogFrame(
      title: 'Run “${profile.name}”',
      onClose: () => Navigator.of(context).pop(),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Heading('Input'),
          for (final path in inputs)
            _InputRow(
              path: path,
              onRemove: () => onInputs([
                for (final p in inputs)
                  if (p != path) p,
              ]),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: addApks,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add APK…'),
              ),
              if (selected != null && !inputs.contains(selected))
                TextButton.icon(
                  onPressed: () => onInputs([...inputs, selected]),
                  icon: const Icon(Icons.android_rounded, size: 18),
                  label: Text(
                    'Use the selected APK, ${host.path.basename(selected)}',
                  ),
                ),
            ],
          ),
          if (check != null) ...[
            const SizedBox(height: 18),
            const _Heading('Checks before signing'),
            if (value == null)
              const _CheckLine(
                ok: null,
                text: 'Reading the APKs and opening the keys…',
              )
            else ...[
              for (final input in value.inputs) _InputCheck(report: input),
              for (final problem in value.plan.problems)
                _CheckLine(ok: false, text: problem),
              for (final key in value.keys?.values ?? const <Never>[])
                _CheckLine(
                  ok: true,
                  text:
                      '${shortPath(key.keyProperties, host)}: '
                      'key “${key.alias}” opens',
                  detail: key.sha256 == null
                      ? null
                      : 'SHA-256 ${shortDigest(key.sha256!)}',
                ),
              if (value.keyFailure != null)
                _CheckLine(
                  ok: false,
                  text: value.keyFailure!.title,
                  detail: value.keyFailure!.details.join('\n'),
                ),
            ],
          ],
          if (value != null && value.plan.jobs.isNotEmpty) ...[
            const SizedBox(height: 18),
            const _Heading('Plan'),
            RunPlanTable(check: value),
            const SizedBox(height: 8),
            Text(
              runPlanSummary(value),
              style: TextStyle(fontSize: 12.5, color: colors.muted),
            ),
          ],
        ],
      ),
      footer: [
        Expanded(
          child: Text(
            footer,
            style: TextStyle(
              fontSize: 12.5,
              color: check is AsyncData && !(value?.canRun ?? false)
                  ? colors.error
                  : colors.muted,
            ),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: value != null && value.canRun && !busy
              ? () => onRun(value)
              : null,
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Run'),
        ),
      ],
    );
  }
}

class _InputRow extends ConsumerWidget {
  const _InputRow({required this.path, required this.onRemove});

  final String path;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(hostProvider);
    final report = ref.watch(apkReportProvider(path)).value;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Row(
        children: [
          Icon(
            Icons.description_outlined,
            size: 20,
            color: context.status.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  host.path.basename(path),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  [
                    host.path.dirname(path),
                    if (report != null) formatBytes(report.sizeBytes),
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: context.status.muted),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _InputCheck extends ConsumerWidget {
  const _InputCheck({required this.report});

  final ApkReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(hostProvider);
    final badging = report.badging;
    final signed =
        (report.signature?.signers.isNotEmpty ?? false) ||
        report.hasJarSignature;
    return _CheckLine(
      ok: true,
      text:
          '${host.path.basename(report.path)}: '
          '${badging?.packageName ?? 'package unknown'}'
          '${badging?.versionName == null ? '' : ' ${badging!.versionName} (${badging.versionCode})'}'
          ', ${signed ? 'signed' : 'unsigned'}',
      detail: [
        report.contents.nativeLibraries.isEmpty
            ? 'No native code'
            : report.contents.nativeLibraries.keys.join(', '),
        formatBytes(report.sizeBytes),
      ].join(' · '),
    );
  }
}

/// "2 APKs to write, 1 skipped. The input is not modified."
String runPlanSummary(ProfileRunCheck check) {
  final plan = check.plan;
  return '${plan.outputCount} APK${plan.outputCount == 1 ? '' : 's'} to write'
      '${plan.skipped.isEmpty ? '' : ', ${plan.skipped.length} skipped'}. '
      'The input${check.inputs.length == 1 ? ' is' : 's are'} not modified.';
}

/// What a checked run writes, target by target, and what it skips: in the
/// Run dialog, and when an agent asks to run.
class RunPlanTable extends ConsumerWidget {
  const RunPlanTable({super.key, required this.check});

  final ProfileRunCheck check;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(hostProvider);
    final colors = context.status;
    final several = check.inputs.length > 1;
    String keyName(String file) =>
        check.keys?[file]?.alias ?? host.path.basename(file);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 36,
        dataRowMinHeight: 36,
        dataRowMaxHeight: 52,
        columns: [
          const DataColumn(label: Text('Target')),
          if (several) const DataColumn(label: Text('Input')),
          const DataColumn(label: Text('ABI')),
          const DataColumn(label: Text('Key')),
          const DataColumn(label: Text('Writes')),
        ],
        rows: [
          for (final job in check.plan.jobs)
            for (final output in job.outputs)
              DataRow(
                cells: [
                  DataCell(Text(output.target.name)),
                  if (several)
                    DataCell(Text(host.path.basename(job.input.path))),
                  DataCell(Text(output.target.abiName)),
                  DataCell(Text(keyName(job.keyProperties))),
                  DataCell(
                    Tooltip(
                      message: output.path,
                      child: Text(
                        shortPath(output.path, host),
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                  ),
                ],
              ),
          for (final skipped in check.plan.skipped)
            DataRow(
              cells: [
                DataCell(Text(skipped.target.name)),
                if (several)
                  DataCell(Text(host.path.basename(skipped.input.path))),
                DataCell(Text(skipped.target.abiName)),
                DataCell(Text(keyName(skipped.target.keyProperties))),
                DataCell(
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: colors.warning,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Skipped: ${skipped.reason}',
                        style: TextStyle(color: colors.warning, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
