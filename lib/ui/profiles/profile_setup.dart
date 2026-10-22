import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/profiles/profile.dart';
import '../../state/profiles.dart';
import '../../state/providers.dart';
import '../common/widgets.dart';
import '../theme.dart';
import 'targets_step.dart';

enum _Step { input, targets, fileName, after }

/// The profile's steps, each one summary line; the one being edited opens.
class ProfileSetup extends ConsumerStatefulWidget {
  const ProfileSetup({super.key, required this.profile});

  final SigningProfile profile;

  @override
  ConsumerState<ProfileSetup> createState() => _ProfileSetupState();
}

class _ProfileSetupState extends ConsumerState<ProfileSetup> {
  _Step? _open = _Step.targets;

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final notifier = ref.read(profilesProvider.notifier);
    void update(SigningProfile changed) => notifier.update(changed);

    Widget step(
      _Step id,
      int number,
      String title,
      String summary,
      Widget body, {
      List<String> problems = const [],
    }) => _StepTile(
      number: number,
      title: title,
      summary: summary,
      problems: problems,
      open: _open == id,
      onToggle: () => setState(() => _open = _open == id ? null : id),
      child: body,
    );

    final keys = profile.keyFiles.length;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        step(
          _Step.input,
          1,
          'Input',
          [
            profile.input.packageName ?? 'Any package',
            if (profile.input.mustBeUnsigned) 'must be unsigned',
          ].join(' · '),
          _InputStep(profile: profile, onChanged: update),
        ),
        step(
          _Step.targets,
          2,
          'Targets',
          profile.targets.isEmpty
              ? 'None yet'
              : '${profile.targets.length} '
                    'target${profile.targets.length == 1 ? '' : 's'} · '
                    '$keys key${keys == 1 ? '' : 's'}',
          TargetsStep(profile: profile, onChanged: update),
          problems: ref.watch(profileProblemsProvider(profile.id)),
        ),
        step(
          _Step.fileName,
          3,
          'File name',
          '${profile.fileNamePattern}.apk',
          _FileNameStep(profile: profile, onChanged: update),
        ),
        step(
          _Step.after,
          4,
          'After',
          profile.afterRun.label,
          _AfterStep(profile: profile, onChanged: update),
        ),
      ],
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({
    required this.number,
    required this.title,
    required this.summary,
    required this.open,
    required this.onToggle,
    required this.child,
    this.problems = const [],
  });

  final int number;
  final String title;
  final String summary;

  /// Counted after the summary, so a closed step still shows them.
  final List<String> problems;
  final bool open;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A Material, not a colored box: the step's list tiles (checkboxes,
    // radios) paint their background and splashes on it.
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: open
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.4)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: Theme.of(context).dividerColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: scheme.primaryContainer,
                      child: Text(
                        '$number',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    SizedBox(
                      width: 96,
                      child: Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              summary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: context.status.muted),
                            ),
                          ),
                          if (problems.isNotEmpty) ...[
                            const SizedBox(width: 12),
                            ProblemCount(problems),
                          ],
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Icon(
                        Icons.expand_more_rounded,
                        color: context.status.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (open)
              Padding(
                padding: const EdgeInsets.fromLTRB(56, 0, 16, 16),
                child: child,
              ),
          ],
        ),
      ),
    );
  }
}

class _InputStep extends StatelessWidget {
  const _InputStep({required this.profile, required this.onChanged});

  final SigningProfile profile;
  final ValueChanged<SigningProfile> onChanged;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 520),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SyncedTextField(
          label: 'Package name',
          hint: 'Empty: any package',
          value: profile.input.packageName ?? '',
          onChanged: (value) => onChanged(
            profile.copyWith(
              input: InputChecks(
                packageName: value.trim().isEmpty ? null : value.trim(),
                mustBeUnsigned: profile.input.mustBeUnsigned,
              ),
            ),
          ),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('The input must be unsigned'),
          value: profile.input.mustBeUnsigned,
          onChanged: (value) => onChanged(
            profile.copyWith(
              input: InputChecks(
                packageName: profile.input.packageName,
                mustBeUnsigned: value ?? false,
              ),
            ),
          ),
        ),
        Text(
          'The run stops before signing when an input doesn\'t match, and '
          'says why.',
          style: TextStyle(fontSize: 12.5, color: context.status.muted),
        ),
      ],
    ),
  );
}

class _FileNameStep extends ConsumerWidget {
  const _FileNameStep({required this.profile, required this.onChanged});

  final SigningProfile profile;
  final ValueChanged<SigningProfile> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final example = profile.targets.isEmpty ? null : profile.targets.first;
    final problems = fileNamePatternProblems(profile.fileNamePattern);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SyncedTextField(
            key: ValueKey('pattern-${profile.fileNamePattern.length}'),
            label: 'Pattern',
            value: profile.fileNamePattern,
            onChanged: (value) =>
                onChanged(profile.copyWith(fileNamePattern: value)),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final token in fileNameTokens)
                ActionChip(
                  label: Text(token, style: monospace.copyWith(fontSize: 12)),
                  onPressed: () => onChanged(
                    profile.copyWith(
                      fileNamePattern: '${profile.fileNamePattern}-$token',
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (problems.isNotEmpty)
            ProblemText(problems)
          else
            Text(
              'For app-release.apk 1.0.0: ${profileFileName(profile.fileNamePattern, name: 'app-release', target: example?.name ?? 'Phone', abi: example?.abiName ?? ProfileTarget.universalAbiName, versionName: '1.0.0', versionCode: '1', date: ref.watch(clockProvider)())}',
              style: TextStyle(fontSize: 12.5, color: context.status.muted),
            ),
        ],
      ),
    );
  }
}

class _AfterStep extends StatelessWidget {
  const _AfterStep({required this.profile, required this.onChanged});

  final SigningProfile profile;
  final ValueChanged<SigningProfile> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      RadioGroup<AfterRun>(
        groupValue: profile.afterRun,
        onChanged: (value) {
          if (value != null) onChanged(profile.copyWith(afterRun: value));
        },
        child: Column(
          children: [
            for (final value in AfterRun.values)
              RadioListTile<AfterRun>(
                value: value,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(value.label),
              ),
          ],
        ),
      ),
      Text(
        'Installing stays in Install, on the Workbench.',
        style: TextStyle(fontSize: 12.5, color: context.status.muted),
      ),
    ],
  );
}
