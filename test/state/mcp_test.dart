import 'dart:convert';

import 'package:apk_forge/core/zip/zip_directory.dart';
import 'package:apk_forge/domain/analysis/apk_report.dart';
import 'package:apk_forge/domain/analysis/badging.dart';
import 'package:apk_forge/domain/analysis/signature.dart';
import 'package:apk_forge/domain/build/build_options.dart';
import 'package:apk_forge/domain/failure.dart';
import 'package:apk_forge/domain/mcp/mcp_protocol.dart';
import 'package:apk_forge/domain/profiles/key_properties.dart';
import 'package:apk_forge/domain/profiles/profile.dart';
import 'package:apk_forge/domain/profiles/profile_plan.dart';
import 'package:apk_forge/domain/profiles/profile_run.dart';
import 'package:apk_forge/domain/signing/signing.dart';
import 'package:apk_forge/services/profile_runner.dart';
import 'package:apk_forge/state/log_notifier.dart';
import 'package:apk_forge/state/mcp_notifier.dart';
import 'package:apk_forge/state/mcp_tools.dart';
import 'package:apk_forge/state/profiles.dart';
import 'package:apk_forge/state/providers.dart';
import 'package:apk_forge/state/task_notifier.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fakes.dart';

const _storePassword = 'st0re pass';
const _keyPassword = 'k3y pass';
const _key = '/keys/key.properties';
const _apk = '/ci/app-release.apk';

final _input = ApkReport(
  path: _apk,
  sizeBytes: 1,
  md5: 'm',
  sha256: 'ab12',
  contents: ApkContents.fromEntries([
    for (final abi in ['arm64-v8a', 'armeabi-v7a'])
      for (final name in ['lib/$abi/libapp.so', 'lib/$abi/libflutter.so'])
        ZipEntry(
          name: name,
          compressedSize: 1,
          uncompressedSize: 1,
          isCompressed: false,
        ),
  ]),
  badging: parseBadging(fixture('aapt2_badging_release.txt')),
  signature: parseApksignerVerify(fixture('apksigner_verify_unsigned.txt')),
);

final _universal = SigningProfile(
  id: 'u',
  name: 'Universal',
  targets: [
    for (final (name, abi) in [
      ('Phone', AndroidAbi.arm64V8a),
      ('Kiosk', AndroidAbi.armeabiV7a),
    ])
      ProfileTarget(
        id: name.toLowerCase(),
        name: name,
        abi: abi,
        keyProperties: _key,
        outputDir: '/out/${name.toLowerCase()}',
      ),
  ],
);

final _probe = FakeFileProbe(
  files: {_apk, _key},
  directories: {'/out/phone', '/out/kiosk'},
);

ProfileRunPlan _plan(SigningProfile profile) => planProfileRun(
  profile,
  [_input],
  defaultSchemes: const SigningSchemes(v2: true),
  host: macHost,
  probe: _probe,
  date: DateTime(2026, 10, 22),
);

const _opened = {
  _key: OpenedKey(
    keyProperties: _key,
    keystorePath: '/keys/release.jks',
    alias: 'upload',
    storePassword: _storePassword,
    keyPassword: _keyPassword,
    sha256: 'cd34',
  ),
};

ProfileRunRecord _record({bool cancelled = false, int minute = 5}) =>
    ProfileRunRecord(
      profileId: 'u',
      profileName: 'Universal',
      startedAt: DateTime(2026, 10, 22, 9, minute),
      finishedAt: DateTime(2026, 10, 22, 9, minute, 12),
      inputs: const [RunInput(name: 'app-release.apk', sha256: 'ab12')],
      results: const [
        TargetResult(
          target: 'Phone',
          input: 'app-release.apk',
          status: TargetStatus.signed,
          outputPath: '/out/phone/app-release-Phone.apk',
          sizeBytes: 2048,
          signerSha256: 'cd34',
        ),
      ],
      cancelled: cancelled,
    );

/// The tools over closures that record what they were asked to do.
class _Tools {
  _Tools({
    List<SigningProfile>? profiles,
    this.task = const TaskState(),
    this.runs = const [],
  }) : profiles = profiles ?? [_universal];

  final List<SigningProfile> profiles;
  final List<ProfileRunRecord> runs;

  /// What the check returns: the plan with the keys opened, unless set.
  ProfileRunCheck? checked;

  /// Whether a run asks first, and what the user answers.
  bool askToRun = false;
  RunApproval approval = RunApproval.allowed;

