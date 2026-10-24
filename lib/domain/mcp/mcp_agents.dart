import '../../core/format/format.dart';

/// The header that carries an MCP session's ID: the server gives it in
/// `initialize`'s answer, and the client sends it with each request after.
const mcpSessionHeader = 'Mcp-Session-Id';

/// Who an MCP client says it is, in `initialize`'s `clientInfo`.
class McpClientInfo {
  const McpClientInfo({this.name, this.title, this.version});

  /// What the client sent. Each value is the client's own text, so it's
  /// cut to one short line before the dialog and the log show it.
  factory McpClientInfo.fromJson(Object? json) {
    if (json is! Map<String, Object?>) return const McpClientInfo();
    return McpClientInfo(
      name: _line(json['name']),
      title: _line(json['title']),
      version: _line(json['version']),
    );
  }

  final String? name;
  final String? title;
  final String? version;

  /// `Claude Code 2.1.0`: its title, else its name, and its version.
  String get label => [title ?? name ?? 'An unnamed agent', ?version].join(' ');
}

/// [value] as one line of at most 60 characters, or `null` when it isn't
/// text or is blank.
String? _line(Object? value) {
  if (value is! String) return null;
  final line = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]+'), ' ').trim();
  if (line.isEmpty) return null;
  return line.length <= 60 ? line : '${line.substring(0, 59)}…';
}

/// An agent with a session on the MCP server.
class McpAgent {
  const McpAgent({
    required this.sessionId,
    this.client,
    this.connectedAt,
    required this.lastRequestAt,
    this.lastTool,
  });

  /// Never shown or logged: the dialog names the agent by [label].
  final String sessionId;

  /// `null` for a session this server didn't open: the agent connected
  /// before the app or the server restarted.
  final McpClientInfo? client;

  /// `null` when [client] is.
  final DateTime? connectedAt;
  final DateTime lastRequestAt;

  /// The last tool it called, if any.
  final String? lastTool;

  String get label =>
      client?.label ?? 'An agent connected before the server restarted';

  /// `Connected 14:05 · last request 14:09 · last tool list_profiles`, with
  /// the day too for a moment before [now]'s.
  String activity(DateTime now) {
    final last = formatMoment(lastRequestAt, now);
    return [
      switch (connectedAt) {
        final connected? =>
          'Connected ${formatMoment(connected, now)} · last request $last',
        null => 'Last request $last',
      },
      if (lastTool case final tool?) 'last tool $tool',
    ].join(' · ');
  }

  McpAgent requested(DateTime at, {String? tool}) => McpAgent(
    sessionId: sessionId,
    client: client,
    connectedAt: connectedAt,
    lastRequestAt: at,
    lastTool: tool ?? lastTool,
  );
}

/// The server's sessions: one per agent that sent `initialize`. The app's
/// is `McpAgentsNotifier`.
abstract interface class McpSessions {
  /// Opens a session for [client] and returns its ID.
  String open(McpClientInfo client);

  /// A request in the session [sessionId]: a tool call names its [tool]. An
  /// ID it doesn't know is a session from before a restart, and is kept.
  void request(String sessionId, {String? tool});

  /// Ends the session [sessionId]; `false` when there's none.
  bool close(String sessionId);
}
