import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/analysis/comparison.dart';
import '../../domain/analysis/findings.dart';
import '../../domain/failure.dart';
import '../../state/apks.dart';
import '../../state/devices.dart';
import '../../state/providers.dart';
import '../common/widgets.dart';
import '../theme.dart';

/// Compares [candidate] with [reference], two APKs of the list, in a
/// dialog. The selected APK is the candidate: the one that would be
/// installed over the reference.
Future<void> showApkComparison(
  BuildContext context, {
  required String reference,
  required String candidate,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      _ApkComparisonDialog(reference: reference, candidate: candidate),
);

class _ApkComparisonDialog extends ConsumerStatefulWidget {
  const _ApkComparisonDialog({
    required this.reference,
    required this.candidate,
  });

  final String reference;
  final String candidate;

  @override
  ConsumerState<_ApkComparisonDialog> createState() =>
      _ApkComparisonDialogState();
}

class _ApkComparisonDialogState extends ConsumerState<_ApkComparisonDialog> {
  late String _reference = widget.reference;
  late String _candidate = widget.candidate;

  @override
  Widget build(BuildContext context) {
    final host = ref.watch(hostProvider);
    return ComparisonDialog(
      referenceTitle: 'Reference',
      referenceName: host.path.basename(_reference),
      candidateTitle: 'Compared',
      candidateName: host.path.basename(_candidate),
      comparison: ref.watch(
        apkComparisonProvider((reference: _reference, candidate: _candidate)),
      ),
      onSwap: () => setState(() {
        final reference = _reference;
        _reference = _candidate;
        _candidate = reference;
      }),
    );
  }
}

/// Compares [candidate], an APK of the list, with the app of [package]
/// installed on the device [serial], in a dialog.
Future<void> showInstalledComparison(
  BuildContext context, {
  required String serial,
  required String deviceName,
  required String package,
  required String candidate,
}) => showDialog<void>(
  context: context,
  builder: (_) => _InstalledComparisonDialog(
    serial: serial,
    deviceName: deviceName,
    package: package,
    candidate: candidate,
  ),
);

class _InstalledComparisonDialog extends ConsumerWidget {
  const _InstalledComparisonDialog({
    required this.serial,
    required this.deviceName,
    required this.package,
    required this.candidate,
  });

  final String serial;
  final String deviceName;
  final String package;
  final String candidate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(hostProvider);
    final files = ref
        .watch(installedApkProvider((serial: serial, package: package)))
        .value
        ?.files;
    return ComparisonDialog(
      referenceTitle: 'Installed',
      referenceName: '$package on $deviceName',
      referenceDetail: files == null || !files.isSplit
          ? null
          : 'Installed as splits: ${files.pulledNames} compared'
                '${files.notPulled.isEmpty ? '' : '; ${files.notPulledNames} '
                          'left out (resources only)'}. '
                'Size and hashes are of those files.',
      referenceInText: 'the installed app',
      candidateTitle: 'Selected',
      candidateName: host.path.basename(candidate),
      comparison: ref.watch(
        installedComparisonProvider((
          serial: serial,
          package: package,
          candidate: candidate,
        )),
      ),
      missing:
          '$package is not installed on $deviceName: installing the '
          'selected APK would be a fresh install.',
    );
  }
}

/// The frame every comparison shares: the two sides named at the top, the
/// verdicts, the differences, then what is the same.
class ComparisonDialog extends StatelessWidget {
  const ComparisonDialog({
    super.key,
    required this.referenceTitle,
    required this.referenceName,
    required this.candidateTitle,
    required this.candidateName,
    required this.comparison,
    this.referenceDetail,
    this.referenceInText,
    this.missing,
    this.onSwap,
  });

  /// "Reference", "Installed".
  final String referenceTitle;
  final String referenceName;

  /// What the reference side is made of, when it isn't one APK.
  final String? referenceDetail;

  /// How the verdicts name the reference ("the installed app");
  /// [referenceName] by default.
  final String? referenceInText;

  /// "Compared", "Selected".
  final String candidateTitle;
  final String candidateName;

  /// `null` when there is nothing to compare with; [missing] says why.
  final AsyncValue<ApkComparison?> comparison;
  final String? missing;
  final VoidCallback? onSwap;

