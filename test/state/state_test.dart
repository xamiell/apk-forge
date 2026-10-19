import 'dart:io';

import 'package:apk_forge/core/process/command.dart';
import 'package:apk_forge/core/process/process_runner.dart';
import 'package:apk_forge/core/system/host.dart';
import 'package:apk_forge/domain/analysis/comparison.dart';
import 'package:apk_forge/domain/build/build_options.dart';
import 'package:apk_forge/domain/failure.dart';
import 'package:apk_forge/domain/profiles/profile.dart';
import 'package:apk_forge/domain/profiles/profile_run.dart';
import 'package:apk_forge/domain/signing/keystore.dart';
import 'package:apk_forge/domain/signing/signing.dart';
import 'package:apk_forge/domain/tools/toolchain.dart';
import 'package:apk_forge/state/actions/build_action.dart';
import 'package:apk_forge/state/actions/install_action.dart';
import 'package:apk_forge/state/actions/load_keys_action.dart';
import 'package:apk_forge/state/actions/profile_run_action.dart';
import 'package:apk_forge/state/actions/sign_actions.dart';
import 'package:apk_forge/state/apks.dart';
import 'package:apk_forge/state/devices.dart';
import 'package:apk_forge/state/forms.dart';
import 'package:apk_forge/state/log_notifier.dart';
import 'package:apk_forge/state/profiles.dart';
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

/// No tool found.
class _NoTools extends ToolchainNotifier {
  @override
  Future<Toolchain> build() async => const Toolchain();
}

