import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/failure.dart';
import '../domain/mcp/mcp_protocol.dart';
import '../services/mcp_server.dart';
import 'log_notifier.dart';
import 'mcp_agents.dart';
import 'mcp_tools.dart';
import 'providers.dart';

/// What the app keeps of the MCP server: whether it's on, its port, its
/// token, and whether an agent's run waits for Allow.
class McpSettings {
  const McpSettings({
    this.enabled = false,
    this.port = mcpDefaultPort,
    this.token,
    this.askToRun = true,
  });

  factory McpSettings.fromJson(Map<String, Object?> json) => McpSettings(
    enabled: json['enabled'] as bool? ?? false,
    port: json['port'] as int? ?? mcpDefaultPort,
    token: json['token'] as String?,
    askToRun: json['askToRun'] as bool? ?? true,
  );

  /// Whether it was turned on: it comes back on at launch.
  final bool enabled;
  final int port;

  /// Made the first time the server is turned on, and again by New token.
  /// The one secret the settings keep (ARCHITECTURE §3).
  final String? token;

  /// Whether the app asks its user to allow each run an agent asks for,
  /// once its check passes. On until it's turned off.
  final bool askToRun;

  McpSettings copyWith({
    bool? enabled,
    int? port,
    String? token,
    bool? askToRun,
  }) => McpSettings(
    enabled: enabled ?? this.enabled,
    port: port ?? this.port,
    token: token ?? this.token,
    askToRun: askToRun ?? this.askToRun,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'port': port,
    'token': token,
    'askToRun': askToRun,
  };

  @override
  String toString() =>
      'McpSettings(enabled: $enabled, port: $port, askToRun: $askToRun)';
}

enum McpServerStatus { off, starting, on, failed }

class McpServerState {
  const McpServerState({
    required this.settings,
    this.status = McpServerStatus.off,
    this.failure,
  });

  final McpSettings settings;
  final McpServerStatus status;

  /// Why it couldn't start, while [status] is [McpServerStatus.failed].
  final ToolFailure? failure;

  String get url => mcpUrl(settings.port);

  /// The `Authorization` header an agent sends; `null` until there's a
  /// token.
  String? get authorization => switch (settings.token) {
    final token? => mcpAuthorization(token),
    null => null,
  };
}

/// The MCP server: off until it's turned on, then on at every launch until
/// it's turned off.
final mcpServerProvider = NotifierProvider<McpServerNotifier, McpServerState>(
  McpServerNotifier.new,
);

class McpServerNotifier extends Notifier<McpServerState> {
  McpServerStop? _stop;

  @override
  McpServerState build() {
    ref.onDispose(() => _stop?.call());
    final saved = ref.read(settingsStoreProvider).read(SettingsKey.mcp);
    return McpServerState(
      settings: saved == null
          ? const McpSettings()
          : McpSettings.fromJson(saved),
    );
  }

  /// At launch: back on if it was on when the app closed.
  Future<void> resume() async {
    if (state.settings.enabled && state.status == McpServerStatus.off) {
      await _start();
    }
  }

  /// Makes the token the first time.
  Future<void> turnOn() async {
    if (state.status == McpServerStatus.starting) return;
    _save(
      state.settings.copyWith(
        enabled: true,
        token: state.settings.token ?? ref.read(mcpTokenMakerProvider)(),
      ),
    );
    await _start();
  }

  Future<void> turnOff() async {
    _save(state.settings.copyWith(enabled: false));
    final wasOn = _stop != null;
    await _stopServer();
    state = McpServerState(settings: state.settings);
    if (wasOn) ref.read(logProvider.notifier).info('MCP server off.');
  }

  /// The server moves to [port] if it's on.
  Future<void> setPort(int port) async {
    final moved = port != state.settings.port;
    _save(state.settings.copyWith(port: port));
    if (moved && state.settings.enabled) await _start();
  }

  /// Whether an agent's run waits for Allow. Takes effect at once, server
  /// on or off.
  void setAskToRun(bool ask) => _save(state.settings.copyWith(askToRun: ask));

  /// The old token stops working: every client must be registered again.
  Future<void> newToken() async {
    _save(state.settings.copyWith(token: ref.read(mcpTokenMakerProvider)()));
    if (state.settings.enabled) await _start();
  }

  void _save(McpSettings settings) {
    state = McpServerState(
      settings: settings,
      status: state.status,
      failure: state.failure,
    );
    ref.read(settingsStoreProvider).write(SettingsKey.mcp, settings.toJson());
  }

  Future<void> _start() async {
    await _stopServer();
    final settings = state.settings;
    final token = settings.token;
    if (token == null) return;
    state = McpServerState(
      settings: settings,
      status: McpServerStatus.starting,
    );
    final log = ref.read(logProvider.notifier);
    try {
      _stop = await ref.read(mcpServerStarterProvider)(
        port: settings.port,
        token: token,
        toolbox: ref.read(mcpToolboxProvider),
        sessions: ref.read(mcpAgentsProvider.notifier),
      );
    } on ToolFailure catch (failure) {
      state = McpServerState(
        settings: state.settings,
        status: McpServerStatus.failed,
        failure: failure,
      );
      log.error(failure.title);
      for (final line in failure.details) {
        log.error('  $line');
      }
      return;
    }
    // Turned off while it was starting.
    if (!state.settings.enabled) return _stopServer();
    state = McpServerState(
      settings: state.settings,
      status: McpServerStatus.on,
    );
    log.success('MCP server on at ${mcpUrl(settings.port)}.');
  }

  /// A run waiting for Allow is declined: its request is cut. The agents'
  /// sessions end with the server.
  Future<void> _stopServer() async {
    final stop = _stop;
    _stop = null;
    if (stop == null) return;
    ref.read(mcpRunRequestProvider.notifier).answer(allow: false);
    await stop();
    ref.read(mcpAgentsProvider.notifier).clear();
  }
}
