import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/system/host.dart';
import '../../domain/failure.dart';
import '../../domain/signing/signing.dart';
import '../../domain/tools/toolchain.dart';
import '../../services/apk_split_service.dart';
import '../../services/signing_service.dart';
import '../../services/tool_executor.dart';
import '../apks.dart';
import '../forms.dart';
import '../providers.dart';
import '../task_notifier.dart';
import '../toolchain_notifier.dart';

/// Signs APKs one after another with one key, and lists each signed APK,
/// selected, as soon as it's written.
class ApkBatchSigner {
  const ApkBatchSigner({required this.signing, required this.list});

  final ApkSigningService signing;
  final ApkSink list;

  /// Stops before the next APK when the task is cancelled.
  Future<void> signAll(
    ToolExecutor executor, {
    required Toolchain toolchain,
    required List<String> paths,
    required SigningRequest request,
    String? expectedSha256,
  }) async {
    for (final path in paths) {
      if (executor.isCancelled) return;
      final signed = await signing.sign(
        executor,
        toolchain: toolchain,
        input: path,
        request: request,
        expectedSha256: expectedSha256,
      );
      list.add(signed.path, ApkOrigin.signed);
    }
  }
}

final apkBatchSignerProvider = Provider(
  (ref) => ApkBatchSigner(
    signing: ref.watch(signingServiceProvider),
    list: ref.watch(apkListProvider.notifier),
  ),
);

/// Signs APKs that already exist (from CI, a store, another machine) with
/// the key in Sign and the schemes in Defaults.
class SignAction {
  const SignAction({
    required this.task,
    required this.toolchain,
    required this.signing,
    required this.signer,
    required this.host,
  });

  final TaskRunner task;
  final ToolchainSource toolchain;
  final SigningSetup Function() signing;
  final ApkBatchSigner signer;
  final Host host;

  Future<void> run(List<String> paths) async {
    if (paths.isEmpty) return;
    final signing = this.signing();
    final label = paths.length == 1
        ? 'Sign ${host.path.basename(paths.single)}'
        : 'Sign ${paths.length} APKs';
    await task.run(label, (executor) async {
      final ready = _ready(signing);
      await signer.signAll(
        executor,
        toolchain: await toolchain(),
        paths: paths,
        request: ready.request,
        expectedSha256: ready.expectedSha256,
      );
    });
  }
}

final signActionProvider = Provider(
  (ref) => SignAction(
    task: ref.watch(taskProvider.notifier),
    toolchain: () => ref.read(toolchainProvider.future),
    signing: () => ref.read(signingSetupProvider),
    signer: ref.watch(apkBatchSignerProvider),
    host: ref.watch(hostProvider),
  ),
);

/// Splits each APK (a universal one, from CI) into one APK per ABI in
/// Defaults that it has, and signs each split with the key in Sign and the
/// schemes in Defaults, next to the original as `<name>-<abi>-signed.apk`
/// unless Sign has an output folder. An APK with nothing to split is signed
/// as it is.
class SplitAndSignAction {
  const SplitAndSignAction({
    required this.task,
    required this.toolchain,
    required this.signing,
    required this.abis,
    required this.splitter,
    required this.signer,
    required this.host,
  });

  final TaskRunner task;
  final ToolchainSource toolchain;
  final SigningSetup Function() signing;

  /// The ABIs in Defaults, as the folder names under `lib/`.
  final Set<String> Function() abis;
  final ApkSplitService splitter;
  final ApkBatchSigner signer;
  final Host host;

  Future<void> run(List<String> paths) async {
    if (paths.isEmpty) return;
    final signing = this.signing();
    final abis = this.abis();
    final label = paths.length == 1
        ? 'Split and sign ${host.path.basename(paths.single)}'
        : 'Split and sign ${paths.length} APKs';
    await task.run(label, (executor) async {
      final ready = _ready(signing);
      final toolchain = await this.toolchain();
      for (final path in paths) {
        if (executor.isCancelled) return;
        await splitter.withSplits(
          executor,
          input: path,
          abis: abis,
          use: (splits) => signer.signAll(
            executor,
            toolchain: toolchain,
            paths: splits.isEmpty ? [path] : [for (final s in splits) s.path],
            request: ready.request.withDefaultOutputDir(
              host.path.dirname(path),
            ),
            expectedSha256: ready.expectedSha256,
          ),
        );
      }
    });
  }
}

final splitAndSignActionProvider = Provider(
  (ref) => SplitAndSignAction(
    task: ref.watch(taskProvider.notifier),
    toolchain: () => ref.read(toolchainProvider.future),
    signing: () => ref.read(signingSetupProvider),
    abis: () => ref.read(defaultsProvider).abiNames,
    splitter: ref.watch(apkSplitServiceProvider),
    signer: ref.watch(apkBatchSignerProvider),
    host: ref.watch(hostProvider),
  ),
);

/// [signing], or the failure that says why Sign can't sign yet.
ReadyToSign _ready(SigningSetup signing) => switch (signing) {
  ReadyToSign() => signing,
  NotReadyToSign(:final problem) => throw ToolFailure(
    'Signing is not ready',
    details: [problem],
  ),
};
