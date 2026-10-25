import 'dart:convert';
import 'dart:math';

import 'mcp_agents.dart';

/// The MCP versions the server speaks, newest first. A client that asks for
/// another one gets the newest, and decides whether to go on.
const mcpProtocolVersions = ['2025-11-25', '2025-06-18', '2025-03-26'];

/// The port the server listens on until another one is chosen.
const mcpDefaultPort = 7740;

/// The name the server is registered under in an MCP client.
const mcpServerName = 'apk-forge';

/// The version of the tools' contract: it goes up when a tool's arguments
/// or results change.
const mcpToolsVersion = '1';

/// Where an MCP client reaches the server: the loopback address only.
String mcpUrl(int port) => 'http://127.0.0.1:$port/mcp';

/// The `Authorization` header's value an agent sends with every request.
/// It holds [token]: it's copied, never shown or logged.
String mcpAuthorization(String token) => 'Bearer $token';

/// Why [text] can't be the server's port, or `null` when it can.
String? mcpPortProblem(String text) {
  final port = int.tryParse(text.trim());
  if (port == null) return 'A port is a number.';
  if (port < 1024 || port > 65535) return 'Choose a port from 1024 to 65535.';
  return null;
}

/// A new token for the server: 256 bits from [random], URL-safe, so it fits
/// in a header and a shell argument as it is.
String newMcpToken(Random random) => base64Url
    .encode([for (var i = 0; i < 32; i++) random.nextInt(256)])
    .replaceAll('=', '');

/// A tool an agent can call: its name, what it does, and its arguments as
/// a JSON Schema.
class McpTool {
  const McpTool({
    required this.name,
    required this.title,
    required this.description,
    required this.inputSchema,
    required this.readOnly,
  });

  final String name;
  final String title;
  final String description;
  final Map<String, Object?> inputSchema;

  /// Whether it changes nothing. One that does may also replace a file it
  /// wrote before.
  final bool readOnly;

  Map<String, Object?> toJson() => {
    'name': name,
    'title': title,
    'description': description,
    'inputSchema': inputSchema,
    'annotations': {
      'title': title,
      'readOnlyHint': readOnly,
      'destructiveHint': !readOnly,
      'openWorldHint': false,
    },
  };
}

/// What a tool call returns to the agent, as JSON text. An error is a
/// refusal or a failure the agent can act on, not a protocol error.
class McpToolResult {
  const McpToolResult(this.data) : isError = false;

  McpToolResult.error(String message, {Map<String, Object?> data = const {}})
    : data = {'error': message, ...data},
      isError = true;

  final Map<String, Object?> data;
  final bool isError;

  Map<String, Object?> toJson() => {
    'content': [
      {'type': 'text', 'text': _pretty.convert(data)},
    ],
    'isError': isError,
  };
}

const _pretty = JsonEncoder.withIndent('  ');

/// The tools, and what calling one does. The app's is `ProfileMcpTools`.
abstract interface class McpToolbox {
  List<McpTool> get tools;

  /// Runs the tool [name], one of [tools], with [arguments], for [agent]:
  /// the calling session's agent as Agent access names it.
  Future<McpToolResult> call(
    String name,
    Map<String, Object?> arguments, {
    required String agent,
  });
}

/// JSON-RPC's error codes.
abstract final class JsonRpcCode {
  static const parseError = -32700;
  static const invalidRequest = -32600;
  static const methodNotFound = -32601;
  static const invalidParams = -32602;
}

/// What the server says in `initialize`.
const mcpInstructions =
    'APK Forge signs Android APKs with saved signing profiles. '
    'list_profiles shows them. check_profile_run says what a run would do '
    'and opens the keys without signing anything. run_profile checks again, '
    'then signs one APK per target into its folder; the run shows in the '
    'app and in its History. When APK Forge asks before an agent runs a '
    'profile, run_profile waits until its user allows or declines the run '
    'in the app: tell the user to answer there. list_runs reads the History. '
    'Give APKs as absolute paths. Passwords never leave the app.';

/// The HTTP answer to a request: its status, the headers it needs, and the
/// JSON body, if any.
class McpHttpAnswer {
  const McpHttpAnswer(this.status, {this.body, this.headers = const {}});