void main() {
  late FakeProcessRunner runner;
  late MemorySettingsStore store;
  late Directory temp;
  late ProviderContainer container;
  late List<String> revealed;

  setUp(() {
    runner = FakeProcessRunner();
    store = MemorySettingsStore();
    revealed = [];
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
        fileRevealerProvider.overrideWithValue(
          (path, host) async => revealed.add(path),
        ),
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

    await container.read(buildActionProvider).run();

    expect(container.read(taskProvider).failure, isNull);
    expect(runner.callsWithFirstArg('sign'), hasLength(3));
    final list = container.read(apkListProvider);
    expect(list.items.where((i) => i.origin == ApkOrigin.signed), hasLength(3));
    expect(list.items.where((i) => i.origin == ApkOrigin.built), hasLength(3));
    expect(p.basename(list.selectedPath!), 'app-x86_64-release-signed.apk');
  });

  test('a failure becomes the error panel and frees the task', () async {
    final notifier = container.read(taskProvider.notifier);

    final value = await notifier.run<String>(
      'Build',
      (_) => throw const ToolFailure(
        'Build failed (exit code 1)',
        details: ['Gradle broke'],
      ),
    );

    expect(value, isNull);
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

    notifier.dismissFailure();
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

    await container.read(loadKeysActionProvider).run();

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

    final saved = store.values[SettingsKey.signing]!;
    expect(saved['keystorePath'], '/k.jks');
    expect(saved['alias'], 'forge-test');
    expect(saved.toString(), isNot(contains('hunter2')));
    expect(saved.toString(), isNot(contains('k3y')));
  });

  group('what stops Build and Sign', () {
    test(
      'Build: the project, then the key while Sign after build is on',
      () async {
        await container.read(toolchainProvider.future);

        expect(container.read(buildProblemsProvider), [
          'Choose the Flutter project folder.',
          'Signing: Choose a keystore.',
        ]);

        container
            .read(buildOptionsProvider.notifier)
            .update(
              (o) => o.copyWith(projectDir: project(), signAfterBuild: false),
            );
        expect(container.read(buildProblemsProvider), isEmpty);
      },
    );

    test('without the tools: Build needs flutter and Sign apksigner', () async {
      final bare = ProviderContainer.test(
        overrides: [
          environmentProvider.overrideWithValue(const {}),
          settingsStoreProvider.overrideWithValue(MemorySettingsStore()),
          toolchainProvider.overrideWith(_NoTools.new),
        ],
      );
      await bare.read(toolchainProvider.future);

      expect(
        bare.read(buildProblemsProvider).first,
        'flutter was not found. Set it in Tools.',
      );
      expect(bare.read(signProblemsProvider), [
        'apksigner was not found (Android SDK build-tools).',
        'Choose a keystore.',
      ]);
    });
  });

  group('signingSetup', () {
    const entry = KeystoreEntry(
      alias: 'forge-test',
      entryType: 'PrivateKeyEntry',
      sha256: 'b34c',
    );
    const form = SigningForm(
      keystorePath: ' /k.jks ',
      storePassword: 'hunter2',
      entries: [entry],
      alias: 'forge-test',
    );
    const schemes = SigningSchemes(v1: false, v2: true, v3: true);

    test('the key in Sign with the schemes in Defaults', () {
      final setup = signingSetup(form, schemes) as ReadyToSign;

      expect(setup.request.keystorePath, '/k.jks');
      expect(setup.request.alias, 'forge-test');
      expect(setup.request.schemes.label, 'v2, v3');
      expect(setup.expectedSha256, 'b34c');
    });

    test('the key is missing first, then the schemes', () {
      const bad = SigningSchemes(v1: false, v2: false, v3: false);

      expect(
        signingSetup(form.copyWith(storePassword: ''), bad),
        isA<NotReadyToSign>().having(
          (s) => s.problem,
          'problem',
          'Enter the keystore password.',
        ),
      );
      expect(
        signingSetup(form, bad),
        isA<NotReadyToSign>().having(
          (s) => s.problem,
          'problem',
          'Signature schemes in Defaults: Mark v1, v2 or v3.',
        ),
      );
    });
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
    store.values[SettingsKey.build] = {
      'projectDir': '/w/app',
      'mode': 'debug',
      'packaging': 'splitPerAbi',
      'obfuscate': true,
      'symbolsDir': '/w/sym',
      'signAfterBuild': false,
    };

    final options = container.read(buildOptionsProvider);

    expect(options.projectDir, '/w/app');
    expect(options.mode, BuildMode.debug);
    expect(options.packaging, ApkPackaging.splitPerAbi);
    expect(options.signAfterBuild, isFalse);
  });

  group('Defaults', () {
    test('saved, back after a restart, and Build follows its ABIs', () {
      final defaults = container.read(defaultsProvider.notifier);
      expect(container.read(buildOptionsProvider).abis, hasLength(3));

      defaults
        ..toggleAbi(AndroidAbi.x8664)
        ..toggleAbi(AndroidAbi.armeabiV7a)
        ..update(
          (d) => d.copyWith(
            schemes: const SigningSchemes(v1: false, v2: true, v3: true),
            folded: true,
          ),
        );

      expect(container.read(buildOptionsProvider).abis, {AndroidAbi.arm64V8a});
      expect(store.values[SettingsKey.defaults], {
        'abis': ['arm64-v8a'],
        'schemes': {'v1': false, 'v2': true, 'v3': true, 'v4': null},
        'folded': true,
      });

      final restarted = ProviderContainer.test(
        overrides: [settingsStoreProvider.overrideWithValue(store)],
      );
      final back = restarted.read(defaultsProvider);
      expect(back.abis, {AndroidAbi.arm64V8a});
      expect(back.schemes.label, 'v2, v3');
      expect(back.folded, isTrue);
      expect(restarted.read(buildOptionsProvider).abis, {AndroidAbi.arm64V8a});
    });

    test('the ABIs and schemes saved in Build and Sign move here, once', () {
      store.values[SettingsKey.build] = {
        'projectDir': '/w/app',
        'abis': ['arm64-v8a', 'x86_64'],
      };
      store.values[SettingsKey.signing] = {
        'keystorePath': '/k.jks',
        'schemes': {'v1': true, 'v2': true, 'v3': false, 'v4': false},
      };

      migrateSettings(store);
      container.read(buildOptionsProvider.notifier).update((o) => o);
      container.read(signingFormProvider.notifier).update((f) => f);

      final defaults = container.read(defaultsProvider);
      expect(defaults.abis, {AndroidAbi.arm64V8a, AndroidAbi.x8664});
      expect(defaults.schemes.label, 'v1, v2');
      expect(container.read(buildOptionsProvider).abis, defaults.abis);
      // Build and Sign no longer save them.
      expect(store.values[SettingsKey.build]!.containsKey('abis'), isFalse);
      expect(
        store.values[SettingsKey.signing]!.containsKey('schemes'),
        isFalse,
      );

      // Once there, Defaults wins.
      container.read(defaultsProvider.notifier).toggleAbi(AndroidAbi.x8664);
      store.values[SettingsKey.build] = {
        'abis': ['armeabi-v7a'],
      };
      migrateSettings(store);
      expect(store.values[SettingsKey.defaults]!['abis'], ['arm64-v8a']);
    });

    test('nothing saved before: nothing to move', () {
      migrateSettings(store);

      expect(store.values, isEmpty);
      expect(container.read(defaultsProvider).abis, hasLength(3));
      expect(container.read(defaultsProvider).schemes.isAutomatic, isTrue);
    });

    test('Sign writes the schemes in Defaults', () async {
      runner.whenFirstArg(
        'verify',
        ok(fixture('apksigner_verify_test_key.txt')),
      );
      final apk = writeApk(p.join(temp.path, 'app.apk'), ['arm64-v8a']);
      loadTestKey();
      container
          .read(defaultsProvider.notifier)
          .update(
            (d) => d.copyWith(
              schemes: const SigningSchemes(
                v1: false,
                v2: true,
                v3: true,
                v4: false,
              ),
            ),
          );

      await container.read(signActionProvider).run([apk]);

      expect(container.read(taskProvider).failure, isNull);
      expect(
        runner.callsWithFirstArg('sign').single.arguments,
        containsAllInOrder([
          '--v1-signing-enabled', 'false', //
          '--v2-signing-enabled', 'true',
          '--v3-signing-enabled', 'true',
          '--v4-signing-enabled', 'false',
        ]),
      );
    });

    test('schemes apksigner cannot sign with stop Sign first', () async {
      final apk = writeApk(p.join(temp.path, 'app.apk'), ['arm64-v8a']);
      loadTestKey();
      container
          .read(defaultsProvider.notifier)
          .update(
            (d) => d.copyWith(
              schemes: const SigningSchemes(
                v1: false,
                v2: false,
                v3: false,
                v4: false,
              ),
            ),
          );

      await container.read(signActionProvider).run([apk]);

      expect(runner.calls, isEmpty);
      expect(container.read(taskProvider).failure!.details, [
        'Signature schemes in Defaults: Mark v1, v2 or v3.',
      ]);
    });

    test('split and sign writes only the ABIs in Defaults', () async {
      runner.whenFirstArg(
        'verify',
        ok(fixture('apksigner_verify_test_key.txt')),
      );
      final universal = writeApk(p.join(temp.path, 'ci', 'app-release.apk'), [
        'arm64-v8a',
        'armeabi-v7a',
        'x86_64',
      ]);
      loadTestKey();
      container.read(defaultsProvider.notifier).toggleAbi(AndroidAbi.x8664);

      await container.read(splitAndSignActionProvider).run([universal]);

      expect(container.read(taskProvider).failure, isNull);
      expect(
        runner
            .callsWithFirstArg('sign')
            .map((c) => p.basename(c.arguments.last)),
        ['app-release-arm64-v8a.apk', 'app-release-armeabi-v7a.apk'],
      );
      expect(
        container.read(logProvider).entries.map((e) => e.text),
        contains('Left out x86_64: not chosen.'),
      );
    });
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

      await container.read(installActionProvider).run();

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

  test('a list with APKs always has one selected', () {
    final list = container.read(apkListProvider.notifier)
      ..add('/out/a.apk', ApkOrigin.signed, select: false);
    expect(container.read(apkListProvider).selectedPath, '/out/a.apk');

    // Once something is selected, select: false keeps it.
    list.add('/out/b.apk', ApkOrigin.signed, select: false);
    expect(container.read(apkListProvider).selectedPath, '/out/a.apk');
  });

  test(
    'compare: two APKs of the list, from their reports, read once',
    () async {
      final release = writeApk(p.join(temp.path, 'app-release.apk'), [
        'arm64-v8a',
        'armeabi-v7a',
      ]);
      final debug = writeApk(p.join(temp.path, 'app-debug.apk'), ['arm64-v8a']);
      bool reads(Command c, String path) => c.arguments.last == path;
      runner
        ..when(
          (c) => c.arguments.first == 'dump' && reads(c, release),
          (_) => ok(fixture('aapt2_badging_release.txt')),
        )
        ..when(
          (c) => c.arguments.first == 'dump' && reads(c, debug),
          (_) => ok(fixture('aapt2_badging_debug.txt')),
        )
        ..when(
          (c) => c.arguments.first == 'verify' && reads(c, release),
          (_) => ok(fixture('apksigner_verify_test_key.txt')),
        )
        ..when(
          (c) => c.arguments.first == 'verify' && reads(c, debug),
          (_) => ok(fixture('apksigner_verify_debug_key.txt')),
        );
      container.read(apkListProvider.notifier)
        ..add(release, ApkOrigin.signed)
        ..add(debug, ApkOrigin.built);

      final comparison = await container.read(
        apkComparisonProvider((reference: release, candidate: debug)).future,
      );

      expect(comparison.signer, SignerVerdict.different);
      expect(comparison.updateBlockers.map((f) => f.label), [
        'Signer SHA-256',
        'Version code',
      ]);
      expect(comparison.differences.map((f) => f.label), contains('ABIs'));

      // Swapping the two reads nothing again.
      final calls = runner.calls.length;
      final swapped = await container.read(
        apkComparisonProvider((reference: debug, candidate: release)).future,
      );
      expect(runner.calls, hasLength(calls));
      expect(swapped.updateBlockers.map((f) => f.label), ['Signer SHA-256']);
    },
  );

  test(
    'compare with installed: the copy from the device against the APK',
    () async {
      final selected = writeApk(p.join(temp.path, 'app-release.apk'), [
        'arm64-v8a',
      ]);
      String? pulledBase;
      runner
        ..when(
          (c) => c.arguments.contains('pm') && c.arguments.contains('path'),
          (_) => ok(fixture('adb_pm_path_single.txt')),
        )
        ..when((c) => c.arguments.length > 2 && c.arguments[2] == 'pull', (c) {
          pulledBase = writeApk(c.arguments[4], ['arm64-v8a']);
          return ok();
        })
        ..when(
          (c) => c.arguments.first == 'dump',
          (c) => ok(
            fixture(
              c.arguments.last == selected
                  ? 'aapt2_badging_debug.txt'
                  : 'aapt2_badging_release.txt',
            ),
          ),
        )
        ..when(
          (c) => c.arguments.first == 'verify',
          (c) => ok(
            fixture(
              c.arguments.last == selected
                  ? 'apksigner_verify_debug_key.txt'
                  : 'apksigner_verify_test_key.txt',
            ),
          ),
        );
      container.read(apkListProvider.notifier).add(selected, ApkOrigin.built);

      final comparison = await container.read(
        installedComparisonProvider((
          serial: 'SER1',
          package: 'io.example.sample_app',
          candidate: selected,
        )).future,
      );

      // A debug build signed with the debug key, over the release install.
      expect(comparison!.signer, SignerVerdict.different);
      expect(comparison.updateBlockers.map((f) => f.label), [
        'Signer SHA-256',
        'Version code',
      ]);
      // The copy was deleted once read.
      expect(File(pulledBase!).existsSync(), isFalse);
    },
  );

  test('compare with installed: an app that is not installed', () async {
    final selected = writeApk(p.join(temp.path, 'app.apk'), ['arm64-v8a']);
    runner.when(
      (c) => c.arguments.contains('pm') && c.arguments.contains('path'),
      (_) => failed(1),
    );

    final comparison = await container.read(
      installedComparisonProvider((
        serial: 'SER1',
        package: 'com.example.app',
        candidate: selected,
      )).future,
    );

    expect(comparison, isNull);
  });

  group('the Install warning about the signer', () {
    bool isDumpsys(Command c) => c.arguments.last.startsWith('dumpsys package');
    bool isPmPath(Command c) =>
        c.arguments.contains('pm') && c.arguments.contains('path');

    test('another key than the installed app: warned', () async {
      final apk = writeApk(p.join(temp.path, 'app-debug.apk'), ['arm64-v8a']);
      runner
        ..when(
          isDumpsys,
          (_) => ok(fixture('adb_installed_package_settings.txt')),
        )
        ..when(isPmPath, (_) => ok(fixture('adb_pm_path_single.txt')))
        ..when((c) => c.arguments.length > 2 && c.arguments[2] == 'pull', (c) {
          writeApk(c.arguments[4], ['arm64-v8a']);
          return ok();
        })
        ..when(
          (c) => c.arguments.first == 'dump',
          (_) => ok(fixture('aapt2_badging_release.txt')),
        )
        ..when(
          (c) => c.arguments.first == 'verify',
          (c) => ok(
            fixture(
              c.arguments.last == apk
                  ? 'apksigner_verify_debug_key.txt'
                  : 'apksigner_verify_test_key.txt',
            ),
          ),
        );

      final warning = await container.read(
        installSignerWarningProvider((serial: 'SER1', apk: apk)).future,
      );

      expect(warning, contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE'));
    });

    test('not installed: no warning, and nothing copied', () async {
      final apk = writeApk(p.join(temp.path, 'app.apk'), ['arm64-v8a']);
      runner
        // grep finds nothing: the package isn't installed.
        ..when(isDumpsys, (_) => failed(1))
        ..when(
          (c) => c.arguments.first == 'dump',
          (_) => ok(fixture('aapt2_badging_release.txt')),
        );

      final warning = await container.read(
        installSignerWarningProvider((serial: 'SER1', apk: apk)).future,
      );

      expect(warning, isNull);
      expect(runner.calls.where(isPmPath), isEmpty);
    });
  });

  group('profiles', () {
    test(
      'created, edited, duplicated and deleted, and back after a restart',
      () {
        final profiles = container.read(profilesProvider.notifier);
        final id = profiles.create();
        profiles.update(
          container
              .read(profilesProvider)
              .byId(id)!
              .copyWith(
                name: 'Release',
                targets: const [
                  ProfileTarget(
                    id: 't1',
                    name: 'Phone',
                    abi: AndroidAbi.arm64V8a,
                    keyProperties: '/keys/key.properties',
                    outputDir: '/out/phone',
                  ),
                ],
              ),
        );
        final copy = profiles.duplicate(id);

        expect(container.read(profilesProvider).selectedId, copy);
        expect(container.read(profilesProvider).profiles.map((p) => p.name), [
          'Release',
          'Release copy',
        ]);

        // A restart reads them back from the settings.
        final restarted = ProviderContainer.test(
          overrides: [settingsStoreProvider.overrideWithValue(store)],
        );
        final back = restarted.read(profilesProvider);
        expect(back.profiles.map((p) => p.name), ['Release', 'Release copy']);
        expect(
          back.selected!.targets.single.keyProperties,
          '/keys/key.properties',
        );

        profiles.delete(copy);
        expect(container.read(profilesProvider).profiles.single.id, id);
        expect(container.read(profilesProvider).selectedId, id);
      },
    );

    test('an import, a copy or a new profile never repeats a name', () {
      final profiles = container.read(profilesProvider.notifier);
      String name(String id) => container.read(profilesProvider).byId(id)!.name;
      const imported = SigningProfile(id: 'from-file', name: 'Release');

      final first = profiles.add(imported);
      final again = profiles.add(imported);
      final copy = profiles.duplicate(first);
      final secondCopy = profiles.duplicate(first);
      final created = profiles.create();
      final createdAgain = profiles.create();

      expect(name(first), 'Release');
      expect(name(again), 'Release 2');
      expect(name(copy), 'Release copy');
      expect(name(secondCopy), 'Release copy 2');
      expect(name(created), 'New profile');
      expect(name(createdAgain), 'New profile 2');

      // A name freed by a delete is used again, never repeated.
      profiles.delete(created);
      expect(name(profiles.create()), 'New profile');
    });

    test('the history keeps each profile\'s runs, newest first', () {
      ProfileRunRecord run(String profile, int minute) => ProfileRunRecord(
        profileId: profile,
        profileName: profile,
        startedAt: DateTime(2026, 10, 18, 11, minute),
        finishedAt: DateTime(2026, 10, 18, 11, minute, 9),
        inputs: const [],
        results: const [],
      );
      final history = container.read(profileHistoryProvider.notifier)
        ..add(run('a', 1))
        ..add(run('b', 2))
        ..add(run('a', 3));

      expect(history.of('a').map((r) => r.startedAt.minute), [3, 1]);
      history.clear('a');
      expect(container.read(profileHistoryProvider).single.profileId, 'b');
      expect(
        ProviderContainer.test(
          overrides: [settingsStoreProvider.overrideWithValue(store)],
        ).read(profileHistoryProvider).single.profileId,
        'b',
      );
    });

    group('a run', () {
      const storePassword = 'st0re pass';
      const keyPassword = 'k3y pass';
      late String input;
      late String profileId;

      setUp(() {
        final keys = Directory(p.join(temp.path, 'keys'))..createSync();
        File(p.join(keys.path, 'release.jks')).writeAsStringSync('keystore');
        File(p.join(keys.path, 'key.properties')).writeAsStringSync(
          'storePassword=$storePassword\nkeyPassword=$keyPassword\n'
          'keyAlias=forge-test\nstoreFile=release.jks\n',
        );
        input = writeApk(p.join(temp.path, 'ci', 'app-release.apk'), [
          'arm64-v8a',
          'armeabi-v7a',
        ]);
        // Each folder exists, as when it's picked in the target editor.
        ProfileTarget target(String name, AndroidAbi abi) => ProfileTarget(
          id: name,
          name: name,
          abi: abi,
          keyProperties: p.join(keys.path, 'key.properties'),
          outputDir: (Directory(
            p.join(temp.path, 'out', name.toLowerCase()),
          )..createSync(recursive: true)).path,
        );
        final profiles = container.read(profilesProvider.notifier);
        profileId = profiles.create();
        profiles.update(
          container
              .read(profilesProvider)
              .byId(profileId)!
              .copyWith(
                name: 'Release',
                input: const InputChecks(
                  packageName: 'io.example.sample_app',
                  mustBeUnsigned: true,
                ),
                targets: [
                  target('Phone', AndroidAbi.arm64V8a),
                  target('Kiosk', AndroidAbi.armeabiV7a),
                  target('Emulator', AndroidAbi.x8664),
                ],
              ),
        );

        runner
          ..when(
            (c) => c.arguments.first == 'dump',
            (_) => ok(fixture('aapt2_badging_release.txt')),
          )
          ..when(
            (c) => c.arguments.first == 'verify',
            (c) => ok(
              fixture(
                c.arguments.last == input
                    ? 'apksigner_verify_unsigned.txt'
                    : 'apksigner_verify_test_key.txt',
              ),
            ),
          )
          ..when((c) => c.arguments.first == 'sign', (c) {
            final out = c.arguments[c.arguments.indexOf('--out') + 1];
            File(out).writeAsStringSync('signed');
            return ok();
          })
          ..when(
            (c) => c.arguments.contains('-list'),
            (_) => ok(fixture('keytool_list.txt')),
          );
      });

      Future<ProfileRunCheck> check() async {
        final provider = profileRunCheckProvider((
          profileId: profileId,
          inputs: input,
        ));
        container.listen(provider, (_, _) {});
        return container.read(provider.future);
      }

      test('checked, then run: one APK per target, recorded, and no password '
          'kept anywhere', () async {
        runner.when(
          (c) => c.arguments.contains('-certreq'),
          (_) => ok(fixture('keytool_certreq_ok.txt')),
        );

        final checked = await check();
        expect(checked.canRun, isTrue);
        expect(checked.plan.skipped.single.reason, 'No native code for x86_64');

        final profile = container.read(profilesProvider).byId(profileId)!;
        final record = await container
            .read(profileRunActionProvider)
            .run(profile, checked);

        expect(record!.summary, '2 signed · 1 skipped');
        expect(
          record.results
              .where((r) => r.status == TargetStatus.signed)
              .map((r) => p.relative(r.outputPath!, from: temp.path)),
          [
            'out/phone/app-release-Phone.apk',
            'out/kiosk/app-release-Kiosk.apk',
          ],
        );
        expect(
          container.read(profileHistoryProvider).single.profileId,
          profileId,
        );
        final run = container.read(profileRunProvider)!;
        expect(run.running, isFalse);
        expect(run.finished, 3);
        final list = container.read(apkListProvider);
        expect(
          list.items.map((i) => p.basename(i.path)),
          containsAll(['app-release-Phone.apk', 'app-release-Kiosk.apk']),
        );
        // The list had nothing selected: the panel needs one selected once
        // it has APKs.
        expect(list.selectedPath, isNotNull);
        // The profile opens its output folders.
        expect(revealed.map(p.basename), [
          'app-release-Phone.apk',
          'app-release-Kiosk.apk',
        ]);
        // The settings (profiles and history) and the log never saw a
        // password.
        final saved = store.values.toString();
        final log = container
            .read(logProvider)
            .entries
            .map((e) => e.text)
            .join('\n');
        for (final secret in [storePassword, keyPassword]) {
          expect(saved, isNot(contains(secret)));
          expect(log, isNot(contains(secret)));
        }
      });

      test('a key that does not open: nothing is signed', () async {
        runner.when(
          (c) => c.arguments.contains('-certreq'),
          (_) => failed(
            1,
            stdout: fixture('keytool_certreq_wrong_key_password.txt'),
          ),
        );

        final checked = await check();

        expect(checked.canRun, isFalse);
        expect(
          checked.keyFailure!.details.first,
          'The key password (keyPassword) is wrong.',
        );
        final profile = container.read(profilesProvider).byId(profileId)!;
        expect(
          await container.read(profileRunActionProvider).run(profile, checked),
          isNull,
        );
        expect(runner.callsWithFirstArg('sign'), isEmpty);
      });

      test('an input that fails the checks opens no key', () async {
        final profiles = container.read(profilesProvider.notifier);
        profiles.update(
          container
              .read(profilesProvider)
              .byId(profileId)!
              .copyWith(
                input: const InputChecks(packageName: 'com.example.other'),
              ),
        );

        final checked = await check();

        expect(checked.canRun, isFalse);
        expect(checked.plan.problems.single, contains('not com.example.other'));
        expect(
          runner.calls.where((c) => c.arguments.contains('-list')),
          isEmpty,
        );
      });

      test(
        'a folder that does not exist stops the check before the keys',
        () async {
          Directory(p.join(temp.path, 'out', 'kiosk')).deleteSync();

          final checked = await check();

          expect(checked.canRun, isFalse);
          expect(checked.plan.problems, [
            'Kiosk: its output folder does not exist: '
                '${p.join(temp.path, 'out', 'kiosk')}',
          ]);
          expect(
            runner.calls.where((c) => c.arguments.contains('-list')),
            isEmpty,
          );
        },
      );
    });
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
