import 'dart:io';

import 'package:path/path.dart' as p;

enum HostOs { macos, windows, linux }

/// The machine the app runs on, as plain values.
///
/// Code that depends on the OS or the environment takes a [Host] instead of
/// reading `Platform`, so a test can describe a Windows machine while it runs
/// on a Mac.
class Host {
  const Host({required this.os, required this.environment});

  factory Host.current(Map<String, String> environment) => Host(
    os: Platform.isWindows
        ? HostOs.windows
        : Platform.isMacOS
        ? HostOs.macos
        : HostOs.linux,
    environment: environment,
  );

  final HostOs os;
  final Map<String, String> environment;

  bool get isWindows => os == HostOs.windows;

  p.Context get path => isWindows
      ? p.Context(style: p.Style.windows)
      : p.Context(style: p.Style.posix);

  String? get home =>
      isWindows ? environment['USERPROFILE'] : environment['HOME'];

  /// `adb` → `adb.exe` on Windows, where most SDK tools have an extension.
  String executableName(String name, {String windowsExtension = '.exe'}) =>
      isWindows ? '$name$windowsExtension' : name;

  List<String> get pathEntries {
    final value = environment['PATH'] ?? environment['Path'] ?? '';
    return value
        .split(isWindows ? ';' : ':')
        .where((entry) => entry.isNotEmpty)
        .toList();
  }
}

/// What the app asks the file system, so a test can answer instead.
abstract interface class FileProbe {
  bool fileExists(String path);
  bool directoryExists(String path);

  /// The names (not paths) of the directories directly inside [path].
  List<String> directoryNames(String path);
}

class IoFileProbe implements FileProbe {
  const IoFileProbe();

  @override
  bool fileExists(String path) => File(path).existsSync();

  @override
  bool directoryExists(String path) => Directory(path).existsSync();

  @override
  List<String> directoryNames(String path) {
    final directory = Directory(path);
    if (!directory.existsSync()) return const [];
    return directory
        .listSync(followLinks: false)
        .whereType<Directory>()
        .map((entry) => p.basename(entry.path))
        .toList();
  }
}

/// The first `PATH` entry that holds [executable], like `which`.
String? findOnPath(String executable, Host host, FileProbe probe) {
  for (final directory in host.pathEntries) {
    final candidate = host.path.join(directory, executable);
    if (probe.fileExists(candidate)) return candidate;
  }
  return null;
}
