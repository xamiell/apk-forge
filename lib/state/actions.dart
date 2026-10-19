import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/build/flutter_build.dart';
import '../domain/devices/devices.dart';
import '../domain/failure.dart';
import '../domain/profiles/profile.dart';
import '../domain/profiles/profile_run.dart';
import '../domain/signing/signing.dart';
import '../domain/tools/toolchain.dart';
import '../services/tool_executor.dart';
import 'apks.dart';
import 'devices.dart';
import 'forms.dart';
import 'profiles.dart';
import 'providers.dart';
import 'task_notifier.dart';
import 'toolchain_notifier.dart';

/// What the buttons do. Each action runs as the single current task, so
/// two signings never write the same file at once.
final actionsProvider = Provider<ForgeActions>(ForgeActions.new);

class ForgeActions {
  ForgeActions(this._ref);

  final Ref _ref;

  TaskNotifier get _task => _ref.read(taskProvider.notifier);

  /// Builds with the Build panel's options, then signs every APK with the
  /// Sign panel's key when "Sign after build" is on.
  Future<void> build() async {
    final options = _ref.read(buildOptionsProvider);
    final host = _ref.read(hostProvider);
    final signing = _ref.read(signingFormProvider);
    final signingProblem = _ref.read(signingProblemProvider);
    final schemes = _ref.read(defaultsProvider).schemes;

    await _task.run('Build', (executor) async {
      final toolchain = await _toolchain();
      final flutter = toolchain.flutter;
      if (flutter == null) {
        throw const ToolFailure(
          'flutter was not found',
          details: ['Set the Flutter SDK in Tools.'],
        );
      }
      final problems = buildProblems(
        options,
        host,
        _ref.read(fileProbeProvider),
      );
      if (problems.isNotEmpty) {
        throw ToolFailure('Cannot build yet', details: problems);
      }
      if (options.signAfterBuild && signingProblem != null) {
        throw ToolFailure(
          'Sign after build is on, but signing is not ready',
          details: [signingProblem],
        );
      }

      final apks = await _ref
          .read(flutterBuildServiceProvider)
          .build(executor, flutter: flutter, options: options);
      final list = _ref.read(apkListProvider.notifier);
      for (final apk in apks) {
        list.add(apk, ApkOrigin.built, select: false);
      }
      executor.log.success(
        'Built ${apks.length} APK${apks.length == 1 ? '' : 's'}.',
      );

      if (options.signAfterBuild) {
        await _signAll(
          executor,
          toolchain,
          apks,
          signing.toRequest(schemes: schemes),
          signing.selectedEntry?.sha256,
        );
      } else {
        list.select(apks.last);
      }
    });
  }

  /// Signs APKs that already exist (from CI, a store, another machine)
  /// with the schemes in Defaults.
  Future<void> signFiles(List<String> paths) async {
    if (paths.isEmpty) return;
    final signing = _ref.read(signingFormProvider);
    final problem = _ref.read(signingProblemProvider);
    final schemes = _ref.read(defaultsProvider).schemes;
    final label = paths.length == 1
        ? 'Sign ${_ref.read(hostProvider).path.basename(paths.single)}'
        : 'Sign ${paths.length} APKs';
    await _task.run(label, (executor) async {
      if (problem != null) {
        throw ToolFailure('Signing is not ready', details: [problem]);
      }
      final toolchain = await _toolchain();
      await _signAll(
        executor,
        toolchain,
        paths,
        signing.toRequest(schemes: schemes),
        signing.selectedEntry?.sha256,
      );
    });
  }

  /// Splits each APK (a universal one, from CI) into one APK per ABI in
  /// Defaults that it has, and signs each split with the schemes in
  /// Defaults, next to the original as `<name>-<abi>-signed.apk` unless the
  /// Sign panel has an output folder. An APK with nothing to split is
  /// signed as it is.
  Future<void> splitAndSignFiles(List<String> paths) async {
    if (paths.isEmpty) return;
    final signing = _ref.read(signingFormProvider);
    final problem = _ref.read(signingProblemProvider);
    final defaults = _ref.read(defaultsProvider);
    final host = _ref.read(hostProvider);
    final label = paths.length == 1
        ? 'Split and sign ${host.path.basename(paths.single)}'
        : 'Split and sign ${paths.length} APKs';
    await _task.run(label, (executor) async {
      if (problem != null) {
        throw ToolFailure('Signing is not ready', details: [problem]);
      }
      final toolchain = await _toolchain();
      final request = signing.toRequest(schemes: defaults.schemes);
      for (final path in paths) {
        if (executor.isCancelled) return;
        await _ref
            .read(apkSplitServiceProvider)
            .withSplits(
              executor,
              input: path,
              abis: defaults.abiNames,
              use: (splits) => _signAll(
                executor,
                toolchain,
                splits.isEmpty ? [path] : [for (final s in splits) s.path],
                request.withDefaultOutputDir(host.path.dirname(path)),
                signing.selectedEntry?.sha256,
              ),
            );
      }
    });
  }

