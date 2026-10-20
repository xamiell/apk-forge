import 'dart:io';

import 'package:apk_forge/core/system/host.dart';
import 'package:apk_forge/domain/analysis/apk_report.dart';
import 'package:apk_forge/domain/build/build_options.dart';
import 'package:apk_forge/domain/devices/devices.dart';
import 'package:apk_forge/domain/profiles/profile.dart';
import 'package:apk_forge/domain/profiles/profile_plan.dart';
import 'package:apk_forge/domain/profiles/profile_run.dart';
import 'package:apk_forge/domain/signing/keystore.dart';
import 'package:apk_forge/domain/signing/signing.dart';
import 'package:apk_forge/domain/tools/toolchain.dart';
import 'package:apk_forge/services/adb_service.dart';
import 'package:apk_forge/services/apk_split_service.dart';
import 'package:apk_forge/services/flutter_build_service.dart';
import 'package:apk_forge/services/profile_runner.dart';
import 'package:apk_forge/services/signing_service.dart';
import 'package:apk_forge/state/actions/build_action.dart';
import 'package:apk_forge/state/actions/create_folder_action.dart';
import 'package:apk_forge/state/actions/install_action.dart';
import 'package:apk_forge/state/actions/load_keys_action.dart';
import 'package:apk_forge/state/actions/profile_run_action.dart';
import 'package:apk_forge/state/actions/sign_actions.dart';
import 'package:apk_forge/state/apks.dart';
import 'package:apk_forge/state/forms.dart';
import 'package:apk_forge/state/profiles.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/fakes.dart';

const _toolchain = Toolchain(
  flutter: '/flutter',
  apksigner: '/bt/apksigner',
  zipalign: '/bt/zipalign',
  aapt2: '/bt/aapt2',
  buildToolsVersion: '36.0.0',
  adb: '/pt/adb',
  keytool: '/jdk/keytool',
);

/// The certificate in `apksigner_verify_test_key.txt`.
const _testKeySha =
    'b34c9445c5e411b045884f499034b5592ab109ec5cd1ca9cb584e54f582dcfa8';

ReadyToSign _ready({
  SigningSchemes schemes = const SigningSchemes.automatic(),
}) => ReadyToSign(
  SigningRequest(
    keystorePath: '/k.jks',
    storePassword: 'hunter2',
    alias: 'forge-test',
    schemes: schemes,
  ),
  expectedSha256: _testKeySha,
);

/// Records a run's progress, in order.
class _RecordingProgress implements ProfileRunProgress {
  final events = <String>[];

  @override
  void start(String profileId, ProfileRunPlan plan, Host host) =>
      events.add('start $profileId');

  @override
  void update(TargetProgress progress) =>
      events.add('${progress.target} ${progress.stage.name}');

  @override
  void finish(ProfileRunRecord record) => events.add('finish');
}

