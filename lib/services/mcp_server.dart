import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/failure.dart';
import '../domain/mcp/mcp_agents.dart';
import '../domain/mcp/mcp_protocol.dart';

/// Stops a running MCP server. Open requests are cut; a run they started
/// goes on in the app.
typedef McpServerStop = Future<void> Function();

/// The MCP server over HTTP, on the loopback address only.
///
/// Thin on purpose: what it refuses ([refuseMcpRequest]) and what it
/// answers ([answerMcpBody], [answerMcpDelete]) are decided in
/// `domain/mcp`.
abstract final class McpHttpServer {
  /// A request body larger than this is refused: a tool call is a few
  /// hundred bytes.
  static const maxBodyBytes = 1 << 20;

  /// Listens on 127.0.0.1:[port] until the returned function is called,
  /// keeping its agents' sessions in [sessions]. Throws [ToolFailure] when
  /// it can't, such as a port in use.
  static Future<McpServerStop> start({
    required int port,
    required String token,
    required McpToolbox toolbox,
    required McpSessions sessions,
  }) async {
    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException catch (error) {
      throw ToolFailure(
        'The MCP server can\'t listen on 127.0.0.1:$port',
        details: [
          'Another program may be using the port: choose another one.',
          ?error.osError?.message,
        ],
      );
    }
    server.listen(
      (request) => _answer(
        request,
        port: port,
        token: token,
        toolbox: toolbox,
        sessions: sessions,
      ),
    );
    return () => server.close(force: true);
  }

  static Future<void> _answer(
    HttpRequest request, {
    required int port,
    required String token,
    required McpToolbox toolbox,
    required McpSessions sessions,
  }) async {
    McpHttpAnswer answer;
    try {
      final headers = request.headers;
      final sessionId = headers.value(mcpSessionHeader);
      answer =
          refuseMcpRequest(
            method: request.method,
            path: request.uri.path,
            origin: headers.value('origin'),
            authorization: headers.value(HttpHeaders.authorizationHeader),
            protocolVersion: headers.value('mcp-protocol-version'),
            port: port,
            token: token,
          ) ??
          (request.method == 'DELETE'
              ? answerMcpDelete(sessionId, sessions: sessions)
              : switch (await _body(request)) {
                  final body? => await answerMcpBody(
                    body,
                    toolbox: toolbox,
                    sessions: sessions,
                    sessionId: sessionId,
                  ),
                  null => const McpHttpAnswer(413),
                });
    } on Object {
      // The tools answer their own failures: this is a request that broke
      // off, or a bug.
      answer = const McpHttpAnswer(500);
    }
    try {
      final response = request.response..statusCode = answer.status;
      answer.headers.forEach(response.headers.set);
      if (answer.body case final body?) {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(body));
      }
      await response.close();
    } on Object {
      // The client went away before its answer: nothing to tell it.
    }
  }

  /// The body as text, or `null` when it's over [maxBodyBytes].
  static Future<String?> _body(HttpRequest request) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request) {
      bytes.add(chunk);
      if (bytes.length > maxBodyBytes) return null;
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }
}