  Future<void> _signAll(
    ToolExecutor executor,
    Toolchain toolchain,
    List<String> apks,
    SigningRequest request,
    String? expectedSha256,
  ) async {
    final list = _ref.read(apkListProvider.notifier);
    for (final apk in apks) {
      if (executor.isCancelled) return;
      final signed = await _ref
          .read(signingServiceProvider)
          .sign(
            executor,
            toolchain: toolchain,
            input: apk,
            request: request,
            expectedSha256: expectedSha256,
          );
      list.add(signed.path, ApkOrigin.signed);
    }
  }

  /// Runs [profile] as [check] planned it, with the keys it opened: the
  /// progress goes to [profileRunProvider], the record to the history, and
  /// each signed APK to the list.
  Future<ProfileRunRecord?> runProfile(
    SigningProfile profile,
    ProfileRunCheck check,
  ) async {
    if (!check.canRun || _ref.read(taskProvider).isRunning) return null;
    final host = _ref.read(hostProvider);
    final progress = _ref.read(profileRunProvider.notifier)
      ..start(profile.id, check.plan, host);
    final startedAt = _ref.read(clockProvider)();

    return _task.run('Run profile ${profile.name}', (executor) async {
      final results = await _ref
          .read(profileRunnerProvider)
          .run(
            executor,
            toolchain: await _toolchain(),
            plan: check.plan,
            keys: check.keys!,
            onProgress: progress.update,
          );
      final record = ProfileRunRecord(
        profileId: profile.id,
        profileName: profile.name,
        startedAt: startedAt,
        finishedAt: _ref.read(clockProvider)(),
        inputs: [
          for (final input in check.inputs)
            RunInput(
              name: host.path.basename(input.path),
              sha256: input.sha256,
              packageName: input.badging?.packageName,
              versionName: input.badging?.versionName,
              versionCode: input.badging?.versionCode,
            ),
        ],
        results: results,
        cancelled: executor.isCancelled,
      );
      _ref.read(profileHistoryProvider.notifier).add(record);
      progress.finish(record);

      final list = _ref.read(apkListProvider.notifier);
      final signed = [
        for (final result in results)
          if (result.status == TargetStatus.signed) result.outputPath!,
      ];
      for (final path in signed) {
        list.add(path, ApkOrigin.signed, select: false);
      }
      executor.log.success('${profile.name}: ${record.summary}.');
      if (profile.afterRun == AfterRun.openFolders) {
        // One window per folder, with its APK selected.
        final byFolder = {
          for (final path in signed) host.path.dirname(path): path,
        };
        for (final path in byFolder.values) {
          await _ref.read(fileRevealerProvider)(path, host);
        }
      }
      return record;
    });
  }

  /// Reads the keys of the Sign panel's keystore.
  Future<void> loadKeys() async {
    final form = _ref.read(signingFormProvider);
    await _task.run('Load keys', (executor) async {
      final keytool = (await _toolchain()).keytool;
      if (keytool == null) {
        throw const ToolFailure(
          'keytool was not found',
          details: ['Install a JDK, or set JAVA_HOME.'],
        );
      }
      final entries = await _ref
          .read(keystoreServiceProvider)
          .listEntries(
            executor,
            keytool: keytool,
            keystorePath: form.keystorePath.trim(),
            password: form.storePassword,
          );
      _ref.read(signingFormProvider.notifier).setEntries(entries);
      for (final entry in entries) {
        executor.log.info(
          '${entry.alias}: ${entry.owner ?? '?'}'
          '${entry.canSign ? '' : ' (certificate only)'}',
        );
      }
      executor.log.success(
        '${entries.length} key${entries.length == 1 ? '' : 's'} loaded.',
      );
    });
  }

  /// Installs the selected APK on the selected device.
  Future<void> install() async {
    final apk = _ref.read(apkListProvider).selectedPath;
    final options = _ref.read(installOptionsProvider);
    final device = _selectedDevice(options.selectedSerial);
    if (apk == null || device == null) return;

    await _task.run('Install on ${device.displayName}', (executor) async {
      final adb = (await _toolchain()).adb;
      if (adb == null) throw const ToolFailure('adb was not found');
      await _ref
          .read(adbServiceProvider)
          .install(
            executor,
            adb: adb,
            serial: device.serial,
            apk: apk,
            allowDowngrade: options.allowDowngrade,
          );
      executor.log.success(
        'Installed ${_ref.read(hostProvider).path.basename(apk)} on ${device.displayName}.',
      );
    });
  }

  AndroidDevice? _selectedDevice(String? serial) {
    for (final device in _ref.read(devicesProvider).devices) {
      if (device.serial == serial) return device;
    }
    return null;
  }

  Future<Toolchain> _toolchain() => _ref.read(toolchainProvider.future);
}