void main() {
  late FakeProcessRunner runner;
  late FakeTaskRunner task;
  late RecordingApkSink list;
  late Directory temp;

  setUp(() {
    runner = FakeProcessRunner();
    task = FakeTaskRunner(runner);
    list = RecordingApkSink();
    temp = Directory.systemTemp.createTempSync('apk_forge_actions_');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<Toolchain> toolchain() async => _toolchain;

  ApkBatchSigner signer() => ApkBatchSigner(
    signing: ApkSigningService(host: macHost, temporaryDirectory: () => temp),
    list: list,
  );

  Iterable<String> signedInputs() =>
      runner.callsWithFirstArg('sign').map((c) => p.basename(c.arguments.last));

  group('BuildAction', () {
    late String project;

    setUp(() {
      project = p.join(temp.path, 'app');
      Directory(p.join(project, 'android')).createSync(recursive: true);
      File(p.join(project, 'pubspec.yaml')).writeAsStringSync('name: app');
    });

    BuildAction action(BuildOptions options, {SigningSetup? signing}) =>
        BuildAction(
          task: task,
          toolchain: toolchain,
          options: () => options,
          signing: () => signing ?? _ready(),
          builder: const FlutterBuildService(host: macHost),
          signer: signer(),
          list: list,
          host: macHost,
          probe: const IoFileProbe(),
        );

    test('lists each APK built, then signs each one and lists it', () async {
      runner
        ..whenFirstArg('build', ok(fixture('flutter_build_split.txt')))
        ..whenFirstArg('verify', ok(fixture('apksigner_verify_test_key.txt')));

      await action(
        BuildOptions(projectDir: project, packaging: ApkPackaging.splitPerAbi),
      ).run();

      expect(task.failure, isNull);
      expect(signedInputs(), [
        'app-armeabi-v7a-release.apk',
        'app-arm64-v8a-release.apk',
        'app-x86_64-release.apk',
      ]);
      expect(
        list.added.map(
          (a) => '${a.origin.name} ${p.basename(a.path)} ${a.select}',
        ),
        [
          'built app-armeabi-v7a-release.apk false',
          'built app-arm64-v8a-release.apk false',
          'built app-x86_64-release.apk false',
          'signed app-armeabi-v7a-release-signed.apk true',
          'signed app-arm64-v8a-release-signed.apk true',
          'signed app-x86_64-release-signed.apk true',
        ],
      );
      expect(task.log.lines, contains('success: Built 3 APKs.'));
    });

    test('signing on but not ready: fails before flutter runs', () async {
      await action(
        BuildOptions(projectDir: project),
        signing: const NotReadyToSign('Choose a keystore.'),
      ).run();

      expect(runner.calls, isEmpty);
      expect(
        task.failure!.title,
        'Sign after build is on, but signing is not ready',
      );
      expect(task.failure!.details, ['Choose a keystore.']);
    });

    test('signing off: the APK built is selected and keeps Gradle\'s '
        'signature', () async {
      runner.whenFirstArg('build', ok(fixture('flutter_build_debug.txt')));

      await action(
        BuildOptions(
          projectDir: project,
          mode: BuildMode.debug,
          signAfterBuild: false,
        ),
        signing: const NotReadyToSign('Choose a keystore.'),
      ).run();

      expect(task.failure, isNull);
      expect(runner.callsWithFirstArg('sign'), isEmpty);
      expect(list.selected.map(p.basename), ['app-debug.apk']);
    });

    test(
      'a project that is not a Flutter project: flutter never runs',
      () async {
        await action(BuildOptions(projectDir: temp.path)).run();

        expect(runner.calls, isEmpty);
        expect(task.failure!.title, 'Cannot build yet');
        expect(task.failure!.details, [
          'The folder has no pubspec.yaml: it is not a Flutter project.',
        ]);
      },
    );

    test('a failed build fails the task with what went wrong', () async {
      runner.whenFirstArg(
        'build',
        failed(1, stdout: ['* What went wrong:', 'Gradle broke', '* Try:']),
      );

      await action(BuildOptions(projectDir: project, signAfterBuild: false))
          .run();

      expect(task.failure!.details, ['Gradle broke']);
      expect(list.added, isEmpty);
    });
  });

  group('SignAction', () {
    SignAction action(SigningSetup signing) => SignAction(
      task: task,
      toolchain: toolchain,
      signing: () => signing,
      signer: signer(),
      host: macHost,
    );

    test('signs each APK with the key and schemes it was given, and lists '
        'it', () async {
      runner.whenFirstArg(
        'verify',
        ok(fixture('apksigner_verify_test_key.txt')),
      );
      final a = writeApk(p.join(temp.path, 'a.apk'), ['arm64-v8a']);
      final b = writeApk(p.join(temp.path, 'b.apk'), ['arm64-v8a']);

      await action(
        _ready(
          schemes: const SigningSchemes(
            v1: false,
            v2: true,
            v3: true,
            v4: false,
          ),
        ),
      ).run([a, b]);

      expect(task.failure, isNull);
      expect(task.labels, ['Sign 2 APKs']);
      expect(signedInputs(), ['a.apk', 'b.apk']);
      expect(
        runner.callsWithFirstArg('sign').first.arguments,
        containsAllInOrder([
          '--v1-signing-enabled', 'false', //
          '--v2-signing-enabled', 'true',
          '--v3-signing-enabled', 'true',
          '--v4-signing-enabled', 'false',
        ]),
      );
      expect(list.added.map((a) => p.basename(a.path)), [
        'a-signed.apk',
        'b-signed.apk',
      ]);
      expect(list.added.every((a) => a.origin == ApkOrigin.signed), isTrue);
    });

    test('not ready: nothing runs, and the failure says why', () async {
      final apk = writeApk(p.join(temp.path, 'app.apk'), ['arm64-v8a']);

      await action(
        const NotReadyToSign(
          'Signature schemes in Defaults: Mark v1, v2 or v3.',
        ),
      ).run([apk]);

      expect(runner.calls, isEmpty);
      expect(task.failure!.title, 'Signing is not ready');
      expect(task.failure!.details, [
        'Signature schemes in Defaults: Mark v1, v2 or v3.',
      ]);
    });

    test('no files: no task', () async {
      await action(_ready()).run([]);

      expect(task.labels, isEmpty);
    });
  });

  group('SplitAndSignAction', () {
    SplitAndSignAction action(Set<String> abis) => SplitAndSignAction(
      task: task,
      toolchain: toolchain,
      signing: _ready,
      abis: () => abis,
      splitter: ApkSplitService(host: macHost, temporaryDirectory: () => temp),
      signer: signer(),
      host: macHost,
    );

    setUp(
      () => runner.whenFirstArg(
        'verify',
        ok(fixture('apksigner_verify_test_key.txt')),
      ),
    );

    test('one signed APK per ABI, next to the original', () async {
      final ci = p.join(temp.path, 'ci');
      final universal = writeApk(p.join(ci, 'app-release.apk'), [
        'arm64-v8a',
        'armeabi-v7a',
        'x86_64',
      ]);

      await action({'arm64-v8a', 'armeabi-v7a', 'x86_64'}).run([universal]);

      expect(task.failure, isNull);
      expect(signedInputs(), [
        'app-release-arm64-v8a.apk',
        'app-release-armeabi-v7a.apk',
        'app-release-x86_64.apk',
      ]);
      final sign = runner.callsWithFirstArg('sign').first.arguments;
      expect(p.dirname(sign[sign.indexOf('--out') + 1]), ci);
      expect(list.added.map((a) => p.basename(a.path)), [
        'app-release-arm64-v8a-signed.apk',
        'app-release-armeabi-v7a-signed.apk',
        'app-release-x86_64-signed.apk',
      ]);
      expect(File(universal).existsSync(), isTrue);
    });

    test('only the ABIs it is given', () async {
      final universal = writeApk(p.join(temp.path, 'ci', 'app-release.apk'), [
        'arm64-v8a',
        'armeabi-v7a',
        'x86_64',
      ]);

      await action({'arm64-v8a', 'armeabi-v7a'}).run([universal]);

      expect(signedInputs(), [
        'app-release-arm64-v8a.apk',
        'app-release-armeabi-v7a.apk',
      ]);
      expect(task.log.lines, contains('info: Left out x86_64: not chosen.'));
    });

    test('an APK with one ABI is signed as it is', () async {
      final apk = writeApk(p.join(temp.path, 'app-arm64-v8a-release.apk'), [
        'arm64-v8a',
      ]);

      await action({'arm64-v8a', 'x86_64'}).run([apk]);

      expect(runner.callsWithFirstArg('sign').single.arguments.last, apk);
      expect(
        p.basename(list.added.single.path),
        'app-arm64-v8a-release-signed.apk',
      );
    });
  });

  group('LoadKeysAction', () {
    late List<KeystoreEntry>? loaded;

    setUp(() => loaded = null);

    LoadKeysAction action({Toolchain tools = _toolchain}) => LoadKeysAction(
      task: task,
      toolchain: () async => tools,
      form: () =>
          const SigningForm(keystorePath: ' /k.jks ', storePassword: 'hunter2'),
      keystore: const KeystoreService(),
      onLoaded: (entries) => loaded = entries,
    );

    test('hands the keys read to Sign, and logs each one', () async {
      runner.when(
        (c) => c.executable == '/jdk/keytool',
        (_) => ok(fixture('keytool_list.txt')),
      );

      await action().run();

      expect(task.failure, isNull);
      expect(runner.calls.single.arguments, contains('/k.jks'));
      expect(loaded!.map((e) => e.alias), contains('forge-test'));
      expect(task.log.lines, contains('success: 2 keys loaded.'));
      expect(task.log.lines.join('\n'), isNot(contains('hunter2')));
    });

    test('without keytool, nothing runs and no key is handed over', () async {
      await action(tools: const Toolchain(apksigner: '/bt/apksigner')).run();

      expect(runner.calls, isEmpty);
      expect(task.failure!.title, 'keytool was not found');
      expect(loaded, isNull);
    });
  });

  group('InstallAction', () {
    late int installed;

    setUp(() => installed = 0);

    const pixel = AndroidDevice(
      serial: 'SER1',
      state: 'device',
      model: 'Pixel_8',
    );

    InstallAction action({
      String? apk = '/out/app.apk',
      AndroidDevice? device = pixel,
      bool allowDowngrade = false,
    }) => InstallAction(
      task: task,
      toolchain: toolchain,
      apk: () => apk,
      device: () => device,
      options: () => InstallOptions(allowDowngrade: allowDowngrade),
      adb: const AdbService(),
      host: macHost,
      onInstalled: () => installed++,
    );

    test('installs the APK on the device, downgrade if allowed', () async {
      runner.when(
        (c) => c.arguments.contains('install'),
        (_) => ok(['Success']),
      );

      await action(allowDowngrade: true).run();

      expect(task.failure, isNull);
      expect(runner.calls.single.arguments, [
        '-s',
        'SER1',
        'install',
        '-r',
        '-d',
        '/out/app.apk',
      ]);
      expect(task.log.lines.last, 'success: Installed app.apk on Pixel 8.');
      expect(installed, 1);
    });

    test('a failed install leaves what was read about the device', () async {
      runner.when((c) => c.arguments.contains('install'), (_) => failed(1));

      await action().run();

      expect(task.failure, isNotNull);
      expect(installed, 0);
    });

    test('without an APK or a device, nothing runs', () async {
      await action(apk: null).run();
      await action(device: null).run();

      expect(task.labels, isEmpty);
      expect(runner.calls, isEmpty);
      expect(installed, 0);
    });
  });

  group('CreateFolderAction', () {
    test('creates the folder, then the targets are checked again', () async {
      final created = <String>[];
      var checked = 0;

      final failure = await CreateFolderAction(
        create: (path) async => created.add(path),
        onCreated: () => checked++,
      ).run('/out/kiosk');

      expect(failure, isNull);
      expect(created, ['/out/kiosk']);
      expect(checked, 1);
    });

    test(
      'a folder that cannot be created says why, and nothing changes',
      () async {
        var checked = 0;

        final failure = await CreateFolderAction(
          create: (path) async => throw FileSystemException(
            'Creation failed',
            path,
            const OSError('Permission denied', 13),
          ),
          onCreated: () => checked++,
        ).run('/out/kiosk');

        expect(failure, 'Could not create /out/kiosk: Permission denied');
        expect(checked, 0);
      },
    );
  });

  group('ProfileRunAction', () {
    late _RecordingProgress progress;
    late List<ProfileRunRecord> history;
    late List<String> revealed;
    var now = DateTime(2026, 10, 19, 9);

    const key = OpenedKey(
      keyProperties: '/keys/key.properties',
      keystorePath: '/keys/release.jks',
      alias: 'forge-test',
      storePassword: 'hunter2',
      keyPassword: 'hunter3',
      sha256: _testKeySha,
    );

    setUp(() {
      progress = _RecordingProgress();
      history = [];
      revealed = [];
      now = DateTime(2026, 10, 19, 9);
      runner
        ..when((c) => c.arguments.first == 'sign', (c) {
          final out = c.arguments[c.arguments.indexOf('--out') + 1];
          File(out).writeAsStringSync('signed');
          return ok();
        })
        ..whenFirstArg('verify', ok(fixture('apksigner_verify_test_key.txt')));
    });

    ProfileRunAction action() => ProfileRunAction(
      task: task,
      toolchain: toolchain,
      runner: ProfileRunner(
        host: macHost,
        signing: ApkSigningService(
          host: macHost,
          temporaryDirectory: () => temp,
        ),
        temporaryDirectory: () => temp,
      ),
      progress: progress,
      addToHistory: history.add,
      list: list,
      reveal: (path, host) async => revealed.add(path),
      clock: () => now = now.add(const Duration(seconds: 30)),
      host: macHost,
    );

    /// Two targets in one folder and one in another, on an APK without
    /// native code: every target signs it whole.
    (SigningProfile, ProfileRunCheck) checked({
      AfterRun afterRun = AfterRun.openFolders,
      bool keysOpened = true,
    }) {
      ProfileTarget target(String name, String folder) => ProfileTarget(
        id: name,
        name: name,
        keyProperties: key.keyProperties,
        outputDir: p.join(temp.path, folder),
      );
      final profile = SigningProfile(
        id: 'p',
        name: 'Release',
        targets: [
          target('Phone', 'phones'),
          target('Tablet', 'phones'),
          target('Kiosk', 'kiosks'),
        ],
        afterRun: afterRun,
      );
      final input = ApkReport(
        path: p.join(temp.path, 'app-release.apk'),
        sizeBytes: 10,
        md5: 'm',
        sha256: 'ab12',
        contents: ApkContents.fromEntries(const []),
      );
      final plan = planProfileRun(
        profile,
        [input],
        defaultSchemes: const SigningSchemes.automatic(),
        host: macHost,
        probe: FakeFileProbe(
          files: {key.keyProperties},
          directories: {for (final t in profile.targets) t.outputDir},
        ),
        date: now,
      );
      return (
        profile,
        ProfileRunCheck(
          inputs: [input],
          plan: plan,
          keys: keysOpened ? {key.keyProperties: key} : null,
        ),
      );
    }

    test('records the run, lists each APK without selecting it, and opens '
        'each folder once', () async {
      final (profile, check) = checked();

      final record = await action().run(profile, check);

      expect(record!.summary, '3 signed');
      expect(record.finishedAt.difference(record.startedAt).inSeconds, 30);
      expect(record.inputs.single.sha256, 'ab12');
      expect(history, [record]);
      expect(progress.events.first, 'start p');
      expect(progress.events.last, 'finish');
      expect(list.added.map((a) => '${p.basename(a.path)} ${a.select}'), [
        'app-release-Phone.apk false',
        'app-release-Tablet.apk false',
        'app-release-Kiosk.apk false',
      ]);
      expect(revealed.map((path) => p.basename(p.dirname(path))), [
        'phones',
        'kiosks',
      ]);
      expect(task.log.lines, contains('success: Release: 3 signed.'));
    });

    test('a profile that does nothing after the run opens no folder', () async {
      final (profile, check) = checked(afterRun: AfterRun.nothing);

      await action().run(profile, check);

      expect(list.added, hasLength(3));
      expect(revealed, isEmpty);
    });

    test(
      'a check that cannot run, or another task running, runs nothing',
      () async {
        final (profile, notOpened) = checked(keysOpened: false);
        expect(await action().run(profile, notOpened), isNull);

        task.isRunning = true;
        final (_, check) = checked();
        expect(await action().run(profile, check), isNull);

        expect(runner.calls, isEmpty);
        expect(progress.events, isEmpty);
        expect(history, isEmpty);
      },
    );
  });
}
