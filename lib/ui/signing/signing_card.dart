import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/format.dart';
import '../../domain/signing/abi_split.dart';
import '../../state/actions/load_keys_action.dart';
import '../../state/actions/sign_actions.dart';
import '../../state/apks.dart';
import '../../state/forms.dart';
import '../../state/providers.dart';
import '../../state/profiles.dart';
import '../../state/task_notifier.dart';
import '../../state/toolchain_notifier.dart';
import '../common/file_types.dart';
import '../common/widgets.dart';
import '../profiles/run_dialog.dart';
import '../theme.dart';
import 'new_key_sheet.dart';

class SigningCard extends ConsumerWidget {
  const SigningCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = ref.watch(signingFormProvider);
    final notifier = ref.read(signingFormProvider.notifier);
    final busy = ref.watch(taskProvider.select((task) => task.isRunning));
    final toolchain = ref.watch(toolchainProvider).value;
    final entry = form.selectedEntry;

    final schemes = ref.watch(defaultsProvider.select((d) => d.schemes));
    final problems = ref.watch(signProblemsProvider);

    void loadKeys() {
      if (form.canLoadKeys && !busy) ref.read(loadKeysActionProvider).run();
    }

    return SectionCard(
      title: 'Sign',
      icon: Icons.verified_user_outlined,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message:
                'Empty the keystore, its password and the key. The output '
                'folder stays, and nothing on disk changes.',
            child: TextButton(
              onPressed: form.canClear && !busy ? notifier.clear : null,
              child: const Text('Clear'),
            ),
          ),
          const SizedBox(width: 6),
          FilledButton.tonalIcon(
            onPressed: () => showNewKeySheet(context),
            icon: const Icon(Icons.key_outlined, size: 16),
            label: const Text('New key…'),
          ),
        ],
      ),
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
          const SizedBox(height: 4),
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
            'Writes <name>-signed.apk (or .aab) and never touches the '
            'original. '
            'Passwords stay in memory and are never saved.',
            style: TextStyle(fontSize: 12, color: context.status.muted),
          ),
          const SizedBox(height: 10),
          FromDefaults(
            'Schemes: ${schemes.label}',
            warning: schemes.problem != null,
          ),
          const SizedBox(height: 14),
          ProblemText(problems),
          const SizedBox(height: 6),
          _SignActions(canSign: problems.isEmpty && !busy),
          const SizedBox(height: 14),
          const Divider(),
          const SizedBox(height: 10),
          const _ProfilesEntry(),
        ],
      ),
    );
  }
}

/// Signs the APK selected in Analyze APK, or picked files when none is.
class _SignActions extends ConsumerWidget {
  const _SignActions({required this.canSign});

  final bool canSign;

  static const _splitTooltip =
      'One signed APK per architecture in Defaults: '
      '<name>-<abi>-signed.apk. They keep the versionCode, which is fine to '
      'install or share; Google Play needs a different one per APK.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sign = ref.read(signActionProvider);
    final split = ref.read(splitAndSignActionProvider);
    final selected = ref.watch(apkListProvider.select((list) => list.selected));
    final availability = ref.watch(splitAvailabilityProvider);
    final cannotSplit = switch (availability) {
      CannotSplit(:final reason) => reason,
      CanSplit() => null,
    };
    final muted = TextStyle(fontSize: 12, color: context.status.muted);

    Future<void> pick(
      Future<void> Function(List<String>) action, {
      bool bundles = false,
    }) async {
      final files = await openFiles(
        acceptedTypeGroups: [apkTypes, if (bundles) appBundleTypes],
      );
      if (files.isNotEmpty) await action([for (final f in files) f.path]);
    }

    if (selected == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: canSign ? () => pick(sign.run, bundles: true) : null,
            icon: const Icon(Icons.draw_outlined),
            label: const Text('Sign APK or AAB files…'),
          ),
          const SizedBox(height: 8),
          Tooltip(
            message: cannotSplit ?? _splitTooltip,
            child: OutlinedButton.icon(
              onPressed: canSign && cannotSplit == null
                  ? () => pick(split.run)
                  : null,
              icon: const Icon(Icons.call_split),
              label: const Text('Split per ABI and sign…'),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Or open an APK in Analyze APK: Sign uses the one selected there.',
            style: muted,
          ),
        ],
      );
    }

    final name = ref.watch(hostProvider).path.basename(selected.path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FieldLabel('The APK selected in Analyze APK'),
        Tooltip(
          message: selected.path,
          child: FilledButton.icon(
            onPressed: canSign ? () => sign.run([selected.path]) : null,
            icon: const Icon(Icons.draw_outlined),
            label: Text('Sign $name', overflow: TextOverflow.ellipsis),
          ),
        ),
        const SizedBox(height: 8),
        Tooltip(
          message: cannotSplit ?? _splitTooltip,
          child: OutlinedButton.icon(
            onPressed: canSign && cannotSplit == null
                ? () => split.run([selected.path])
                : null,
            icon: const Icon(Icons.call_split),
            label: Text(
              cannotSplit == null
                  ? 'Split $name per ABI and sign'
                  : 'Split per ABI and sign',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(switch (availability) {
          CanSplit(:final summary) => summary,
          CannotSplit(:final reason) => reason,
        }, style: muted),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: canSign ? () => pick(sign.run, bundles: true) : null,
            icon: const Icon(Icons.folder_open_rounded, size: 18),
            label: const Text('Sign other APK or AAB files…'),
          ),
        ),
      ],
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