  final int status;
  final Map<String, Object?>? body;
  final Map<String, String> headers;
}

/// Why the server refuses an HTTP request before reading its body, or
/// `null` when it's one to answer.
///
/// - An `Origin` other than the server's own is a web page reaching it
///   through the browser (DNS rebinding): 403.
/// - A missing or wrong token: 401.
/// - Only `POST /mcp`, and `DELETE /mcp` to end a session: the server has
///   no event stream to `GET`.
/// - A protocol version it doesn't speak: 400.
McpHttpAnswer? refuseMcpRequest({
  required String method,
  required String path,
  required String? origin,
  required String? authorization,
  required String? protocolVersion,
  required int port,
  required String token,
}) {
  if (origin != null &&
      origin != 'http://127.0.0.1:$port' &&
      origin != 'http://localhost:$port') {
    return _refusal(403, 'Requests from $origin are refused.');
  }
  if (!_sameText(authorization ?? '', mcpAuthorization(token))) {
    return _refusal(
      401,
      'The token is missing or wrong: copy the header again in APK Forge.',
      headers: const {'WWW-Authenticate': 'Bearer'},
    );
  }
  if (path != '/mcp') return _refusal(404, 'The MCP endpoint is /mcp.');
  if (method != 'POST' && method != 'DELETE') {
    return _refusal(
      405,
      'Only POST, and DELETE to end a session: this server has no event '
      'stream.',
      headers: const {'Allow': 'POST, DELETE'},
    );
  }
  if (protocolVersion != null &&
      !mcpProtocolVersions.contains(protocolVersion)) {
    return _refusal(
      400,
      'MCP $protocolVersion isn\'t supported: '
      '${mcpProtocolVersions.join(', ')}.',
    );
  }
  return null;
}

McpHttpAnswer _refusal(
  int status,
  String message, {
  Map<String, String> headers = const {},
}) => McpHttpAnswer(
  status,
  body: _error(null, JsonRpcCode.invalidRequest, message),
  headers: headers,
);

/// Compares in a time that doesn't depend on where they differ, so the
/// token can't be guessed from how long a refusal takes.
bool _sameText(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var difference = x.length ^ y.length;
  for (var i = 0; i < x.length && i < y.length; i++) {
    difference |= x[i] ^ y[i];
  }
  return difference == 0;
}

/// The HTTP answer to the body of a `POST /mcp` that passed
/// [refuseMcpRequest]: one JSON-RPC message, answered with JSON.
///
/// - `initialize` opens a session in [sessions] with the client's
///   `clientInfo`, and its answer carries the session's ID in
///   [mcpSessionHeader].
/// - Any other message with a [sessionId] is a request in that session, and
///   a tool it calls is told the session's agent. A session [sessions]
///   doesn't have, such as one from before a restart, is 404: MCP's rule
///   for the client to send `initialize` again, and its name with it. A
///   message with no [sessionId] is answered, from [mcpUnnamedAgent].
/// - A notification, or a client's response, gets 202 with no body. A batch
///   isn't supported: MCP dropped them in 2025-06-18.
Future<McpHttpAnswer> answerMcpBody(
  String body, {
  required McpToolbox toolbox,
  required McpSessions sessions,
  String? sessionId,
}) async {
  final Object? message;
  try {
    message = jsonDecode(body);
  } on FormatException {
    return McpHttpAnswer(
      400,
      body: _error(null, JsonRpcCode.parseError, 'The body isn\'t JSON.'),
    );
  }
  if (message is List) {
    return McpHttpAnswer(
      400,
      body: _error(
        null,
        JsonRpcCode.invalidRequest,
        'Send one message per request: batches aren\'t supported.',
      ),
    );
  }
  final (method, params) = switch (message) {
    {'method': final String method, 'params': final params} => (method, params),
    {'method': final String method} => (method, null),
    _ => (null, null),
  };
  McpAgent? agent;
  if (method != null && method != 'initialize' && sessionId != null) {
    agent = sessions.request(
      sessionId,
      tool: switch ((method, params)) {
        ('tools/call', {'name': final String tool}) => tool,
        _ => null,
      },
    );
    if (agent == null) {
      return _refusal(404, 'There is no such session: send initialize again.');
    }
  }
  final answer = await answerMcpMessage(
    message,
    toolbox: toolbox,
    agent: agent?.label ?? mcpUnnamedAgent,
  );
  if (answer == null) return const McpHttpAnswer(202);
  if (method == 'initialize' && answer.containsKey('result')) {
    final client = McpClientInfo.fromJson(switch (params) {
      {'clientInfo': final info} => info,
      _ => null,
    });
    return McpHttpAnswer(
      200,
      body: answer,
      headers: {mcpSessionHeader: sessions.open(client)},
    );
  }
  return McpHttpAnswer(200, body: answer);
}

