import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/system/host.dart';

import '../domain/tools/toolchain.dart';
import '../services/bundletool_service.dart';
import '../services/flutter_build_service.dart';
import '../services/java_service.dart';
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

  void set(ToolOverrides overrides) {
    state = overrides.cleaned();
    ref.read(settingsStoreProvider).write(SettingsKey.tools, state.toJson());
  }
}

/// The tools, as [toolchainProvider] found them: what the actions read when
/// a task starts.
typedef ToolchainSource = Future<Toolchain> Function();

final toolchainProvider = AsyncNotifierProvider<ToolchainNotifier, Toolchain>(
  ToolchainNotifier.new,
);

class ToolchainNotifier extends AsyncNotifier<Toolchain> {
  @override
  Future<Toolchain> build() async {
    final overrides = ref.watch(toolOverridesProvider);
    final host = ref.watch(hostProvider);
    final probe = ref.watch(fileProbeProvider);

    // Riverpod forbids writing to another provider (the log) during the
    // synchronous part of a build; everything after an await is outside it.
    await Future<void>.value();
    final log = ref.read(logProvider.notifier);
    log.step('Tools');
    final found = await _findTools(
      overrides,
      host: host,
      probe: probe,
      executor: ToolExecutor(ref.read(processRunnerProvider), log),
    );

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
    report('jarsigner', found.jarsigner);
    report('java', found.java, version: found.javaVersion);
    report('bundletool', found.bundletool, version: found.bundletoolVersion);
    for (final problem in found.problems) {
      log.warning(problem);
    }
    return found;
  }

  /// Looks for the tools again, after the user installs one.
  void refresh() => ref.invalidateSelf();
}

/// The tools Tools' fields would give, before they're saved: what the Tools
/// dialog shows while you pick them. Nothing is saved, and the toolchain
/// the tasks use doesn't change until Save.
final toolchainPreviewProvider = FutureProvider.autoDispose
    .family<Toolchain, ToolOverrides>((ref, overrides) async {
      final host = ref.watch(hostProvider);
      final probe = ref.watch(fileProbeProvider);
      await Future<void>.value();
      final log = ref.read(logProvider.notifier);
      log.step('Check tools');
      return _findTools(
        overrides.cleaned(),
        host: host,
        probe: probe,
        executor: ToolExecutor(ref.read(processRunnerProvider), log),
      );
    });

/// The tools for [overrides]: found, then asked their versions, which tells
/// a bundletool from any other file.
Future<Toolchain> _findTools(
  ToolOverrides overrides, {
  required Host host,
  required FileProbe probe,
  required ToolExecutor executor,
}) async {
  final toolchain = ToolchainLocator(
    host: host,
    probe: probe,
  ).locate(overrides);
  return toolchain.withVersions(
    flutter: toolchain.flutter == null
        ? null
        : await readFlutterVersion(executor, toolchain.flutter!),
    java: toolchain.java == null
        ? null
        : await readJavaVersion(executor, toolchain.java!),
    bundletool: await readBundletoolVersion(executor, toolchain),
  );
}
