import 'dart:io';

import 'package:apk_forge/core/process/process_runner.dart';
import 'package:apk_forge/core/system/host.dart';
import 'package:apk_forge/domain/build/build_options.dart';
import 'package:apk_forge/domain/signing/keystore.dart';
import 'package:apk_forge/domain/tools/toolchain.dart';
import 'package:apk_forge/state/actions.dart';
import 'package:apk_forge/state/apks.dart';
import 'package:apk_forge/state/devices.dart';
import 'package:apk_forge/state/forms.dart';
import 'package:apk_forge/state/log_notifier.dart';
import 'package:apk_forge/state/providers.dart';
import 'package:apk_forge/state/task_notifier.dart';
import 'package:apk_forge/state/toolchain_notifier.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/fakes.dart';

/// A toolchain without running the locator or `flutter --version`.
class _FixedToolchain extends ToolchainNotifier {
  @override
  Future<Toolchain> build() async => const Toolchain(
    flutter: '/flutter',
    apksigner: '/bt/apksigner',
    zipalign: '/bt/zipalign',
    aapt2: '/bt/aapt2',
    buildToolsVersion: '36.0.0',
    adb: '/pt/adb',
    keytool: '/jdk/keytool',
  );
}

void main() {
  late FakeProcessRunner runner;
  late MemorySettingsStore store;
  late Directory temp;
  late ProviderContainer container;

  setUp(() {
    runner = FakeProcessRunner();
    store = MemorySettingsStore();
    temp = Directory.systemTemp.createTempSync('apk_forge_state_');
    final project = p.join(temp.path, 'app');
    Directory(p.join(project, 'android')).createSync(recursive: true);
    File(p.join(project, 'pubspec.yaml')).writeAsStringSync('name: app');

    container = ProviderContainer.test(
      retry: (_, _) => null,
      overrides: [
        environmentProvider.overrideWithValue(const {}),
        hostProvider.overrideWithValue(
          const Host(os: HostOs.macos, environment: {}),
        ),
        processRunnerProvider.overrideWithValue(runner),
        settingsStoreProvider.overrideWithValue(store),
        toolchainProvider.overrideWith(_FixedToolchain.new),
      ],
    );
  });
  tearDown(() => temp.deleteSync(recursive: true));

  String project() => p.join(temp.path, 'app');

  void loadTestKey() {
    container.read(signingFormProvider.notifier)
      ..setKeystore('/k.jks')
      ..setStorePassword('hunter2')
      ..setEntries(const [
        KeystoreEntry(
          alias: 'forge-test',
          entryType: 'PrivateKeyEntry',
          sha256: 'b34c9445c5e411b045884f499034b5592ab109ec5cd1ca9cb584e54f582dcfa8',
        ),
      ]);
  }

  test('build and sign: every split is built, signed, listed and the last one selected', () async {
    runner
      ..whenFirstArg('build', ok(fixture('flutter_build_split.txt')))
      ..whenFirstArg('verify', ok(fixture('apksigner_verify_test_key.txt')));
    container
        .read(buildOptionsProvider.notifier)
        .update(
          (o) => o.copyWith(
            projectDir: project(),
            packaging: ApkPackaging.splitPerAbi,
          ),
        );
    loadTestKey();

    await container.read(actionsProvider).build();

    expect(container.read(taskProvider).failure, isNull);
    expect(runner.callsWithFirstArg('sign'), hasLength(3));
    final list = container.read(apkListProvider);
    expect(list.items.where((i) => i.origin == ApkOrigin.signed), hasLength(3));
    expect(list.items.where((i) => i.origin == ApkOrigin.built), hasLength(3));
    expect(p.basename(list.selectedPath!), 'app-x86_64-release-signed.apk');
  });

  test(
    'a build with signing on but no key fails before running flutter',
    () async {
      container
          .read(buildOptionsProvider.notifier)
          .update((o) => o.copyWith(projectDir: project()));

      await container.read(actionsProvider).build();

      expect(runner.calls, isEmpty);
      final failure = container.read(taskProvider).failure!;
      expect(failure.title, 'Sign after build is on, but signing is not ready');
      expect(failure.details, ['Choose a keystore.']);
    },
  );

  test(
    'without signing, the built APK keeps Gradle\'s signature and is selected',
    () async {
      runner.whenFirstArg('build', ok(fixture('flutter_build_debug.txt')));
      container
          .read(buildOptionsProvider.notifier)
          .update(
            (o) => o.copyWith(
              projectDir: project(),
              mode: BuildMode.debug,
              signAfterBuild: false,
            ),
          );

      await container.read(actionsProvider).build();

      expect(runner.callsWithFirstArg('sign'), isEmpty);
      expect(
        p.basename(container.read(apkListProvider).selectedPath!),
        'app-debug.apk',
      );
    },
  );

  test('a failure becomes the error panel and frees the task', () async {
    runner.whenFirstArg(
      'build',
      failed(1, stdout: ['* What went wrong:', 'Gradle broke', '* Try:']),
    );
    container
        .read(buildOptionsProvider.notifier)
        .update(
          (o) => o.copyWith(projectDir: project(), signAfterBuild: false),
        );

    await container.read(actionsProvider).build();

    final task = container.read(taskProvider);
    expect(task.isRunning, isFalse);
    expect(task.failure!.details, ['Gradle broke']);
    final log = container.read(logProvider).entries.map((e) => e.text);
    expect(
      log,
      containsAllInOrder([
        'Build',
        'Build failed (exit code 1)',
        '  Gradle broke',
      ]),
    );

    container.read(taskProvider.notifier).dismissFailure();
    expect(container.read(taskProvider).failure, isNull);
  });

  test('only one task runs at a time', () async {
    final notifier = container.read(taskProvider.notifier);
    var second = false;

    final first = notifier.run(
      'First',
      (_) => Future<void>.delayed(Duration.zero),
    );
    await notifier.run('Second', (_) async => second = true);
    await first;

    expect(second, isFalse);
  });

  test('cancel stops the task without an error panel', () async {
    final notifier = container.read(taskProvider.notifier);
    final running = notifier.run('Long', (executor) async {
      await Future<void>.delayed(Duration.zero);
      return 'done';
    });
    notifier.cancel();

    expect(await running, isNull);
    expect(container.read(taskProvider).failure, isNull);
    expect(container.read(logProvider).entries.last.text, 'Long: cancelled.');
  });

  test('load keys fills the form and selects the first signing key', () async {
    runner.when(
      (c) => c.executable == '/jdk/keytool',
      (_) => ok(fixture('keytool_list.txt')),
    );
    container.read(signingFormProvider.notifier)
      ..setKeystore('/k.jks')
      ..setStorePassword('hunter2');

    await container.read(actionsProvider).loadKeys();

    final form = container.read(signingFormProvider);
    expect(form.entries, hasLength(2));
    expect(form.alias, 'forge-test');
    expect(form.isReady, isTrue);
  });

  test('the saved settings never hold a password', () {
    loadTestKey();
    container
        .read(signingFormProvider.notifier)
        .update(
          (f) => f.copyWith(keyUsesStorePassword: false, keyPassword: 'k3y'),
        );

    final saved = store.values['signing']!;
    expect(saved['keystorePath'], '/k.jks');
    expect(saved['alias'], 'forge-test');
    expect(saved.toString(), isNot(contains('hunter2')));
    expect(saved.toString(), isNot(contains('k3y')));
  });

  test('another keystore forgets the password and the keys', () {
    loadTestKey();

    container.read(signingFormProvider.notifier).setKeystore('/other.jks');

    final form = container.read(signingFormProvider);
    expect(form.storePassword, isEmpty);
    expect(form.entries, isEmpty);
    expect(form.problem, 'Enter the keystore password.');
  });

  test('build options come back from the settings', () {
    store.values['build'] = {
      'projectDir': '/w/app',
      'mode': 'debug',
      'abis': ['arm64-v8a'],
      'packaging': 'splitPerAbi',
      'obfuscate': true,
      'symbolsDir': '/w/sym',
      'signAfterBuild': false,
    };

    final options = container.read(buildOptionsProvider);

    expect(options.projectDir, '/w/app');
    expect(options.mode, BuildMode.debug);
    expect(options.abis, {AndroidAbi.arm64V8a});
    expect(options.packaging, ApkPackaging.splitPerAbi);
    expect(options.signAfterBuild, isFalse);
  });

  test(
    'install runs adb on the selected device with the selected APK',
    () async {
      runner
        ..whenFirstArg(
          'devices',
          ok(['List of devices attached', 'SER1 device model:Pixel_8']),
        )
        ..when((c) => c.arguments.contains('install'), (_) => ok(['Success']));
      await container.read(devicesProvider.notifier).refresh();
      container.read(installOptionsProvider.notifier).select('SER1');
      container
          .read(apkListProvider.notifier)
          .add('/out/app.apk', ApkOrigin.opened);

      await container.read(actionsProvider).install();

      expect(container.read(taskProvider).failure, isNull);
      expect(runner.calls.last.arguments, [
        '-s',
        'SER1',
        'install',
        '-r',
        '/out/app.apk',
      ]);
      expect(
        container.read(logProvider).entries.last.text,
        'Installed app.apk on Pixel 8.',
      );
    },
  );

  test(
    'refresh selects the first ready device, and keeps a listed one',
    () async {
      runner.whenFirstArg(
        'devices',
        ok([
          'List of devices attached',
          'SER0 unauthorized',
          'SER1 device model:A',
          'SER2 device model:B',
        ]),
      );

      await container.read(devicesProvider.notifier).refresh();
      expect(container.read(installOptionsProvider).selectedSerial, 'SER1');
      expect(container.read(selectedDeviceProvider)!.model, 'A');

      container.read(installOptionsProvider.notifier).select('SER2');
      await container.read(devicesProvider.notifier).refresh();
      expect(container.read(installOptionsProvider).selectedSerial, 'SER2');
    },
  );

  test('refresh clears a selection whose device is gone', () async {
    container.read(installOptionsProvider.notifier).select('GONE');
    runner.whenFirstArg('devices', ok(['List of devices attached']));

    await container.read(devicesProvider.notifier).refresh();

    expect(container.read(installOptionsProvider).selectedSerial, isNull);
    expect(container.read(selectedDeviceProvider), isNull);
  });

  test('CommandResult from a start failure keeps the reason', () {
    const result = CommandResult(
      exitCode: startFailureExitCode,
      stderr: ['Could not start x'],
    );

    expect(result.succeeded, isFalse);
    expect(result.allLines, ['Could not start x']);
  });
}
