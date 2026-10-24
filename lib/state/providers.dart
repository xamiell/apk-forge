import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/process/process_runner.dart';
import '../core/system/host.dart';
import '../domain/mcp/mcp_agents.dart';
import '../domain/mcp/mcp_protocol.dart';
import '../services/adb_service.dart';
import '../services/apk_analyzer.dart';
import '../services/apk_split_service.dart';
import '../services/bundle_install_service.dart';
import '../services/bundle_signing_service.dart';
import '../services/desktop_shell.dart';
import '../services/flutter_build_service.dart';
import '../services/installed_apk_service.dart';
import '../services/mcp_server.dart';
import '../services/new_key_service.dart';
import '../services/profile_runner.dart';
import '../services/signing_service.dart';

/// The environment programs start with: the login shell's, loaded once in
/// `main`. Overridden there.
final environmentProvider = Provider<Map<String, String>>(
  (ref) => throw UnimplementedError('Overridden in main().'),
);

/// Overridden in `main` with the preferences, and in tests with memory.
final settingsStoreProvider = Provider<SettingsStore>(
  (ref) => throw UnimplementedError('Overridden in main().'),
);

final hostProvider = Provider<Host>(
  (ref) => Host.current(ref.watch(environmentProvider)),
);

final fileProbeProvider = Provider<FileProbe>((ref) => const IoFileProbe());

final processRunnerProvider = Provider<ProcessRunner>(
  (ref) => IoProcessRunner(ref.watch(hostProvider)),
);

final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Shows the file at [path] in the OS file manager.
typedef FileRevealer = Future<void> Function(String path, Host host);

/// Overridden in tests, so they open no window.
final fileRevealerProvider = Provider<FileRevealer>(
  (ref) => revealInFileManager,
);

/// Creates the folder at a path, and the folders above it.
typedef FolderCreator = Future<void> Function(String path);

/// Overridden in tests, so they write nothing.
final folderCreatorProvider = Provider<FolderCreator>(
  (ref) =>
      (path) => Directory(path).create(recursive: true),
);

/// Starts the MCP server on 127.0.0.1:[port] with [toolbox]'s tools, keeping
/// its agents' sessions in [sessions].
typedef McpServerStarter = Future<McpServerStop> Function({
  required int port,
  required String token,
  required McpToolbox toolbox,
  required McpSessions sessions,
});

/// Overridden in tests, so they open no port.
final mcpServerStarterProvider = Provider<McpServerStarter>(
  (ref) => McpHttpServer.start,
);

/// Makes a new token for the MCP server. Overridden in tests.
final mcpTokenMakerProvider = Provider<String Function()>(
  (ref) =>
      () => newMcpToken(Random.secure()),
);

/// Makes the ID of a new MCP session: random like a token, so one session
/// can't guess another's. Overridden in tests.
final mcpSessionIdMakerProvider = Provider<String Function()>(
  (ref) =>
      () => newMcpToken(Random.secure()),
);

final flutterBuildServiceProvider = Provider(
  (ref) => FlutterBuildService(host: ref.watch(hostProvider)),
);
final keystoreServiceProvider = Provider((ref) => const KeystoreService());
final newKeyServiceProvider = Provider(
  (ref) => NewKeyService(host: ref.watch(hostProvider)),
);
final signingServiceProvider = Provider(
  (ref) => ApkSigningService(host: ref.watch(hostProvider)),
);
final bundleSigningServiceProvider = Provider(
  (ref) => BundleSigningService(host: ref.watch(hostProvider)),
);
final bundleInstallServiceProvider = Provider(
  (ref) => BundleInstallService(host: ref.watch(hostProvider)),
);
final apkSplitServiceProvider = Provider(
  (ref) => ApkSplitService(host: ref.watch(hostProvider)),
);
final apkAnalyzerProvider = Provider((ref) => const ApkAnalyzer());
final adbServiceProvider = Provider((ref) => const AdbService());
final profileKeyServiceProvider = Provider(
  (ref) => ProfileKeyService(host: ref.watch(hostProvider)),
);
final profileRunnerProvider = Provider(
  (ref) => ProfileRunner(
    host: ref.watch(hostProvider),
    signing: ref.watch(signingServiceProvider),
  ),
);
final installedApkServiceProvider = Provider(
  (ref) => InstalledApkService(
    host: ref.watch(hostProvider),
    analyzer: ref.watch(apkAnalyzerProvider),
  ),
);

/// What the app saves between launches, one entry each.
///
/// [storageName] is where it's stored: changing one loses what was saved
/// under the old name.
enum SettingsKey {
  defaults('defaults'),
  build('build'),
  signing('signing'),
  tools('tools'),
  profiles('profiles'),
  profileHistory('profile_history'),
  mcp('mcp');

  const SettingsKey(this.storageName);
  final String storageName;
}

/// Remembers the forms between launches. Passwords never come here; the
/// MCP server's token does (ARCHITECTURE §3).
abstract interface class SettingsStore {
  Map<String, Object?>? read(SettingsKey key);
  void write(SettingsKey key, Map<String, Object?> value);
}

class PreferencesSettingsStore implements SettingsStore {
  const PreferencesSettingsStore(this._preferences);

  final SharedPreferences _preferences;

  static const _prefix = 'apk_forge.';

  @override
  Map<String, Object?>? read(SettingsKey key) {
    final raw = _preferences.getString('$_prefix${key.storageName}');
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  @override
  void write(SettingsKey key, Map<String, Object?> value) {
    _preferences.setString('$_prefix${key.storageName}', jsonEncode(value));
  }
}

class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([Map<SettingsKey, Map<String, Object?>>? initial])
    : values = {...?initial};

  final Map<SettingsKey, Map<String, Object?>> values;

  @override
  Map<String, Object?>? read(SettingsKey key) => values[key];

  @override
  void write(SettingsKey key, Map<String, Object?> value) =>
      values[key] = value;
}
