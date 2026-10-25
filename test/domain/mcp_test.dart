import 'dart:convert';
import 'dart:math';

import 'package:apk_forge/core/zip/zip_directory.dart';
import 'package:apk_forge/domain/analysis/apk_report.dart';
import 'package:apk_forge/domain/analysis/badging.dart';
import 'package:apk_forge/domain/analysis/signature.dart';
import 'package:apk_forge/domain/build/build_options.dart';
import 'package:apk_forge/domain/failure.dart';
import 'package:apk_forge/domain/mcp/mcp_agents.dart';
import 'package:apk_forge/domain/mcp/mcp_protocol.dart';
import 'package:apk_forge/domain/mcp/profile_tools.dart';
import 'package:apk_forge/domain/profiles/key_properties.dart';
import 'package:apk_forge/domain/profiles/profile.dart';
import 'package:apk_forge/domain/profiles/profile_plan.dart';
import 'package:apk_forge/domain/profiles/profile_run.dart';
import 'package:apk_forge/domain/profiles/run_report.dart';
import 'package:apk_forge/domain/signing/signing.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fakes.dart';

/// Echoes what it's called with, and throws when asked to.
class _EchoToolbox implements McpToolbox {
  final calls = <(String, Map<String, Object?>)>[];

  /// The agent each call was for.
  final agents = <String>[];

  @override
  List<McpTool> get tools => const [
    McpTool(
      name: 'echo',
      title: 'Echo',
      description: 'Says it back.',
      inputSchema: {'type': 'object'},
      readOnly: true,
    ),
  ];

  @override
  Future<McpToolResult> call(
    String name,
    Map<String, Object?> arguments, {
    required String agent,
  }) async {
    calls.add((name, arguments));
    agents.add(agent);
    if (arguments['fail'] == true) throw StateError('it broke');
    return McpToolResult({'said': arguments['text']});
  }
}

/// Records what the protocol tells it, and opens `session-1`, `session-2`…
class _Sessions implements McpSessions {
  final events = <String>[];
  final clients = <String, McpClientInfo>{};
  var _opened = 0;

  @override
  String open(McpClientInfo client) {
    final id = 'session-${++_opened}';
    clients[id] = client;
    events.add('open ${client.label}');
    return id;
  }

  @override
  McpAgent? request(String sessionId, {String? tool}) {
    events.add('request $sessionId ${tool ?? '-'}');
    return switch (clients[sessionId]) {
      final client? => McpAgent(
        sessionId: sessionId,
        client: client,
        connectedAt: DateTime(2026, 10, 24),
        lastRequestAt: DateTime(2026, 10, 24),
      ),
      null => null,
    };
  }

  @override
  bool close(String sessionId) {
    events.add('close $sessionId');
    return clients.remove(sessionId) != null;
  }
}

Map<String, Object?> _request(
  String method, {
  Object id = 1,
  Map<String, Object?>? params,
}) => {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params};

/// The JSON a tool result carries as text.
Map<String, Object?> _toolData(Map<String, Object?>? answer) {
  final result = answer!['result'] as Map<String, Object?>;
  final content = (result['content'] as List).single as Map<String, Object?>;
  expect(content['type'], 'text');
  return jsonDecode(content['text'] as String) as Map<String, Object?>;
}

Object? _errorCode(Map<String, Object?>? answer) =>
    (answer!['error'] as Map<String, Object?>)['code'];

