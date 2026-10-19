import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/format.dart';
import '../../state/actions.dart';
import '../../state/forms.dart';
import '../../state/profiles.dart';
import '../../state/task_notifier.dart';
import '../../state/toolchain_notifier.dart';
import '../common/file_types.dart';
import '../common/widgets.dart';
import '../profiles/run_dialog.dart';
import '../theme.dart';

class SigningCard extends ConsumerWidget {
  const SigningCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = ref.watch(signingFormProvider);
    final notifier = ref.read(signingFormProvider.notifier);
    final busy = ref.watch(taskProvider.select((task) => task.isRunning));
    final toolchain = ref.watch(toolchainProvider).value;
    final actions = ref.read(actionsProvider);
    final entry = form.selectedEntry;

    final problems = [
      if (toolchain != null && !toolchain.canSign)
        'apksigner was not found (Android SDK build-tools).',
      ?form.problem,
    ];

    void loadKeys() {
      if (form.canLoadKeys && !busy) actions.loadKeys();
    }

    final canSign = problems.isEmpty && !busy;
    Future<void> pickApks(Future<void> Function(List<String>) action) async {
      final files = await openFiles(acceptedTypeGroups: const [apkTypes]);
      if (files.isNotEmpty) await action([for (final f in files) f.path]);
    }

    return SectionCard(
      title: 'Sign',
      icon: Icons.verified_user_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PathField(
            label: 'Keystore',
            hint: '.jks, .keystore or .p12',
            value: form.keystorePath,
            onChanged: (value) => notifier.update(
              (f) => f.copyWith(
                keystorePath: value,
                entries: const [],
                clearAlias: true,
              ),
            ),
            onBrowse: () async {
              final file = await openFile(
                acceptedTypeGroups: const [
                  keystoreTypes,
                  XTypeGroup(label: 'All files'),
                ],
              );
              if (file != null) notifier.setKeystore(file.path);
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SyncedTextField(
                  label: 'Keystore password',
                  value: form.storePassword,
                  obscure: true,
                  onChanged: notifier.setStorePassword,
                  onSubmitted: (_) => loadKeys(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed:
                    form.canLoadKeys &&
                        !busy &&
                        (toolchain?.canReadKeystore ?? false)
                    ? loadKeys
                    : null,
                child: const Text('Load keys'),
              ),
            ],
          ),
          if (form.entries.isNotEmpty) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: form.alias,
              decoration: const InputDecoration(labelText: 'Key (alias)'),
              items: [
                for (final e in form.entries)
                  DropdownMenuItem(
                    value: e.alias,
                    enabled: e.canSign,
                    child: Text(
                      e.canSign ? e.alias : '${e.alias} (certificate only)',
                    ),
                  ),
              ],
              onChanged: (alias) =>
                  notifier.update((f) => f.copyWith(alias: alias)),
            ),
            if (entry != null) ...[
              const SizedBox(height: 8),
              InfoRow('Owner', entry.owner ?? '?'),
              if (entry.sha256 != null)
                InfoRow(
                  'SHA-256',
                  shortDigest(entry.sha256!),
                  mono: true,
                  trailing: CopyButton(
                    colonDigest(entry.sha256!),
                    tooltip: 'Copy SHA-256',
                  ),
                ),
              if (entry.validUntil != null)
                InfoRow('Valid until', entry.validUntil!),
              if (entry.keyAlgorithm != null)
                InfoRow('Key', entry.keyAlgorithm!),
            ],
          ],
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('The key uses the keystore password'),
            value: form.keyUsesStorePassword,
            onChanged: (value) => notifier.update(
              (f) => f.copyWith(keyUsesStorePassword: value ?? true),
            ),
          ),
          if (!form.keyUsesStorePassword) ...[
            SyncedTextField(
              label: 'Key password',
              value: form.keyPassword,
              obscure: true,
              onChanged: (value) =>
                  notifier.update((f) => f.copyWith(keyPassword: value)),
            ),
            const SizedBox(height: 8),
          ],
          SchemesField(
            schemes: form.schemes,
            onChanged: (s) => notifier.update((f) => f.copyWith(schemes: s)),
          ),
          const SizedBox(height: 12),
          PathField(
            label: 'Output folder',
            hint: 'Empty: next to each APK',
            value: form.outputDir,
            onChanged: (value) =>
                notifier.update((f) => f.copyWith(outputDir: value)),
            onBrowse: () async {
              final folder = await getDirectoryPath(
                confirmButtonText: 'Choose folder',
              );
              if (folder != null) {
                notifier.update((f) => f.copyWith(outputDir: folder));
              }
            },
          ),
          const SizedBox(height: 6),
          Text(
            'Writes <name>-signed.apk and never touches the original. '
            'Passwords stay in memory and are never saved.',
            style: TextStyle(fontSize: 12, color: context.status.muted),
          ),
          const SizedBox(height: 10),
          ProblemText(problems),
          const SizedBox(height: 6),
          FilledButton.icon(
            onPressed: canSign ? () => pickApks(actions.signFiles) : null,
            icon: const Icon(Icons.draw_outlined),
            label: const Text('Sign APK files…'),
          ),
          const SizedBox(height: 8),
          Tooltip(
            message:
                'From a universal APK, one signed APK per ABI: '
                '<name>-<abi>-signed.apk. They keep its versionCode, which is '
                'fine to install or share; Google Play needs a different one '
                'per APK.',
            child: OutlinedButton.icon(
              onPressed: canSign
                  ? () => pickApks(actions.splitAndSignFiles)
                  : null,
              icon: const Icon(Icons.call_split),
              label: const Text('Split per ABI and sign…'),
            ),
          ),
          const SizedBox(height: 14),
          const Divider(),
          const SizedBox(height: 10),
          const _ProfilesEntry(),
        ],
      ),
    );
  }
}

