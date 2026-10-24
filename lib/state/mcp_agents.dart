import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/mcp/mcp_agents.dart';
import 'log_notifier.dart';
import 'providers.dart';

/// The agents with a session on the MCP server, the most recent request
/// first. Empty while the server is off: its sessions end with it.
final mcpAgentsProvider = NotifierProvider<McpAgentsNotifier, List<McpAgent>>(
  McpAgentsNotifier.new,
);

class McpAgentsNotifier extends Notifier<List<McpAgent>>
    implements McpSessions {
  /// The most it keeps: an agent that quits without ending its session
  /// stays, so the oldest go first.
  static const maxAgents = 20;

  @override
  List<McpAgent> build() => const [];

  @override
  String open(McpClientInfo client) {
    final id = ref.read(mcpSessionIdMakerProvider)();
    final now = ref.read(clockProvider)();
    _first(
      McpAgent(
        sessionId: id,
        client: client,
        connectedAt: now,
        lastRequestAt: now,
      ),
    );
    ref
        .read(logProvider.notifier)
        .info('${client.label} connected to the MCP server.');
    return id;
  }

  @override
  void request(String sessionId, {String? tool}) {
    final now = ref.read(clockProvider)();
    _first(
      _find(sessionId)?.requested(now, tool: tool) ??
          McpAgent(sessionId: sessionId, lastRequestAt: now, lastTool: tool),
    );
  }

  @override
  bool close(String sessionId) {
    final agent = _find(sessionId);
    if (agent == null) return false;
    state = [
      for (final other in state)
        if (other.sessionId != sessionId) other,
    ];
    ref
        .read(logProvider.notifier)
        .info('${agent.label} disconnected from the MCP server.');
    return true;
  }

  /// The server stopped: every session ended with it.
  void clear() => state = const [];

  McpAgent? _find(String sessionId) {
    for (final agent in state) {
      if (agent.sessionId == sessionId) return agent;
    }
    return null;
  }

  void _first(McpAgent agent) => state = [
    agent,
    for (final other in state)
      if (other.sessionId != agent.sessionId) other,
  ].take(maxAgents).toList();
}
