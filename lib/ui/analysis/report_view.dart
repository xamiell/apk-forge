import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/format.dart';
import '../../domain/analysis/apk_report.dart';
import '../../domain/analysis/findings.dart';
import '../../domain/analysis/signature.dart';
import '../../domain/failure.dart';
import '../../services/desktop_shell.dart';
import '../../state/apks.dart';
import '../../state/forms.dart';
import '../../state/providers.dart';
import '../common/widgets.dart';
import '../theme.dart';

class ReportView extends ConsumerWidget {
  const ReportView({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(apkReportProvider(path));
    return switch (report) {
      AsyncData(:final value) => _Report(report: value),
      AsyncError(:final error) => _ReportError(path: path, error: error),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

class _ReportError extends ConsumerWidget {
  const _ReportError({required this.path, required this.error});

  final String path;
  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final failure = error is ToolFailure ? error as ToolFailure : null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              color: context.status.error,
              size: 36,
            ),
            const SizedBox(height: 8),
            Text(
              failure?.title ?? 'Could not read the APK',
              style: TextStyle(color: context.status.error),
            ),
            const SizedBox(height: 4),
            SelectableText(
              failure?.details.join('\n') ?? '$error',
              textAlign: TextAlign.center,
              style: monospace,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => ref.invalidate(apkReportProvider(path)),
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Report extends ConsumerWidget {
  const _Report({required this.report});

  final ApkReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(hostProvider);
    final keys = ref.watch(signingFormProvider.select((form) => form.entries));
    final findings = apkFindings(report, keystoreEntries: keys);
    final badging = report.badging;
    final signature = report.signature;
    final colors = context.status;
    final title = badging?.label ?? host.path.basename(report.path);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: the pills go under the title, so a narrow panel wraps
          // them instead of overflowing.
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 2),
          SelectableText(
            [
              badging?.packageName ?? 'Unknown package',
              if (badging?.versionName != null)
                '${badging!.versionName} (${badging.versionCode ?? '?'})',
            ].join('  ·  '),
            style: TextStyle(color: colors.muted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              switch (report.isDebuggable) {
                true => Pill(
                  'Debug',
                  color: colors.warning,
                  icon: Icons.bug_report_outlined,
                ),
                false => Pill(
                  'Release',
                  color: colors.ok,
                  icon: Icons.rocket_launch_outlined,
                ),
                null => Pill('Build type ?', color: colors.muted),
              },
              if (signature != null)
                signature.verifies
                    ? Pill(
                        'Signature OK',
                        color: colors.ok,
                        icon: Icons.verified_rounded,
                      )
                    : Pill(
                        'Not verified',
                        color: colors.error,
                        icon: Icons.gpp_bad_outlined,
                      ),
              if (report.isBundle)
                Pill(
                  'App Bundle',
                  color: colors.info,
                  icon: Icons.inventory_2_outlined,
                ),
              if (report.contents.flutter != null)
                Pill(
                  report.contents.flutter == FlutterCompilation.aot
                      ? 'Flutter AOT'
                      : 'Flutter JIT',
                  color: colors.info,
                ),
            ],
          ),
          const SizedBox(height: 14),
          FindingList(findings: findings),
          const SizedBox(height: 18),
          _Section(
            title: 'Signature',
            child: signature == null
                ? Text(
                    report.signatureError ?? 'Not checked.',
                    style: TextStyle(color: colors.warning),
                  )
                : _SignatureDetails(
                    signature: signature,
                    hasJarSignature: report.hasJarSignature,
                    bundle: report.isBundle,
                  ),
          ),
          _Section(
            title: 'Package',
            child: badging == null
                ? Text(
                    report.badgingError ?? 'Not read.',
                    style: TextStyle(color: colors.warning),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      InfoRow('Min SDK', _sdk(badging.minSdk)),
                      InfoRow('Target SDK', _sdk(badging.targetSdk)),
                      if (badging.compileSdk != null)
                        InfoRow('Compile SDK', _sdk(badging.compileSdk)),
                      if (badging.launchableActivity != null)
                        InfoRow(
                          'Launcher',
                          badging.launchableActivity!,
                          mono: true,
                        ),
                      _Permissions(permissions: badging.permissions),
                    ],
                  ),
          ),
          _Section(
            title: 'Architectures',
            child: _NativeCode(
              contents: report.contents,
              error: report.contentsError,
            ),
          ),
          _Section(
            title: 'File',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InfoRow(
                  'Path',
                  report.path,
                  trailing: IconButton(
                    tooltip: 'Show in the file manager',
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.folder_open_outlined),
                    onPressed: () => revealInFileManager(report.path, host),
                  ),
                ),
                InfoRow(
                  'Size',
                  '${formatBytes(report.sizeBytes)}  (${report.sizeBytes} bytes)',
                ),
                InfoRow(
                  'MD5',
                  report.md5,
                  mono: true,
                  trailing: CopyButton(report.md5),
                ),
                InfoRow(
                  'SHA-256',
                  report.sha256,
                  mono: true,
                  trailing: CopyButton(report.sha256),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _sdk(int? level) =>
      level == null ? '?' : 'API $level (${_androidVersion(level)})';

  static String _androidVersion(int level) => switch (level) {
    >= 36 => 'Android 16',
    35 => 'Android 15',
    34 => 'Android 14',
    33 => 'Android 13',
    32 => 'Android 12L',
    31 => 'Android 12',
    30 => 'Android 11',
    29 => 'Android 10',
    28 => 'Android 9',
    27 => 'Android 8.1',
    26 => 'Android 8.0',
    25 => 'Android 7.1',
    24 => 'Android 7.0',
    23 => 'Android 6.0',
    22 => 'Android 5.1',
    21 => 'Android 5.0',
    _ => 'older',
  };
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            letterSpacing: 0.8,
            fontWeight: FontWeight.w700,
            color: context.status.muted,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );
}

class _SignatureDetails extends StatelessWidget {
  const _SignatureDetails({
    required this.signature,
    required this.hasJarSignature,
    required this.bundle,
  });

  final SignatureReport signature;
  final bool hasJarSignature;

  /// A bundle has a JAR signature only: the v1 to v4 schemes are an APK's.
  final bool bundle;

  @override
  Widget build(BuildContext context) {
    final colors = context.status;
    Widget scheme(String name) {
      final status = schemeStatus(
        signature,
        name,
        hasJarSignature: hasJarSignature,
      );
      final (color, icon) = switch (status.state) {
        SchemeState.verified => (colors.ok, Icons.check_rounded),
        SchemeState.presentOnly => (colors.info, Icons.remove_rounded),
        SchemeState.absent => (colors.muted, Icons.close_rounded),
        SchemeState.unchecked => (colors.muted, Icons.question_mark_rounded),
        SchemeState.failed => (colors.warning, Icons.close_rounded),
      };
      return Tooltip(
        message: status.description,
        child: Pill(status.label, color: color, icon: icon),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (bundle)
              Tooltip(
                message:
                    'A bundle carries a JAR signature only: the store signs '
                    'the APKs it makes from it.',
                child: Pill(
                  'JAR signature',
                  color: signature.verifies ? colors.ok : colors.error,
                  icon: signature.verifies
                      ? Icons.check_rounded
                      : Icons.close_rounded,
                ),
              )
            else
              for (final name in const ['v1', 'v2', 'v3', 'v3.1', 'v4'])
                scheme(name),
          ],
        ),
        if (signature.v4Problem case final problem?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'v4: $problem',
              style: TextStyle(fontSize: 12.5, color: colors.warning),
            ),
          ),
        const SizedBox(height: 10),
        for (final signer in signature.signers) ...[
          InfoRow(
            signer.apiRange != null
                ? 'Signer, ${signer.apiRange}'
                : signature.signers.length > 1
                ? signer.label
                : 'Signer',
            signer.distinguishedName ?? '?',
          ),
          if (signer.sha256 != null)
            InfoRow(
              'SHA-256',
              colonDigest(signer.sha256!),
              mono: true,
              trailing: CopyButton(colonDigest(signer.sha256!)),
            ),
          if (signer.sha1 != null)
            InfoRow(
              'SHA-1',
              colonDigest(signer.sha1!),
              mono: true,
              trailing: CopyButton(colonDigest(signer.sha1!)),
            ),
          if (signer.keyAlgorithm != null)
            InfoRow(
              'Key',
              '${signer.keyAlgorithm}${signer.keySize == null ? '' : ' ${signer.keySize} bits'}',
            ),
          const SizedBox(height: 6),
        ],
        if (signature.lineage.isNotEmpty)
          InfoRow(
            'Key rotated',
            [
              for (final signer in signature.lineage)
                signer.distinguishedName ??
                    (signer.sha256 == null ? '?' : shortDigest(signer.sha256!)),
            ].join('  →  '),
          ),
        for (final error in signature.errors)
          Text('ERROR: $error', style: monospace.copyWith(color: colors.error)),
        if (signature.warnings.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              '${signature.warnings.length} apksigner warning${signature.warnings.length == 1 ? '' : 's'}',
              style: TextStyle(fontSize: 12.5, color: colors.warning),
            ),
            children: [
              for (final warning in signature.warnings)
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(warning, style: monospace),
                ),
            ],
          ),
      ],
    );
  }
}