/// The Workbench's one way into profiles: run one, or go set them up. A
/// profile carries its own keys, so it runs without a keystore loaded here.
class _ProfilesEntry extends ConsumerWidget {
  const _ProfilesEntry();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider).profiles;
    final history = ref.watch(profileHistoryProvider);
    final busy = ref.watch(taskProvider.select((task) => task.isRunning));
    final last = history.isEmpty ? null : history.first;

    void manage() => ref.read(appViewProvider.notifier).show(AppView.profiles);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Profiles',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(onPressed: manage, child: const Text('Manage profiles')),
          ],
        ),
        const SizedBox(height: 4),
        MenuAnchor(
          menuChildren: [
            for (final profile in profiles)
              MenuItemButton(
                onPressed: () => showRunProfileDialog(context, profile.id),
                trailingIcon: Text(
                  '${profile.targets.length} '
                  'target${profile.targets.length == 1 ? '' : 's'}',
                  style: TextStyle(fontSize: 12, color: context.status.muted),
                ),
                child: Text(profile.name),
              ),
            if (profiles.isNotEmpty) const Divider(),
            MenuItemButton(
              leadingIcon: const Icon(Icons.tune_rounded, size: 18),
              onPressed: manage,
              child: Text(
                profiles.isEmpty ? 'Create a profile…' : 'Manage profiles…',
              ),
            ),
          ],
          builder: (context, controller, _) => FilledButton.icon(
            onPressed: busy
                ? null
                : () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Run profile…'),
          ),
        ),
        if (last != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.history_rounded,
                size: 16,
                color: context.status.muted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Last run, ${last.profileName}: ${last.summary}.',
                  style: TextStyle(fontSize: 12, color: context.status.muted),
                ),
              ),
              TextButton(
                onPressed: () {
                  ref.read(profilesProvider.notifier).select(last.profileId);
                  ref
                      .read(profileTabProvider.notifier)
                      .show(ProfileTab.history);
                  manage();
                },
                child: const Text('View results'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
