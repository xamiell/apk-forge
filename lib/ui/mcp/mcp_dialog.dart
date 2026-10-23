import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mcp/mcp_protocol.dart';
import '../../domain/mcp/profile_tools.dart';
import '../../state/mcp_notifier.dart';
import '../common/widgets.dart';
import '../theme.dart';

/// The MCP server in the top bar: whether it's on, and the button that
/// opens its dialog.
class McpButton extends ConsumerWidget {
  const McpButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(mcpServerProvider);
    final colors = context.status;
    void open() =>
        showDialog<void>(context: context, builder: (_) => const McpDialog());
    final pill = switch (server.status) {
      McpServerStatus.on => Tooltip(
        message: 'MCP server on at ${server.url}',
        child: Pill('MCP', color: colors.ok, icon: Icons.check_rounded),
      ),
      McpServerStatus.failed => Tooltip(
        message: server.failure?.title ?? 'The MCP server couldn\'t start',
        child: Pill('MCP', color: colors.error, icon: Icons.close_rounded),
      ),
      McpServerStatus.starting || McpServerStatus.off => null,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pill != null)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: InkWell(
              onTap: open,
              borderRadius: BorderRadius.circular(999),
              child: pill,
            ),
          ),
        IconButton(
          tooltip: 'Agent access (MCP)',
          icon: const Icon(Icons.smart_toy_outlined, size: 20),
          onPressed: open,
        ),
      ],
    );
  }
}

/// Turns the MCP server on or off, says how to connect an agent, and
/// whether an agent's run waits for Allow.
class McpDialog extends ConsumerStatefulWidget {
  const McpDialog({super.key});

  @override
  ConsumerState<McpDialog> createState() => _McpDialogState();
}

class _McpDialogState extends ConsumerState<McpDialog> {
  late final _port = TextEditingController(
    text: '${ref.read(mcpServerProvider).settings.port}',
  );

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  void _applyPort() {
    if (mcpPortProblem(_port.text) != null) return;
    ref.read(mcpServerProvider.notifier).setPort(int.parse(_port.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final server = ref.watch(mcpServerProvider);
    final notifier = ref.read(mcpServerProvider.notifier);
    final colors = context.status;
    final settings = server.settings;
    final portProblem = mcpPortProblem(_port.text);
    final portChanged =
        portProblem == null && int.parse(_port.text.trim()) != settings.port;
    final authorization = server.authorization;

    return AlertDialog(
      title: const Text('Agent access (MCP)'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Lets an agent (any MCP client) list the signing profiles, '
                'check a run and run one. It listens on this computer only '
                '(127.0.0.1) and needs the token. Passwords never leave the '
                'app.',
                style: TextStyle(fontSize: 12.5, color: colors.muted),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('MCP server'),
                subtitle: Text(switch (server.status) {
                  McpServerStatus.off => 'Off',
                  McpServerStatus.starting => 'Starting…',
                  McpServerStatus.on => 'On at ${server.url}',
                  McpServerStatus.failed =>
                    server.failure?.title ?? 'It couldn\'t start',
                }),
                value: settings.enabled,
                onChanged: server.status == McpServerStatus.starting
                    ? null
                    : (on) => on ? notifier.turnOn() : notifier.turnOff(),
              ),
              if (server.status == McpServerStatus.failed)
                ProblemText(server.failure?.details ?? const []),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Ask before an agent runs a profile'),
                subtitle: Text(
                  settings.askToRun
                      ? 'Once the check passes, APK Forge shows the plan and '
                            'waits for Allow.'
                      : 'A run starts as soon as its check passes.',
                ),
                value: settings.askToRun,
                onChanged: (ask) => notifier.setAskToRun(ask),
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 160,
                    child: TextField(
                      controller: _port,
                      decoration: InputDecoration(
                        labelText: 'Port',
                        errorText: portProblem,
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _applyPort(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TextButton(
                      onPressed: portChanged ? _applyPort : null,
                      child: const Text('Use this port'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Connect an agent',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              if (authorization == null)
                Text(
                  'Turn the server on to make its token.',
                  style: TextStyle(fontSize: 12.5, color: colors.muted),
                )
              else ...[
                Text(
                  'In your agent\'s MCP settings, add an HTTP server with '
                  'this address and header. The README has an example.',
                  style: TextStyle(fontSize: 12.5, color: colors.muted),
                ),
                const SizedBox(height: 6),
                InfoRow(
                  'Address',
                  server.url,
                  mono: true,
                  trailing: CopyButton(server.url, tooltip: 'Copy the address'),
                ),
                InfoRow(
                  'Authorization',
                  mcpAuthorization('••••••••'),
                  mono: true,
                  trailing: CopyButton(
                    authorization,
                    tooltip: 'Copy the header, with the token',
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'New token makes another one: an agent connected with the '
                  'old one must be given the new header.',
                  style: TextStyle(fontSize: 12, color: colors.muted),
                ),
              ],
              const SizedBox(height: 16),
              Text('Tools', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final tool in profileTools)
                InfoRow(tool.name, tool.title, mono: false),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: settings.token == null ? null : notifier.newToken,
          child: const Text('New token'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
