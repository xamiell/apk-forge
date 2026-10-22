import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/format.dart';
import '../../domain/profiles/profile.dart';
import '../../domain/profiles/profile_run.dart';
import '../../state/profiles.dart';
import '../../state/task_notifier.dart';
import '../common/file_types.dart';
import '../common/widgets.dart';
import '../theme.dart';
import 'profile_history.dart';
import 'profile_setup.dart';
import 'run_dialog.dart';

/// Where profiles are set up: the list on the left, the selected profile's
/// Setup or History on the right.
class ProfilesView extends ConsumerWidget {
  const ProfilesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(profilesProvider.select((s) => s.selected));
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(width: 280, child: _ProfileList()),
          const SizedBox(width: 16),
          Expanded(
            child: selected == null
                ? const _NoProfile()
                : _ProfileEditor(profile: selected),
          ),
        ],
      ),
    );
  }
}

class _ProfileList extends ConsumerWidget {
  const _ProfileList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(profilesProvider);
    final history = ref.watch(profileHistoryProvider);
    final notifier = ref.read(profilesProvider.notifier);

    Future<void> import() async {
      final file = await openFile(acceptedTypeGroups: const [profileTypes]);
      if (file == null) return;
      final SigningProfile profile;
      try {
        profile = importProfile(await file.readAsString());
      } on FormatException catch (error) {
        if (context.mounted) _snack(context, error.message);
        return;
      }
      // A name already in the list gets a number.
      final id = notifier.add(profile);
      final name = ref.read(profilesProvider).byId(id)!.name;
      final problems = ref.read(profileProblemsProvider(id));
      if (!context.mounted) return;
      if (problems.isEmpty) {
        _snack(context, 'Imported $name.');
      } else {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Imported $name'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'It can\'t run on this machine yet. Fix these in each '
                    'target first:',
                  ),
                  const SizedBox(height: 10),
                  ProblemText(problems),
                ],
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }

    return SectionCard(
      title: 'Profiles',
      icon: Icons.layers_outlined,
      expand: true,
      trailing: IconButton(
        tooltip: 'New profile',
        icon: const Icon(Icons.add_rounded),
        onPressed: notifier.create,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: [
                for (final profile in state.profiles)
                  ListTile(
                    selected: profile.id == state.selectedId,
                    selectedTileColor: Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withValues(alpha: 0.35),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    title: Text(
                      profile.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _profileLine(
                            profile,
                            history
                                .where((r) => r.profileId == profile.id)
                                .firstOrNull,
                          ),
                          style: const TextStyle(fontSize: 12),
                        ),
                        ProblemCount(
                          ref.watch(profileProblemsProvider(profile.id)),
                        ),
                      ],
                    ),
                    onTap: () => notifier.select(profile.id),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: OutlinedButton.icon(
              onPressed: import,
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Import profile…'),
            ),
          ),
        ],
      ),
    );
  }

  static String _profileLine(SigningProfile profile, ProfileRunRecord? last) {
    final targets = profile.targets.length;
    final keys = profile.keyFiles.length;
    return [
      '$targets target${targets == 1 ? '' : 's'}',
      '$keys key${keys == 1 ? '' : 's'}',
      if (last != null) 'last run ${formatDateTime(last.startedAt)}',
    ].join(' · ');
  }
}

class _NoProfile extends ConsumerWidget {
  const _NoProfile();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Card(
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.layers_outlined, size: 48, color: context.status.muted),
          const SizedBox(height: 10),
          const Text('No profiles yet'),
          const SizedBox(height: 4),
          Text(
            'A profile saves the steps to turn one APK into a signed APK per '
            'device: each with its ABI, its key and its folder.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: context.status.muted),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: ref.read(profilesProvider.notifier).create,
            icon: const Icon(Icons.add_rounded),
            label: const Text('New profile'),
          ),
        ],
      ),
    ),
  );
}

class _ProfileEditor extends ConsumerWidget {
  const _ProfileEditor({required this.profile});

  final SigningProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(profileTabProvider);
    final notifier = ref.read(profilesProvider.notifier);
    final busy = ref.watch(taskProvider.select((task) => task.isRunning));

    Future<void> export() async {
      final location = await getSaveLocation(
        suggestedName: '${profile.name}.json',
        acceptedTypeGroups: const [profileTypes],
      );
      if (location == null) return;
      await XFile.fromData(
        utf8.encode(exportProfile(profile)),
        mimeType: 'application/json',
      ).saveTo(location.path);
      if (context.mounted) _snack(context, 'Exported to ${location.path}.');
    }

    Future<void> delete() async {
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Delete ${profile.name}?'),
          content: const Text(
            'Its history goes too. The signed APKs and the key.properties '
            'files stay where they are.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (sure ?? false) notifier.delete(profile.id);
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 260,
                  child: SyncedTextField(
                    key: ValueKey('name-${profile.id}'),
                    label: 'Profile',
                    value: profile.name,
                    onChanged: (name) =>
                        notifier.update(profile.copyWith(name: name)),
                  ),
                ),
                SegmentedButton<ProfileTab>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: ProfileTab.setup,
                      label: Text('Setup'),
                    ),
                    ButtonSegment(
                      value: ProfileTab.history,
                      label: Text('History'),
                    ),
                  ],
                  selected: {tab},
                  onSelectionChanged: (choice) =>
                      ref.read(profileTabProvider.notifier).show(choice.single),
                ),
                IconButton(
                  tooltip: 'Duplicate profile',
                  icon: const Icon(Icons.copy_rounded, size: 20),
                  onPressed: () => notifier.duplicate(profile.id),
                ),
                OutlinedButton.icon(
                  onPressed: export,
                  icon: const Icon(Icons.upload_rounded, size: 18),
                  label: const Text('Export…'),
                ),
                IconButton(
                  tooltip: 'Delete profile',
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 20,
                    color: context.status.error,
                  ),
                  onPressed: delete,
                ),
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () => showRunProfileDialog(context, profile.id),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Run…'),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: tab == ProfileTab.setup
                ? ProfileSetup(
                    key: ValueKey('setup-${profile.id}'),
                    profile: profile,
                  )
                : ProfileHistory(profile: profile),
          ),
        ],
      ),
    );
  }
}

void _snack(BuildContext context, String message) =>
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
