import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/format.dart';
import '../../domain/signing/signing.dart';
import '../../state/actions.dart';
import '../../state/forms.dart';
import '../../state/task_notifier.dart';
import '../../state/toolchain_notifier.dart';
import '../common/file_types.dart';
import '../common/widgets.dart';
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
          _SchemesField(
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
            onPressed: problems.isEmpty && !busy
                ? () async {
                    final files = await openFiles(
                      acceptedTypeGroups: const [apkTypes],
                    );
                    if (files.isNotEmpty) {
                      await actions.signFiles([for (final f in files) f.path]);
                    }
                  }
                : null,
            icon: const Icon(Icons.draw_outlined),
            label: const Text('Sign APK files…'),
          ),
        ],
      ),
    );
  }
}

class _SchemesField extends StatelessWidget {
  const _SchemesField({required this.schemes, required this.onChanged});

  final SigningSchemes schemes;
  final ValueChanged<SigningSchemes> onChanged;

  @override
  Widget build(BuildContext context) {
    final custom = !schemes.isAutomatic;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Choose the signature schemes'),
          subtitle: Text(
            custom
                ? 'Only the ones marked are written.'
                : 'Off: apksigner picks them by the APK\'s minSdk.',
            style: const TextStyle(fontSize: 12),
          ),
          value: custom,
          onChanged: (on) => onChanged(
            on
                ? const SigningSchemes(v1: true, v2: true, v3: true, v4: false)
                : const SigningSchemes.automatic(),
          ),
        ),
        if (custom)
          Wrap(
            spacing: 8,
            children: [
              FilterChip(
                label: const Text('v1 (JAR)'),
                selected: schemes.v1 ?? false,
                onSelected: (v) => onChanged(schemes.copyWith(v1: v)),
              ),
              FilterChip(
                label: const Text('v2'),
                selected: schemes.v2 ?? false,
                onSelected: (v) => onChanged(schemes.copyWith(v2: v)),
              ),
              FilterChip(
                label: const Text('v3'),
                selected: schemes.v3 ?? false,
                onSelected: (v) => onChanged(schemes.copyWith(v3: v)),
              ),
              Tooltip(
                message: 'Also writes <apk>.idsig, for incremental installs (adb install --incremental).',
                child: FilterChip(
                  label: const Text('v4'),
                  selected: schemes.v4 ?? false,
                  onSelected: (v) => onChanged(schemes.copyWith(v4: v)),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