  /// What the run returns, and the task it leaves behind.
  ProfileRunRecord? ran;
  TaskState task;
  TaskState? taskAfterRun;
  ProfileRunState? lastRun;

  final asked = <String>[];
  final log = RecordingLog();

  late final tools = ProfileMcpTools(
    profiles: () => profiles,
    history: (profileId) => [
      for (final run in runs)
        if (run.profileId == profileId) run,
    ],
    keySummary: (path) async {
      asked.add('summary $path');
      return KeyFileSummary(path: path, alias: 'upload');
    },
    reread: (path) => asked.add('reread $path'),
    check: (profileId, apks) async {
      asked.add('check $profileId ${apks.join(',')}');
      return checked ??
          ProfileRunCheck(
            inputs: [_input],
            plan: _plan(profiles.firstWhere((p) => p.id == profileId)),
            keys: _opened,
          );
    },
    askToRun: () => askToRun,
    approve: (profile, check) async {
      asked.add('approve ${profile.id}');
      return approval;
    },
    run: (profile, check) async {
      asked.add('run ${profile.id}');
      task = taskAfterRun ?? task;
      return ran;
    },
    task: () => task,
    lastRun: () => lastRun,
    log: log,
    probe: _probe,
    host: macHost,
  );

  Future<McpToolResult> call(
    String name, [
    Map<String, Object?> arguments = const {},
  ]) => tools.call(name, arguments);
}

const _runArguments = {
  'profile': 'universal',
  'apks': [_apk],
};

