import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/system/host.dart';
import '../../domain/build/build_options.dart';
import '../../domain/build/flutter_build.dart';
import '../../domain/failure.dart';
import '../../domain/signing/signing.dart';
import '../../services/flutter_build_service.dart';
import '../apks.dart';
import '../forms.dart';
import '../providers.dart';
import '../task_notifier.dart';
import '../toolchain_notifier.dart';
import 'sign_actions.dart';

/// Builds with the Build panel's options, then signs every APK, or the App
/// Bundle, with the key in Sign when "Sign after build" is on. Only APKs go
/// to the APK list: Analyze APK reads APKs only.
class BuildAction {
  const BuildAction({
    required this.task,
    required this.toolchain,
    required this.options,
    required this.signing,
    required this.builder,
    required this.signer,
    required this.list,
    required this.host,
    required this.probe,
  });

  final TaskRunner task;
  final ToolchainSource toolchain;
  final BuildOptions Function() options;
  final SigningSetup Function() signing;
  final FlutterBuildService builder;
  final ApkBatchSigner signer;
  final ApkSink list;
  final Host host;
  final FileProbe probe;

  Future<void> run() async {
    final options = this.options();
    final signing = this.signing();

    await task.run('Build', (executor) async {
      final toolchain = await this.toolchain();
      final flutter = toolchain.flutter;
      if (flutter == null) {
        throw const ToolFailure(
          'flutter was not found',
          details: ['Set the Flutter SDK in Tools.'],
        );
      }
      final problems = buildProblems(options, host, probe);
      if (problems.isNotEmpty) {
        throw ToolFailure('Cannot build yet', details: problems);
      }
      final signWith = switch (signing) {
        _ when !options.signAfterBuild => null,
        ReadyToSign() => signing,
        NotReadyToSign(:final problem) => throw ToolFailure(
          'Sign after build is on, but signing is not ready',
          details: [problem],
        ),
      };

      final files = await builder.build(
        executor,
        flutter: flutter,
        options: options,
      );
      final apks = files.where((file) => !isAppBundle(file)).toList();
      for (final apk in apks) {
        list.add(apk, ApkOrigin.built, select: false);
      }
      executor.log.success(
        apks.length == files.length
            ? 'Built ${apks.length} APK${apks.length == 1 ? '' : 's'}.'
            : 'Built ${files.map(host.path.basename).join(', ')}.',
      );

      if (signWith == null) {
        if (apks.isNotEmpty) list.select(apks.last);
      } else {
        await signer.signAll(
          executor,
          toolchain: toolchain,
          paths: files,
          request: signWith.request,
          expectedSha256: signWith.expectedSha256,
        );
      }
    });
  }
}

final buildActionProvider = Provider(
  (ref) => BuildAction(
    task: ref.watch(taskProvider.notifier),
    toolchain: () => ref.read(toolchainProvider.future),
    options: () => ref.read(buildOptionsProvider),
    signing: () => ref.read(signingSetupProvider),
    builder: ref.watch(flutterBuildServiceProvider),
    signer: ref.watch(apkBatchSignerProvider),
    list: ref.watch(apkListProvider.notifier),
    host: ref.watch(hostProvider),
    probe: ref.watch(fileProbeProvider),
  ),
);
