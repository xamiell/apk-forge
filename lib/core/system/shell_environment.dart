import 'dart:convert';
import 'dart:io';

const _startMarker = '__APK_FORGE_ENV_START__';
const _endMarker = '__APK_FORGE_ENV_END__';

/// The environment a terminal would have.
///
/// An app opened from Finder or the Dock starts with a bare `PATH`
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), so `flutter`, `java` and anything the
/// user's shell profile adds are missing. On macOS and Linux this asks the
/// user's login shell for its environment once, at startup. On Windows, and
/// whenever the shell doesn't answer, the app's own environment is used.
Future<Map<String, String>> loadShellEnvironment() async {
  final own = Map<String, String>.of(Platform.environment);
  if (Platform.isWindows) return own;

  final shell = own['SHELL'] ?? '/bin/zsh';
  try {
    final result = await Process.run(
      shell,
      // Interactive and login, so both .zprofile and .zshrc are read: PATH
      // additions live in either one.
      ['-ilc', 'echo $_startMarker; /usr/bin/env; echo $_endMarker'],
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
    ).timeout(const Duration(seconds: 10));
    if (result.exitCode != 0) return own;
    final loaded = parseEnvOutput(result.stdout as String);
    if (loaded.isEmpty) return own;
    return {...own, ...loaded};
  } on Object {
    return own;
  }
}

/// Reads the `KEY=value` lines between the markers, ignoring whatever the
/// shell's profile printed before them.
Map<String, String> parseEnvOutput(String output) {
  final start = output.indexOf(_startMarker);
  final end = output.lastIndexOf(_endMarker);
  if (start < 0 || end < start) return const {};

  final environment = <String, String>{};
  final body = output.substring(start + _startMarker.length, end);
  for (final line in const LineSplitter().convert(body)) {
    final separator = line.indexOf('=');
    if (separator <= 0) continue;
    environment[line.substring(0, separator)] = line.substring(separator + 1);
  }
  return environment;
}
