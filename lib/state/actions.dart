import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/build/flutter_build.dart';
import '../domain/devices/devices.dart';
import '../domain/failure.dart';
import '../domain/signing/signing.dart';
import '../domain/tools/toolchain.dart';
import '../services/tool_executor.dart';
import 'apks.dart';
import 'devices.dart';
import 'forms.dart';
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
      if (options.signAfterBuild && !signing.isReady) {
        throw ToolFailure(
          'Sign after build is on, but signing is not ready',
          details: [signing.problem!],
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
          signing.toRequest(),
          signing.selectedEntry?.sha256,
        );
      } else {
        list.select(apks.last);
      }
    });
  }

  /// Signs APKs that already exist (from CI, a store, another machine).
  Future<void> signFiles(List<String> paths) async {
    if (paths.isEmpty) return;
    final signing = _ref.read(signingFormProvider);
    final label = paths.length == 1
        ? 'Sign ${_ref.read(hostProvider).path.basename(paths.single)}'
        : 'Sign ${paths.length} APKs';
    await _task.run(label, (executor) async {
      if (!signing.isReady) {
        throw ToolFailure('Signing is not ready', details: [signing.problem!]);
      }
      final toolchain = await _toolchain();
      await _signAll(
        executor,
        toolchain,
        paths,
        signing.toRequest(),
        signing.selectedEntry?.sha256,
      );
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