class _Permissions extends StatelessWidget {
  const _Permissions({required this.permissions});

  final List<String> permissions;

  @override
  Widget build(BuildContext context) {
    if (permissions.isEmpty) return const InfoRow('Permissions', 'None');
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      dense: true,
      title: Text(
        '${permissions.length} permission${permissions.length == 1 ? '' : 's'}',
        style: const TextStyle(fontSize: 13),
      ),
      children: [
        for (final permission in permissions)
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              permission.replaceFirst('android.permission.', ''),
              style: monospace,
            ),
          ),
      ],
    );
  }
}

class _NativeCode extends StatelessWidget {
  const _NativeCode({required this.contents, this.error});

  final ApkContents contents;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colors = context.status;
    if (error != null) {
      return Text(error!, style: TextStyle(color: colors.warning));
    }
    if (contents.nativeLibraries.isEmpty) {
      return const Text(
        'No native code: it runs on any architecture.',
        style: TextStyle(fontSize: 13),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final MapEntry(key: abi, value: libraries)
            in contents.nativeLibraries.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 120,
                  child: Text(
                    abi,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final library in libraries)
                        Pill(
                          library,
                          color:
                              library == 'libflutter.so' ||
                                  library == 'libapp.so'
                              ? colors.info
                              : colors.muted,
                        ),
                      if (contents.isFlutterApp &&
                          !libraries.contains('libflutter.so'))
                        Pill(
                          'no libflutter.so',
                          color: colors.error,
                          icon: Icons.error_outline_rounded,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