ApkReport _input(String path, {List<String> abis = const ['arm64-v8a']}) =>
    ApkReport(
      path: path,
      sizeBytes: 1,
      md5: 'm',
      sha256: 'ab12',
      contents: ApkContents.fromEntries([
        for (final abi in abis)
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

ProfileTarget _target(String name, {AndroidAbi? abi, String? key}) =>
    ProfileTarget(
      id: name.toLowerCase(),
      name: name,
      abi: abi,
      keyProperties: key ?? '/keys/key.properties',
      outputDir: '/out/${name.toLowerCase()}',
    );

SigningProfile _profile(
  String name, {
  String id = 'p1',
  List<ProfileTarget> targets = const [],
}) => SigningProfile(id: id, name: name, targets: targets);

void main() {
  group('the protocol', () {
    late _EchoToolbox toolbox;
    late _Sessions sessions;

    setUp(() {
      toolbox = _EchoToolbox();
      sessions = _Sessions();
    });

    Future<Map<String, Object?>?> answer(Object? message) =>
        answerMcpMessage(message, toolbox: toolbox);

    test('initialize answers in the version asked, if it speaks it', () async {
      final answered = await answer(
        _request('initialize', params: {'protocolVersion': '2025-06-18'}),
      );

      final result = answered!['result'] as Map<String, Object?>;
      expect(answered['id'], 1);
      expect(result['protocolVersion'], '2025-06-18');
      expect(result['capabilities'], {
        'tools': {'listChanged': false},
      });
      expect(result['serverInfo'], {
        'name': 'apk-forge',
        'title': 'APK Forge',
        'version': mcpToolsVersion,
      });
      expect(result['instructions'], mcpInstructions);
    });

    test('initialize answers in the newest version when asked for another '
        'one', () async {
      final answered = await answer(
        _request('initialize', params: {'protocolVersion': '2024-11-05'}),
      );

      expect(
        (answered!['result'] as Map)['protocolVersion'],
        mcpProtocolVersions.first,
      );
    });

    test('ping answers an empty result, with the same id', () async {
      expect(await answer(_request('ping', id: 'a7')), {
        'jsonrpc': '2.0',
        'id': 'a7',
        'result': <String, Object?>{},
      });
    });

    test('tools/list gives each tool with its schema and whether it changes '
        'anything', () async {
      final answered = await answer(_request('tools/list'));

      final tool =
          ((answered!['result'] as Map)['tools'] as List).single as Map;
      expect(tool['name'], 'echo');
      expect(tool['inputSchema'], {'type': 'object'});
      expect(tool['annotations'], {
        'title': 'Echo',
        'readOnlyHint': true,
        'destructiveHint': false,
        'openWorldHint': false,
      });
    });

    test('tools/call runs the tool with its arguments, and gives its result '
        'as JSON text', () async {
      final answered = await answer(
        _request(
          'tools/call',
          params: {
            'name': 'echo',
            'arguments': {'text': 'hi'},
          },
        ),
      );

      expect(toolbox.calls.single.$1, 'echo');
      expect(toolbox.calls.single.$2, {'text': 'hi'});
      expect(_toolData(answered), {'said': 'hi'});
      expect((answered!['result'] as Map)['isError'], isFalse);
    });

    test('tools/call without arguments calls the tool with none', () async {
      await answer(_request('tools/call', params: {'name': 'echo'}));

      expect(toolbox.calls.single.$1, 'echo');
      expect(toolbox.calls.single.$2, isEmpty);
    });

    test('a tool that throws is a tool error, not a protocol error', () async {
      final answered = await answer(
        _request(
          'tools/call',
          params: {
            'name': 'echo',
            'arguments': {'fail': true},
          },
        ),
      );

      expect((answered!['result'] as Map)['isError'], isTrue);
      expect(_toolData(answered), {
        'error': 'echo failed: Bad state: it broke',
      });
    });

    test('an unknown tool, or arguments that are not an object, are invalid '
        'params', () async {
      final unknown = await answer(
        _request('tools/call', params: {'name': 'sign_everything'}),
      );
      final badArguments = await answer(
        _request('tools/call', params: {'name': 'echo', 'arguments': 'hi'}),
      );

      expect(_errorCode(unknown), JsonRpcCode.invalidParams);
      expect(_errorCode(badArguments), JsonRpcCode.invalidParams);
      expect(toolbox.calls, isEmpty);
    });

    test('an unknown method is method not found', () async {
      expect(
        _errorCode(await answer(_request('resources/list'))),
        JsonRpcCode.methodNotFound,
      );
    });

    test(
      'a notification, or a response from the client, needs no answer',
      () async {
        expect(
          await answer({
            'jsonrpc': '2.0',
            'method': 'notifications/initialized',
          }),
          isNull,
        );
        expect(
          await answer({
            'jsonrpc': '2.0',
            'id': 3,
            'result': <String, Object?>{},
          }),
          isNull,
        );
      },
    );

    test('what is not a JSON-RPC 2.0 request is an invalid request', () async {
      for (final message in <Object?>[
        'ping',
        {'jsonrpc': '1.0', 'id': 1, 'method': 'ping'},
        {'jsonrpc': '2.0', 'id': null, 'method': 'ping'},
        {'jsonrpc': '2.0', 'id': 1},
      ]) {
        expect(
          _errorCode(await answer(message)),
          JsonRpcCode.invalidRequest,
          reason: '$message',
        );
      }
    });

    test('a body: not JSON is 400, a batch is 400, a notification is 202 '
        'and a request is 200', () async {
      Future<McpHttpAnswer> body(String text) =>
          answerMcpBody(text, toolbox: toolbox, sessions: sessions);

      final notJson = await body('{not json');
      final batch = await body(jsonEncode([_request('ping')]));
      final notification = await body(
        jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
      );
      final request = await body(jsonEncode(_request('ping')));

      expect(notJson.status, 400);
      expect(_errorCode(notJson.body), JsonRpcCode.parseError);
      expect(batch.status, 400);
      expect(_errorCode(batch.body), JsonRpcCode.invalidRequest);
      expect(notification.status, 202);
      expect(notification.body, isNull);
      expect(request.status, 200);
      expect(request.body!['result'], <String, Object?>{});
    });

    test('initialize opens a session for who the client says it is, and '
        'answers with its ID', () async {
      final answered = await answerMcpBody(
        jsonEncode(
          _request(
            'initialize',
            params: {
              'protocolVersion': '2025-11-25',
              'clientInfo': {
                'name': 'claude-code',
                'title': 'Claude Code',
                'version': '2.1.0',
              },
            },
          ),
        ),
        toolbox: toolbox,
        sessions: sessions,
      );
      final refused = await answerMcpBody(
        jsonEncode({'jsonrpc': '1.0', 'id': 2, 'method': 'initialize'}),
        toolbox: toolbox,
        sessions: sessions,
      );

      expect(answered.status, 200);
      expect(answered.headers, {mcpSessionHeader: 'session-1'});
      expect(refused.headers, isEmpty);
      expect(sessions.events, ['open Claude Code 2.1.0']);
    });

    test('a request in a session marks it, with the tool it calls; one in '
        'no session is answered the same', () async {
      Future<McpHttpAnswer> post(Object message, {String? sessionId}) =>
          answerMcpBody(
            jsonEncode(message),
            toolbox: toolbox,
            sessions: sessions,
            sessionId: sessionId,
          );

      final id = sessions.open(const McpClientInfo(name: 'claude-code'));

      final call = await post(
        _request(
          'tools/call',
          params: {
            'name': 'echo',
            'arguments': {'text': 'hi'},
          },
        ),
        sessionId: id,
      );
      await post({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }, sessionId: id);
      final ping = await post(_request('ping'));

      expect(_toolData(call.body), {'said': 'hi'});
      expect(ping.status, 200);
      expect(sessions.events, [
        'open claude-code',
        'request session-1 echo',
        'request session-1 -',
      ]);
    });

    test('a session it does not have is 404, so the client initializes '
        'again, and nothing is called', () async {
      final answered = await answerMcpBody(
        jsonEncode(
          _request('tools/call', params: {'name': 'echo', 'arguments': {}}),
        ),
        toolbox: toolbox,
        sessions: sessions,
        sessionId: 'from-before-a-restart',
      );

      expect(answered.status, 404);
      expect(toolbox.calls, isEmpty);
    });

    test('a tool call is told its session\'s agent, or "Agent" in no '
        'session', () async {
      final call = jsonEncode(
        _request('tools/call', params: {'name': 'echo', 'arguments': {}}),
      );

      final id = sessions.open(
        const McpClientInfo(name: 'claude-code', version: '2.1.0'),
      );

      await answerMcpBody(
        call,
        toolbox: toolbox,
        sessions: sessions,
        sessionId: id,
      );
      await answerMcpBody(call, toolbox: toolbox, sessions: sessions);

      expect(toolbox.agents, ['claude-code 2.1.0', 'Agent']);
    });

    test('DELETE ends a session: 204, or 404 for one it does not have, or '
        '400 without the header', () {
      final id = sessions.open(const McpClientInfo(name: 'agent'));

      expect(answerMcpDelete(id, sessions: sessions).status, 204);
      expect(answerMcpDelete(id, sessions: sessions).status, 404);
      expect(answerMcpDelete(null, sessions: sessions).status, 400);
      expect(sessions.events, [
        'open agent',
        'close session-1',
        'close session-1',
      ]);
    });
  });

  group('agents', () {
    test('a client is its title or name and its version, each one short '
        'line', () {
      expect(
        McpClientInfo.fromJson({'name': 'claude-code', 'version': '2.1.0'})
            .label,
        'claude-code 2.1.0',
      );
      expect(
        McpClientInfo.fromJson({'name': 'x', 'title': ' Claude\nCode\t'}).label,
        'Claude Code',
      );
      expect(McpClientInfo.fromJson(null).label, 'Agent');
      expect(
        McpClientInfo.fromJson({'name': 42, 'version': '  '}).label,
        'Agent',
      );
      final long = McpClientInfo.fromJson({'name': 'a' * 100}).name!;
      expect(long, hasLength(60));
      expect(long, endsWith('…'));
    });

    test('an agent says when it connected and what it last asked', () {
      final now = DateTime(2026, 10, 24, 14, 10);
      final agent = McpAgent(
        sessionId: 's',
        client: const McpClientInfo(name: 'claude-code'),
        connectedAt: DateTime(2026, 10, 24, 14, 5),
        lastRequestAt: DateTime(2026, 10, 24, 14, 9),
        lastTool: 'list_profiles',
      );

      expect(
        agent.activity(now),
        'Connected 14:05 · last request 14:09 · last tool list_profiles',
      );
      expect(
        agent.activity(DateTime(2026, 10, 25)),
        'Connected 2026-10-24 14:05 · last request 2026-10-24 14:09 · '
        'last tool list_profiles',
      );
      expect(
        agent.requested(DateTime(2026, 10, 24, 14, 12)).activity(now),
        'Connected 14:05 · last request 14:12 · last tool list_profiles',
      );
    });
  });

  group('what the server refuses', () {
    const token = 'tok3n';

    McpHttpAnswer? refuse({
      String method = 'POST',
      String path = '/mcp',
      String? origin,
      String? authorization = 'Bearer $token',
      String? protocolVersion,
    }) => refuseMcpRequest(
      method: method,
      path: path,
      origin: origin,
      authorization: authorization,
      protocolVersion: protocolVersion,
      port: 7740,
      token: token,
    );

    test('a POST to /mcp with the token, from no page or its own address, '
        'is answered', () {
      expect(refuse(), isNull);
      expect(refuse(origin: 'http://127.0.0.1:7740'), isNull);
      expect(refuse(origin: 'http://localhost:7740'), isNull);
      expect(refuse(protocolVersion: '2025-06-18'), isNull);
    });

    test('a web page is refused even with the token', () {
      final answer = refuse(origin: 'https://example.com');

      expect(answer!.status, 403);
      expect(refuse(origin: 'http://127.0.0.1:8080')!.status, 403);
    });

    test('no token, or another one, is 401 and asks for a bearer token', () {
      for (final authorization in [
        null,
        'Bearer other',
        'Basic $token',
        token,
      ]) {
        final answer = refuse(authorization: authorization);

        expect(answer!.status, 401, reason: authorization);
        expect(answer.headers, {'WWW-Authenticate': 'Bearer'});
        expect(jsonEncode(answer.body), isNot(contains(token)));
      }
    });

    test('another path is 404; a GET is 405: POST, and DELETE to end a '
        'session, only', () {
      expect(refuse(path: '/')!.status, 404);
      final get = refuse(method: 'GET');
      expect(get!.status, 405);
      expect(get.headers, {'Allow': 'POST, DELETE'});
      expect(refuse(method: 'DELETE'), isNull);
    });

    test('a protocol version it does not speak is 400', () {
      expect(refuse(protocolVersion: '2024-11-05')!.status, 400);
    });
  });

  group('connecting a client', () {
    test('the address, and the header with the token', () {
      expect(mcpUrl(7740), 'http://127.0.0.1:7740/mcp');
      expect(mcpAuthorization('abc_-1'), 'Bearer abc_-1');
    });

    test('a port is a number from 1024 to 65535', () {
      expect(mcpPortProblem(' 7740 '), isNull);
      expect(mcpPortProblem('65535'), isNull);
      expect(mcpPortProblem('seven'), 'A port is a number.');
      expect(mcpPortProblem('80'), 'Choose a port from 1024 to 65535.');
      expect(mcpPortProblem('70000'), 'Choose a port from 1024 to 65535.');
    });

    test('a token is 256 bits, URL-safe, and another one each time', () {
      final token = newMcpToken(Random(1));

      expect(token, hasLength(43));
      expect(token, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(newMcpToken(Random(1)), token);
      expect(newMcpToken(Random(2)), isNot(token));
    });
  });

  group('the profile tools', () {
    test('a profile is found by its name, ignoring case and spaces', () {
      final profiles = [
        _profile('Universal', id: 'u'),
        _profile('Release', id: 'r'),
      ];

      expect(findProfile(' universal ', profiles).profile!.id, 'u');
      expect(findProfile('RELEASE', profiles).profile!.id, 'r');
    });

    test('an unknown name lists the profiles; a shared one asks for a '
        'rename', () {
      final profiles = [
        _profile('Release', id: 'a'),
        _profile('release', id: 'b'),
        _profile('Kiosk', id: 'k'),
      ];

      final unknown = findProfile('Phone', profiles);
      final shared = findProfile('Release', profiles);

      expect(unknown.profile, isNull);
      expect(
        unknown.problem,
        'No profile named "Phone". The profiles: "Release", "release", '
        '"Kiosk".',
      );
      expect(shared.profile, isNull);
      expect(
        shared.problem,
        '2 profiles are named "Release": rename one in APK Forge, then ask '
        'again.',
      );
      expect(
        findProfile('Phone', const []).problem,
        'No profile named "Phone": APK Forge has no profiles yet.',
      );
    });

    group('a run\'s arguments', () {
      final probe = FakeFileProbe(files: {'/ci/app.apk', '/ci/other.apk'});

      ProfileRunArguments read(Map<String, Object?> arguments) =>
          ProfileRunArguments.read(arguments, host: macHost, probe: probe);

      test('a profile and APKs that exist, each once', () {
        final read_ = read({
          'profile': ' Universal ',
          'apks': ['/ci/app.apk', '/ci/other.apk', '/ci/app.apk'],
        });

        expect(read_.problem, isNull);
        expect(read_.profile, 'Universal');
        expect(read_.apks, ['/ci/app.apk', '/ci/other.apk']);
      });

      test('one path is a list of one', () {
        expect(read({'profile': 'U', 'apks': '/ci/app.apk'}).apks, [
          '/ci/app.apk',
        ]);
      });

      test('no profile, no APK, a relative path or a missing file are '
          'problems', () {
        expect(
          read({'apks': '/ci/app.apk'}).problem,
          'Name the profile (profile): list_profiles gives the names.',
        );
        expect(
          read({'profile': 'U'}).problem,
          'Give the APKs to run on (apks): their absolute paths.',
        );
        expect(
          read({'profile': 'U', 'apks': <Object?>[]}).problem,
          'Give the APKs to run on (apks): their absolute paths.',
        );
        expect(
          read({
            'profile': 'U',
            'apks': [3],
          }).problem,
          'Each APK is a path (a string).',
        );
        expect(
          read({'profile': 'U', 'apks': 'ci/app.apk'}).problem,
          'Give the APK\'s absolute path, not "ci/app.apk".',
        );
        expect(
          read({'profile': 'U', 'apks': '/ci/gone.apk'}).problem,
          'There is no file at /ci/gone.apk.',
        );
      });
    });

    test('list_runs takes 10 runs unless told, up to 50', () {
      expect(ProfileRunsArguments.read({'profile': 'U'}).limit, 10);
      expect(ProfileRunsArguments.read({'profile': 'U', 'limit': 3}).limit, 3);
      expect(
        ProfileRunsArguments.read({'profile': 'U', 'limit': 51}).problem,
        'limit is a number from 1 to 50.',
      );
      expect(
        ProfileRunsArguments.read({'limit': 3}).problem,
        'Name the profile (profile): list_profiles gives the names.',
      );
    });

    test('a profile lists its targets with their key alias, and its '
        'problems', () {
      final profile = SigningProfile(
        id: 'p1',
        name: 'Universal',
        input: const InputChecks(packageName: 'com.example.app'),
        targets: [
          _target('Phone', abi: AndroidAbi.arm64V8a),
          _target(
            'Kiosk',
            key: '/keys/kiosk/key.properties',
          ).copyWith(schemes: const SigningSchemes(v1: true, v2: true)),
        ],
        fileNamePattern: '{name}-{target}',
      );

      final json = profileJson(
        profile,
        keys: {
          '/keys/key.properties': const KeyFileSummary(
            path: '/keys/key.properties',
            alias: 'upload',
          ),
        },
        problems: const ['Kiosk: Its key.properties does not exist.'],
      );

      expect(json, {
        'name': 'Universal',
        'input': {'packageName': 'com.example.app', 'mustBeUnsigned': false},
        'targets': [
          {
            'name': 'Phone',
            'abi': 'arm64-v8a',
            'keyProperties': '/keys/key.properties',
            'keyAlias': 'upload',
            'schemes': 'Defaults',
            'outputDir': '/out/phone',
          },
          {
            'name': 'Kiosk',
            'abi': 'universal',
            'keyProperties': '/keys/kiosk/key.properties',
            'keyAlias': null,
            'schemes': 'v1, v2',
            'outputDir': '/out/kiosk',
          },
        ],
        'fileNamePattern': '{name}-{target}',
        'afterRun': 'openFolders',
        'problems': ['Kiosk: Its key.properties does not exist.'],
      });
    });

    group('a check', () {
      final input = _input(
        '/ci/app-release.apk',
        abis: ['arm64-v8a', 'armeabi-v7a'],
      );
      final profile = _profile(
        'Universal',
        targets: [
          _target('Phone', abi: AndroidAbi.arm64V8a),
          _target('Emulator', abi: AndroidAbi.x8664),
        ],
      );
      final plan = planProfileRun(
        profile,
        [input],
        defaultSchemes: const SigningSchemes(v2: true),
        host: macHost,
        probe: FakeFileProbe(
          files: {'/keys/key.properties'},
          directories: {'/out/phone', '/out/emulator'},
        ),
        date: DateTime(2026, 10, 22),
      );

      test('says what is signed, where, with which key, and what is '
          'skipped', () {
        final json = runCheckJson(
          profile,
          canRun: true,
          inputs: [input],
          plan: plan,
          keyAliases: const {'/keys/key.properties': 'upload'},
          keyFailure: null,
          host: macHost,
        );

        expect(json['canRun'], isTrue);
        expect(json['problems'], isEmpty);
        expect(json['inputs'], [
          {
            'path': '/ci/app-release.apk',
            'packageName': 'io.example.sample_app',
            'versionName': input.badging!.versionName,
            'versionCode': input.badging!.versionCode,
            'signed': false,
            'sha256': 'ab12',
          },
        ]);
        expect(json['signings'], [
          {
            'input': 'app-release.apk',
            'cutToAbi': 'arm64-v8a',
            'keyProperties': '/keys/key.properties',
            'keyAlias': 'upload',
            'schemes': 'v2',
            'outputs': [
              {'target': 'Phone', 'path': plan.jobs.single.outputs.single.path},
            ],
          },
        ]);
        expect(json['skipped'], [
          {
            'target': 'Emulator',
            'input': 'app-release.apk',
            'reason': 'No native code for x86_64',
          },
        ]);
      });

      test('a key that did not open is among the problems', () {
        final json = runCheckJson(
          profile,
          canRun: false,
          inputs: [input],
          plan: plan,
          keyAliases: null,
          keyFailure: const ToolFailure(
            '/keys/key.properties: the key does not open',
            details: ['The key password (keyPassword) is wrong.'],
          ),
          host: macHost,
        );

        expect(json['canRun'], isFalse);
        expect(json['problems'], [
          '/keys/key.properties: the key does not open',
          'The key password (keyPassword) is wrong.',
        ]);
        expect((json['signings'] as List).single['keyAlias'], isNull);
      });

      test('every target skipped is a problem: nothing to sign', () {
        final x86Only = planProfileRun(
          _profile(
            'Universal',
            targets: [_target('Emulator', abi: AndroidAbi.x8664)],
          ),
          [input],
          defaultSchemes: const SigningSchemes.automatic(),
          host: macHost,
          probe: FakeFileProbe(
            files: {'/keys/key.properties'},
            directories: {'/out/emulator'},
          ),
          date: DateTime(2026, 10, 22),
        );

        final json = runCheckJson(
          profile,
          canRun: false,
          inputs: [input],
          plan: x86Only,
          keyAliases: null,
          keyFailure: null,
          host: macHost,
        );

        expect(json['problems'], ['Every target is skipped: nothing to sign.']);
      });
    });

    test('a run gives each target\'s result, and the History\'s report', () {
      final record = ProfileRunRecord(
        profileId: 'p1',
        profileName: 'Universal',
        startedAt: DateTime(2026, 10, 22, 9, 5),
        finishedAt: DateTime(2026, 10, 22, 9, 5, 12),
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
          TargetResult(
            target: 'Emulator',
            input: 'app-release.apk',
            status: TargetStatus.skipped,
            reason: 'No native code for x86_64',
          ),
        ],
      );

      final json = runResultJson(record);

      expect(json['profile'], 'Universal');
      expect(json['startedAt'], '2026-10-22T09:05:00.000');
      expect(json['outcome'], 'Signed, some skipped');
      expect(json['summary'], '1 signed · 1 skipped');
      expect(json['results'], [
        for (final result in record.results) result.toJson(),
      ]);
      expect(json['report'], runReportText(runReport(record)));
      expect(runSummaryJson(record).containsKey('report'), isFalse);
    });
  });
}