void main() {
  group('the tools', () {
    test('list_profiles gives each profile with its key aliases, and '
        'changes nothing', () async {
      final tools = _Tools();

      final result = await tools.call('list_profiles');

      expect(result.isError, isFalse);
      final profile = (result.data['profiles'] as List).single as Map;
      expect(profile['name'], 'Universal');
      expect(
        [for (final t in profile['targets'] as List) t['keyAlias']],
        ['upload', 'upload'],
      );
      expect(profile['problems'], isEmpty);
      // One read of the shared key file; nothing checked, read or run.
      expect(tools.asked, ['summary $_key']);
    });

    test('list_profiles says what stops a target on this machine', () async {
      final tools = _Tools(
        profiles: [
          _universal.copyWith(
            targets: [
              _universal.targets.first.copyWith(
                keyProperties: '/elsewhere/key.properties',
              ),
            ],
          ),
        ],
      );

      final result = await tools.call('list_profiles');

      final profile = (result.data['profiles'] as List).single as Map;
      expect(profile['problems'], [
        'Phone: Its key.properties does not exist on this machine.',
      ]);
      expect(tools.asked, isEmpty);
    });

    test(
      'check_profile_run reads the APK again, checks, and signs nothing',
      () async {
        final tools = _Tools();

        final result = await tools.call('check_profile_run', _runArguments);

        expect(result.isError, isFalse);
        expect(result.data['profile'], 'Universal');
        expect(result.data['canRun'], isTrue);
        expect(
          [for (final s in result.data['signings'] as List) s['keyAlias']],
          ['upload', 'upload'],
        );
        expect(tools.asked, ['reread $_apk', 'check u $_apk']);
        expect(tools.log.lines, [
          'info: An agent checks "Universal" on app-release.apk.',
        ]);
      },
    );

    test('an unknown or shared profile name, or a missing APK, is a clear '
        'error and checks nothing', () async {
      final tools = _Tools(
        profiles: [
          _universal,
          _universal.copyWith(id: 'u2', name: 'UNIVERSAL'),
          _universal.copyWith(id: 'r', name: 'Release'),
        ],
      );

      for (final tool in ['check_profile_run', 'run_profile']) {
        final unknown = await tools.call(tool, {
          'profile': 'Phone',
          'apks': [_apk],
        });
        final shared = await tools.call(tool, _runArguments);
        final missing = await tools.call(tool, {
          'profile': 'Release',
          'apks': ['/ci/gone.apk'],
        });

        expect(unknown.isError, isTrue);
        expect(
          unknown.data['error'],
          'No profile named "Phone". The profiles: "Universal", '
          '"UNIVERSAL", "Release".',
        );
        expect(shared.data['error'], startsWith('2 profiles are named'));
        expect(missing.data['error'], 'There is no file at /ci/gone.apk.');
      }
      expect(tools.asked, isEmpty);
    });

    test('a check that fails to read an APK says why', () async {
      final tools = _Tools();
      final failing = ProfileMcpTools(
        profiles: () => [_universal],
        history: (_) => const [],
        keySummary: (path) async => KeyFileSummary(path: path),
        reread: (_) {},
        check: (_, _) async =>
            throw const ToolFailure('aapt2 failed', details: ['bad APK']),
        askToRun: () => true,
        approve: (_, _) async => fail('Nothing is asked.'),
        run: (_, _) async => fail('Nothing runs.'),
        task: () => const TaskState(),
        lastRun: () => null,
        log: tools.log,
        probe: _probe,
        host: macHost,
      );

      final result = await failing.call('check_profile_run', _runArguments);

      expect(result.isError, isTrue);
      expect(result.data, {
        'error': 'The check failed: aapt2 failed',
        'details': ['bad APK'],
      });
    });

    test('run_profile checks, runs and gives each target\'s result', () async {
      final tools = _Tools()..ran = _record();

      final result = await tools.call('run_profile', _runArguments);

      expect(result.isError, isFalse);
      expect(result.data['summary'], '1 signed');
      expect((result.data['results'] as List).single, {
        ..._record().results.single.toJson(),
      });
      expect(result.data['report'], contains('APK Forge run: '));
      expect(tools.asked, ['reread $_apk', 'check u $_apk', 'run u']);
      expect(tools.log.lines, [
        'info: An agent runs "Universal" on app-release.apk.',
      ]);
    });

    test('run_profile is refused while another task runs, before any '
        'check', () async {
      final tools = _Tools(task: const TaskState(running: 'Build'));

      final result = await tools.call('run_profile', _runArguments);

      expect(result.isError, isTrue);
      expect(
        result.data['error'],
        'APK Forge is busy: Build. Try again once it is done.',
      );
      expect(tools.asked, isEmpty);
    });

    test('run_profile does not start when the check finds a problem, and '
        'says it', () async {
      final tools = _Tools()
        ..checked = ProfileRunCheck(
          inputs: [_input],
          plan: _plan(_universal),
          keyFailure: const ToolFailure(
            '/keys/key.properties: the key does not open',
            details: ['The key password (keyPassword) is wrong.'],
          ),
        );

      final result = await tools.call('run_profile', _runArguments);

      expect(result.isError, isTrue);
      expect(
        result.data['error'],
        'The run didn\'t start: the check found a problem.',
      );
      expect(result.data['canRun'], isFalse);
      expect(result.data['problems'], [
        '/keys/key.properties: the key does not open',
        'The key password (keyPassword) is wrong.',
      ]);
      expect(tools.asked, ['reread $_apk', 'check u $_apk']);
    });

    test('a run that failed gives the failure; one cancelled gives what it '
        'did', () async {
      final failed = _Tools()
        ..taskAfterRun = const TaskState(
          failure: ToolFailure('Run profile Universal', details: ['disk full']),
        );
      final cancelled = _Tools()
        ..lastRun = ProfileRunState(
          profileId: 'u',
          progress: const [],
          record: _record(cancelled: true),
        );

      final failure = await failed.call('run_profile', _runArguments);
      final stopped = await cancelled.call('run_profile', _runArguments);

      expect(failure.data, {
        'error': 'The run failed: Run profile Universal',
        'details': ['disk full'],
      });
      expect(stopped.isError, isFalse);
      expect(stopped.data['outcome'], 'Cancelled');
    });

    test('asked first: the run waits for Allow, then runs', () async {
      final tools = _Tools()
        ..askToRun = true
        ..ran = _record();

      final result = await tools.call('run_profile', _runArguments);

      expect(result.isError, isFalse);
      expect(tools.asked, [
        'reread $_apk',
        'check u $_apk',
        'approve u',
        'run u',
      ]);
      expect(tools.log.lines, [
        'info: An agent runs "Universal" on app-release.apk.',
        'info: Waiting for Allow in APK Forge.',
        'info: The run was allowed.',
      ]);
    });

    test('declined: a clear error, and nothing runs', () async {
      final tools = _Tools()
        ..askToRun = true
        ..approval = RunApproval.declined;

      final result = await tools.call('run_profile', _runArguments);

      expect(result.isError, isTrue);
      expect(
        result.data['error'],
        'The run was declined in APK Forge: nothing was signed.',
      );
      expect(tools.asked, ['reread $_apk', 'check u $_apk', 'approve u']);
    });

    test(
      'another run already waiting for Allow: refused, nothing runs',
      () async {
        final tools = _Tools()
          ..askToRun = true
          ..approval = RunApproval.anotherWaiting;

        final result = await tools.call('run_profile', _runArguments);

        expect(
          result.data['error'],
          'APK Forge is already asking its user about another run. Try again '
          'once it is answered.',
        );
        expect(tools.asked, isNot(contains('run u')));
      },
    );

    test(
      'a task started in the app while it waited: busy, nothing runs',
      () async {
        late final _Tools tools;
        tools = _Tools()..askToRun = true;
        final approving = ProfileMcpTools(
          profiles: () => [_universal],
          history: (_) => const [],
          keySummary: (path) async => KeyFileSummary(path: path),
          reread: (_) {},
          check: tools.tools.check,
          askToRun: () => true,
          approve: (_, _) async {
            tools.task = const TaskState(running: 'Build');
            return RunApproval.allowed;
          },
          run: (_, _) async => fail('Nothing runs.'),
          task: () => tools.task,
          lastRun: () => null,
          log: tools.log,
          probe: _probe,
          host: macHost,
        );

        final result = await approving.call('run_profile', _runArguments);

        expect(
          result.data['error'],
          'APK Forge is busy: Build. Try again once it is done.',
        );
      },
    );

    test('not asked: the run starts once the check passes', () async {
      final tools = _Tools()..ran = _record();

      await tools.call('run_profile', _runArguments);

      expect(tools.asked, ['reread $_apk', 'check u $_apk', 'run u']);
    });

    test('a run refused because another task started meanwhile says it is '
        'busy', () async {
      final tools = _Tools()
        ..taskAfterRun = const TaskState(running: 'Install');

      final result = await tools.call('run_profile', _runArguments);

      expect(
        result.data['error'],
        'APK Forge is busy: Install. Try again once it is done.',
      );
    });

    test('list_runs gives the profile\'s runs newest first, up to the '
        'limit', () async {
      final tools = _Tools(
        runs: [_record(minute: 9), _record(minute: 7), _record(minute: 5)],
      );

      final result = await tools.call('list_runs', {
        'profile': 'Universal',
        'limit': 2,
      });

      expect(
        [for (final run in result.data['runs'] as List) run['startedAt']],
        ['2026-10-22T09:09:00.000', '2026-10-22T09:07:00.000'],
      );
      expect(tools.asked, isEmpty);
    });

    test('no password in any tool result, error or log line', () async {
      final results = <McpToolResult>[];
      final tools = _Tools()..ran = _record();
      results
        ..add(await tools.call('list_profiles'))
        ..add(await tools.call('check_profile_run', _runArguments))
        ..add(await tools.call('run_profile', _runArguments))
        ..add(await tools.call('list_runs', {'profile': 'Universal'}));
      final refused = _Tools()
        ..checked = ProfileRunCheck(
          inputs: [_input],
          plan: _plan(_universal),
          keyFailure: const ToolFailure('the key does not open'),
        );
      results.add(await refused.call('run_profile', _runArguments));

      final said = [
        for (final result in results) jsonEncode(result.toJson()),
        ...tools.log.lines,
        ...refused.log.lines,
      ].join('\n');
      for (final secret in [_storePassword, _keyPassword]) {
        expect(said, isNot(contains(secret)));
      }
    });
  });

  group('a run waiting for Allow', () {
    late ProviderContainer container;

    setUp(() => container = ProviderContainer.test());

    McpRunRequestNotifier requests() =>
        container.read(mcpRunRequestProvider.notifier);
    final check = ProfileRunCheck(
      inputs: [_input],
      plan: _plan(_universal),
      keys: _opened,
    );

    test('is shown until answered, and gets the answer', () async {
      final allowed = requests().ask(_universal, check);
      expect(container.read(mcpRunRequestProvider)!.profile.name, 'Universal');

      requests().answer(allow: true);

      expect(await allowed, RunApproval.allowed);
      expect(container.read(mcpRunRequestProvider), isNull);

      final declined = requests().ask(_universal, check);
      requests().answer(allow: false);
      expect(await declined, RunApproval.declined);
    });

    test('one at a time: another one is refused at once', () async {
      final first = requests().ask(_universal, check);

      expect(
        await requests().ask(_universal, check),
        RunApproval.anotherWaiting,
      );
      requests().answer(allow: true);
      expect(await first, RunApproval.allowed);
    });

    test('closing the app declines it', () async {
      final waiting = requests().ask(_universal, check);

      container.dispose();

      expect(await waiting, RunApproval.declined);
    });
  });

  group('the server', () {
    late MemorySettingsStore store;
    late List<String> events;
    late ProviderContainer container;
    late int tokens;
    ToolFailure? startFailure;

    setUp(() {
      store = MemorySettingsStore();
      events = [];
      tokens = 0;
      startFailure = null;
      container = ProviderContainer.test(
        overrides: [
          environmentProvider.overrideWithValue(const {}),
          settingsStoreProvider.overrideWithValue(store),
          mcpTokenMakerProvider.overrideWithValue(() => 'token-${++tokens}'),
          mcpServerStarterProvider.overrideWithValue(({
            required port,
            required token,
            required toolbox,
          }) async {
            if (startFailure case final failure?) throw failure;
            expect(toolbox, isA<ProfileMcpTools>());
            events.add('start $port $token');
            return () async => events.add('stop $port');
          }),
        ],
      );
    });

    McpServerNotifier server() => container.read(mcpServerProvider.notifier);
    McpServerState state() => container.read(mcpServerProvider);
    String log() =>
        container.read(logProvider).entries.map((e) => e.text).join('\n');

    test('off until turned on; then on, with a new token, and saved', () async {
      expect(state().status, McpServerStatus.off);
      expect(state().authorization, isNull);
      expect(state().settings.askToRun, isTrue);
      await server().resume();
      expect(events, isEmpty);

      await server().turnOn();

      expect(events, ['start 7740 token-1']);
      expect(state().status, McpServerStatus.on);
      expect(store.values[SettingsKey.mcp], {
        'enabled': true,
        'port': 7740,
        'token': 'token-1',
        'askToRun': true,
      });
      expect(state().authorization, 'Bearer token-1');
      expect(log(), 'MCP server on at http://127.0.0.1:7740/mcp.');
    });

    test('a launch turns it back on with the token it had', () async {
      store.values[SettingsKey.mcp] = {
        'enabled': true,
        'port': 7800,
        'token': 'kept',
      };

      await server().resume();

      expect(events, ['start 7800 kept']);
      expect(state().status, McpServerStatus.on);
    });

    test('off stops it and keeps the token for next time', () async {
      await server().turnOn();
      await server().turnOff();
      await server().turnOn();

      expect(events, ['start 7740 token-1', 'stop 7740', 'start 7740 token-1']);
      expect(tokens, 1);
    });

    test('another port moves it there; the same port leaves it', () async {
      await server().turnOn();
      await server().setPort(7740);
      await server().setPort(7801);

      expect(events, ['start 7740 token-1', 'stop 7740', 'start 7801 token-1']);
      expect(store.values[SettingsKey.mcp]!['port'], 7801);
    });

    test('New token starts it again with the new one only', () async {
      await server().turnOn();
      await server().newToken();

      expect(events, ['start 7740 token-1', 'stop 7740', 'start 7740 token-2']);
      expect(store.values[SettingsKey.mcp]!['token'], 'token-2');
      expect(log(), isNot(contains('token-')));
    });

    test('Ask before an agent runs is saved, and on by default', () async {
      server().setAskToRun(false);

      expect(state().settings.askToRun, isFalse);
      expect(store.values[SettingsKey.mcp]!['askToRun'], isFalse);
    });

    test('stopping the server declines the run waiting for Allow', () async {
      await server().turnOn();
      final waiting = container
          .read(mcpRunRequestProvider.notifier)
          .ask(
            _universal,
            ProfileRunCheck(
              inputs: [_input],
              plan: _plan(_universal),
              keys: _opened,
            ),
          );

      await server().turnOff();

      expect(await waiting, RunApproval.declined);
      expect(container.read(mcpRunRequestProvider), isNull);
    });

    test('a port in use leaves it failed, with the reason', () async {
      startFailure = const ToolFailure(
        'The MCP server can\'t listen on 127.0.0.1:7740',
        details: ['Another program may be using the port: choose another one.'],
      );

      await server().turnOn();

      expect(state().status, McpServerStatus.failed);
      expect(state().failure, startFailure);
      expect(log(), contains('The MCP server can\'t listen on 127.0.0.1:7740'));
    });

    test('closing the app stops it', () async {
      await server().turnOn();
      container.dispose();

      expect(events, ['start 7740 token-1', 'stop 7740']);
    });
  });
}