  @override
  Widget build(BuildContext context) {
    final colors = context.status;
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
              child: Row(
                children: [
                  Icon(
                    Icons.compare_arrows_rounded,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Compare APKs',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (onSwap != null)
                    IconButton(
                      tooltip: 'Swap the two',
                      icon: const Icon(Icons.swap_horiz_rounded),
                      onPressed: onSwap,
                    ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: _Columns(
                label: const SizedBox.shrink(),
                reference: _Side(
                  title: referenceTitle,
                  name: referenceName,
                  detail: referenceDetail,
                ),
                candidate: _Side(title: candidateTitle, name: candidateName),
              ),
            ),
            const Divider(),
            Flexible(
              child: switch (comparison) {
                AsyncData(value: final value?) => SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  child: ComparisonView(
                    comparison: value,
                    referenceName: referenceInText ?? referenceName,
                    candidateName: candidateName,
                  ),
                ),
                AsyncData() => Padding(
                  padding: const EdgeInsets.all(24),
                  child: FindingList(
                    findings: [
                      Finding(
                        FindingLevel.info,
                        'Nothing to compare with',
                        missing,
                      ),
                    ],
                  ),
                ),
                AsyncError(:final error) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: SelectableText(
                    error is ToolFailure
                        ? [error.title, ...error.details].join('\n')
                        : '$error',
                    style: TextStyle(color: colors.error),
                  ),
                ),
                _ => const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The verdicts, the differences worst first, the permissions that changed,
/// and the values that are the same, folded.
class ComparisonView extends StatelessWidget {
  const ComparisonView({
    super.key,
    required this.comparison,
    required this.referenceName,
    required this.candidateName,
  });

  final ApkComparison comparison;
  final String referenceName;
  final String candidateName;

  @override
  Widget build(BuildContext context) {
    final colors = context.status;
    final differences = comparison.differences;
    final identical = comparison.identical;
    final permissionsChanged =
        comparison.permissionsAdded.isNotEmpty ||
        comparison.permissionsRemoved.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FindingList(
          findings: comparisonFindings(
            comparison,
            reference: referenceName,
            candidate: candidateName,
          ),
        ),
        const SizedBox(height: 14),
        _Heading(
          differences.isEmpty
              ? 'No differences'
              : '${differences.length} '
                    'difference${differences.length == 1 ? '' : 's'}',
        ),
        for (final field in differences) _FieldRow(field: field),
        if (permissionsChanged) ...[
          const SizedBox(height: 14),
          const _Heading('Permissions'),
          for (final permission in comparison.permissionsAdded)
            _PermissionRow(
              permission,
              icon: Icons.add_rounded,
              color: colors.warning,
              tooltip: 'Added in $candidateName',
            ),
          for (final permission in comparison.permissionsRemoved)
            _PermissionRow(
              permission,
              icon: Icons.remove_rounded,
              color: colors.muted,
              tooltip: 'Removed in $candidateName',
            ),
        ],
        if (identical.isNotEmpty) ...[
          const SizedBox(height: 6),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              '${identical.length} '
              'value${identical.length == 1 ? ' is' : 's are'} the same',
              style: const TextStyle(fontSize: 13),
            ),
            children: [for (final field in identical) _FieldRow(field: field)],
          ),
        ],
      ],
    );
  }
}

const _labelWidth = 200.0;

/// A label column and two value columns, so the header and every row line
/// up.
class _Columns extends StatelessWidget {
  const _Columns({
    required this.label,
    required this.reference,
    required this.candidate,
  });

  final Widget label;
  final Widget reference;
  final Widget candidate;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(width: _labelWidth, child: label),
      Expanded(child: reference),
      const SizedBox(width: 16),
      Expanded(child: candidate),
    ],
  );
}

class _Side extends StatelessWidget {
  const _Side({required this.title, required this.name, this.detail});

  final String title;
  final String name;
  final String? detail;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          letterSpacing: 0.8,
          fontWeight: FontWeight.w700,
          color: context.status.muted,
        ),
      ),
      const SizedBox(height: 2),
      SelectableText(
        name,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
      ),
      if (detail != null)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            detail!,
            style: TextStyle(fontSize: 12, color: context.status.muted),
          ),
        ),
    ],
  );
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
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

/// One value on both sides. A difference that matters is tinted in its
/// level's color, with the reason under it.
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.field});

  final ComparedField field;

  @override
  Widget build(BuildContext context) {
    final colors = context.status;
    final color = colors.forFinding(field.level);
    final matters =
        field.differs && field.level.index >= FindingLevel.warning.index;
    final mono = field.label.contains('SHA') || field.label == 'MD5';

    Widget value(String? text, {bool emphasize = false}) => text == null
        ? Text('—', style: TextStyle(color: colors.muted))
        : SelectableText(
            text,
            style: (mono ? monospace : const TextStyle(fontSize: 13)).copyWith(
              fontWeight: emphasize ? FontWeight.w600 : null,
              color: emphasize && matters ? color : null,
            ),
          );

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: matters
          ? BoxDecoration(
              color: color.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Columns(
            label: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  field.label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  field.section,
                  style: TextStyle(fontSize: 11.5, color: colors.muted),
                ),
              ],
            ),
            reference: value(field.reference),
            candidate: value(field.candidate, emphasize: field.differs),
          ),
          if (field.differs && field.note != null)
            Padding(
              padding: const EdgeInsets.only(left: _labelWidth, top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(findingIcon(field.level), size: 14, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      field.note!,
                      style: TextStyle(fontSize: 12.5, color: color),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow(
    this.permission, {
    required this.icon,
    required this.color,
    required this.tooltip,
  });

  final String permission;
  final IconData icon;
  final Color color;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 10),
    child: Row(
      children: [
        Tooltip(
          message: tooltip,
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText(
            permission.replaceFirst('android.permission.', ''),
            style: monospace,
          ),
        ),
      ],
    ),
  );
}