/// The HTTP answer to a `DELETE /mcp` that passed [refuseMcpRequest]: the
/// client ends its session [sessionId]. 404 for one [sessions] doesn't
/// have.
McpHttpAnswer answerMcpDelete(
  String? sessionId, {
  required McpSessions sessions,
}) {
  if (sessionId == null) {
    return _refusal(400, 'DELETE ends a session: send its $mcpSessionHeader.');
  }
  return sessions.close(sessionId)
      ? const McpHttpAnswer(204)
      : _refusal(404, 'There is no such session.');
}

/// The answer to one JSON-RPC [message] from an MCP client, or `null` when
/// it needs none. A tool it calls is told it comes from [agent].
Future<Map<String, Object?>?> answerMcpMessage(
  Object? message, {
  required McpToolbox toolbox,
  String agent = mcpUnnamedAgent,
}) async {
  if (message is! Map<String, Object?>) {
    return _error(
      null,
      JsonRpcCode.invalidRequest,
      'A message is a JSON object.',
    );
  }
  final method = message['method'];
  // A response to a request of the server's: it sends none.
  if (method is! String) {
    return message.containsKey('result') || message.containsKey('error')
        ? null
        : _error(message['id'], JsonRpcCode.invalidRequest, 'No method.');
  }
  // A notification (`notifications/initialized`…) needs no answer.
  if (!message.containsKey('id')) return null;
  final Object? id = switch (message['id']) {
    final String id => id,
    final int id => id,
    _ => null,
  };
  if (message['jsonrpc'] != '2.0' || id == null) {
    return _error(
      id,
      JsonRpcCode.invalidRequest,
      'A request is JSON-RPC 2.0, with a string or number id.',
    );
  }
  final params = switch (message['params']) {
    final Map<String, Object?> params => params,
    _ => const <String, Object?>{},
  };

  switch (method) {
    case 'initialize':
      final asked = params['protocolVersion'];
      return _result(id, {
        'protocolVersion': mcpProtocolVersions.contains(asked)
            ? asked
            : mcpProtocolVersions.first,
        'capabilities': {
          'tools': {'listChanged': false},
        },
        'serverInfo': {
          'name': mcpServerName,
          'title': 'APK Forge',
          'version': mcpToolsVersion,
        },
        'instructions': mcpInstructions,
      });
    case 'ping':
      return _result(id, const {});
    case 'tools/list':
      return _result(id, {
        'tools': [for (final tool in toolbox.tools) tool.toJson()],
      });
    case 'tools/call':
      final name = params['name'];
      if (name is! String || !toolbox.tools.any((t) => t.name == name)) {
        return _error(id, JsonRpcCode.invalidParams, 'No tool named $name.');
      }
      final arguments = params['arguments'] ?? const <String, Object?>{};
      if (arguments is! Map<String, Object?>) {
        return _error(
          id,
          JsonRpcCode.invalidParams,
          'A tool\'s arguments are a JSON object.',
        );
      }
      final McpToolResult result;
      try {
        result = await toolbox.call(name, arguments, agent: agent);
      } catch (error) {
        return _result(
          id,
          McpToolResult.error('$name failed: $error').toJson(),
        );
      }
      return _result(id, result.toJson());
    default:
      return _error(id, JsonRpcCode.methodNotFound, 'No method $method.');
  }
}

Map<String, Object?> _result(Object id, Map<String, Object?> result) => {
  'jsonrpc': '2.0',
  'id': id,
  'result': result,
};

Map<String, Object?> _error(Object? id, int code, String message) => {
  'jsonrpc': '2.0',
  'id': id,
  'error': {'code': code, 'message': message},
};
