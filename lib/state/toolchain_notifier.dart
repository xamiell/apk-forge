import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/tools/toolchain.dart';
import '../services/flutter_build_service.dart';
import '../services/tool_executor.dart';
import 'log_notifier.dart';
import 'providers.dart';

final toolOverridesProvider =
    NotifierProvider<ToolOverridesNotifier, ToolOverrides>(
      ToolOverridesNotifier.new,
    );

class ToolOverridesNotifier extends Notifier<ToolOverrides> {
  @override
  ToolOverrides build() {
    final saved = ref.read(settingsStoreProvider).read(SettingsKey.tools);
    return saved == null
        ? const ToolOverrides()
        : ToolOverrides.fromJson(saved);
  }

  void set({required String? flutterSdk, required String? androidSdk}) {
    String? clean(String? value) =>
        (value == null || value.trim().isEmpty) ? null : value.trim();
    state = ToolOverrides(
      flutterSdk: clean(flutterSdk),
      androidSdk: clean(androidSdk),
    );
    ref.read(settingsStoreProvider).write(SettingsKey.tools, state.toJson());
  }
}

final toolchainProvider = AsyncNotifierProvider<ToolchainNotifier, Toolchain>(
  ToolchainNotifier.new,
);

class ToolchainNotifier extends AsyncNotifier<Toolchain> {
  @override
  Future<Toolchain> build() async {
    final overrides = ref.watch(toolOverridesProvider);
    final host = ref.watch(hostProvider);
    final toolchain = ToolchainLocator(
      host: host,
      probe: ref.watch(fileProbeProvider),
    ).locate(overrides);

    // Riverpod forbids writing to another provider (the log) during the
    // synchronous part of a build; everything after an await is outside it.
    await Future<void>.value();
    final log = ref.read(logProvider.notifier);
    log.step('Tools');
    final executor = ToolExecutor(ref.read(processRunnerProvider), log);
    final version = toolchain.flutter == null
        ? null
        : await readFlutterVersion(executor, toolchain.flutter!);
    final found = toolchain.withFlutterVersion(version);

    void report(String name, String? path, {String? version}) {
      if (path == null) {
        log.warning('$name: not found');
      } else {
        log.info('$name${version == null ? '' : ' $version'}: $path');
      }
    }

    report('flutter', found.flutter, version: found.flutterVersion);
    report('apksigner', found.apksigner, version: found.buildToolsVersion);
    report('zipalign', found.zipalign);
    report('aapt2', found.aapt2);
    report('adb', found.adb);
    report('keytool', found.keytool);
    return found;
  }

  /// Looks for the tools again, after the user installs one.
  void refresh() => ref.invalidateSelf();
}
