import '../../core/system/host.dart';

/// What a Gradle `key.properties` holds, as a Flutter project's
/// `android/key.properties` does: where the keystore is and how to open
/// its key.
///
/// It carries passwords: it lives in memory only, for one run, and
/// [toString] leaves them out.
class KeyProperties {
  const KeyProperties({
    this.storeFile,
    this.keyAlias,
    this.storePassword,
    this.keyPassword,
  });

  final String? storeFile;
  final String? keyAlias;
  final String? storePassword;
  final String? keyPassword;

  /// The fields signing needs that the file doesn't have.
  List<String> get missing => [
    if (_blank(storeFile)) 'storeFile',
    if (_blank(keyAlias)) 'keyAlias',
    if (_blank(storePassword)) 'storePassword',
    if (_blank(keyPassword)) 'keyPassword',
  ];

  List<String> get secrets => [?storePassword, ?keyPassword];

  @override
  String toString() =>
      'KeyProperties(storeFile: $storeFile, keyAlias: $keyAlias)';

  static bool _blank(String? value) => value == null || value.trim().isEmpty;
}

/// Reads a `key.properties` the way `java.util.Properties.load` does, as
/// Gradle reads it: `#` and `!` comments, `=`, `:` or a space between key
/// and value, a `\` at the end of a line to continue it, and `\` escapes.
/// A value keeps its trailing spaces, as Java does.
KeyProperties parseKeyProperties(String content) {
  final values = parseJavaProperties(content);
  return KeyProperties(
    storeFile: values['storeFile'],
    keyAlias: values['keyAlias'],
    storePassword: values['storePassword'],
    keyPassword: values['keyPassword'],
  );
}

/// The key/value pairs of a `.properties` file.
Map<String, String> parseJavaProperties(String content) {
  final values = <String, String>{};
  final lines = content
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  for (var i = 0; i < lines.length; i++) {
    var line = _trimLeft(lines[i]);
    if (line.isEmpty || line.startsWith('#') || line.startsWith('!')) {
      continue;
    }
    // A line ending in an odd number of backslashes goes on.
    while (_continues(line) && i + 1 < lines.length) {
      line = line.substring(0, line.length - 1) + _trimLeft(lines[++i]);
    }
    if (_continues(line)) line = line.substring(0, line.length - 1);

    var keyEnd = 0;
    while (keyEnd < line.length) {
      final char = line[keyEnd];
      if (char == r'\') {
        keyEnd += 2;
        continue;
      }
      if (char == '=' || char == ':' || char == ' ' || char == '\t') break;
      keyEnd++;
    }
    final key = line.substring(0, keyEnd.clamp(0, line.length));
    var rest = keyEnd < line.length ? line.substring(keyEnd) : '';
    rest = _trimLeft(rest);
    if (rest.startsWith('=') || rest.startsWith(':')) {
      rest = _trimLeft(rest.substring(1));
    }
    values[_unescape(key)] = _unescape(rest);
  }
  return values;
}

bool _continues(String line) {
  var slashes = 0;
  for (var i = line.length - 1; i >= 0 && line[i] == r'\'; i--) {
    slashes++;
  }
  return slashes.isOdd;
}

String _trimLeft(String text) => text.replaceFirst(RegExp(r'^[ \t\f]+'), '');

String _unescape(String text) {
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (char != r'\' || i + 1 >= text.length) {
      out.write(char);
      continue;
    }
    final next = text[++i];
    switch (next) {
      case 't':
        out.write('\t');
      case 'n':
        out.write('\n');
      case 'r':
        out.write('\r');
      case 'f':
        out.write('\f');
      case 'u' when i + 4 < text.length:
        final code = int.tryParse(text.substring(i + 1, i + 5), radix: 16);
        if (code == null) {
          out.write('u');
        } else {
          out.writeCharCode(code);
          i += 4;
        }
      default:
        // `\\`, `\=`, `\:`, `\ ` and any other escaped character: itself.
        out.write(next);
    }
  }
  return out.toString();
}

/// What the target editor shows about a `key.properties`: where its
/// keystore is, its alias, and whether the passwords are there. It never
/// holds the passwords themselves.
class KeyFileSummary {
  const KeyFileSummary({
    required this.path,
    this.error,
    this.storeFile,
    this.keystorePath,
    this.keystoreExists = false,
    this.alias,
    this.missing = const [],
  });

  final String path;

  /// Why the file couldn't be read at all.
  final String? error;

  /// As written in the file.
  final String? storeFile;

  /// [storeFile] resolved as Gradle does.
  final String? keystorePath;
  final bool keystoreExists;
  final String? alias;

  /// The fields the file lacks (`keyPassword`…).
  final List<String> missing;

  bool get hasStorePassword => !missing.contains('storePassword');
  bool get hasKeyPassword => !missing.contains('keyPassword');

  /// Why a run with this file won't start yet.
  List<String> get problems => [
    ?error,
    if (missing.isNotEmpty) 'It has no ${missing.join(', ')}.',
    if (keystorePath != null && !keystoreExists)
      'The keystore $keystorePath does not exist.',
  ];
}

/// [content], the `key.properties` at [path], summed up for the editor.
KeyFileSummary summarizeKeyProperties(
  String path,
  String content,
  Host host,
  bool Function(String path) fileExists,
) {
  final keys = parseKeyProperties(content);
  final storeFile = keys.storeFile?.trim();
  final keystore = storeFile == null || storeFile.isEmpty
      ? null
      : resolveStoreFile(path, storeFile, host);
  return KeyFileSummary(
    path: path,
    storeFile: storeFile,
    keystorePath: keystore,
    keystoreExists: keystore != null && fileExists(keystore),
    alias: keys.keyAlias?.trim(),
    missing: keys.missing,
  );
}

/// Where Gradle finds [storeFile] for the `key.properties` at
/// [propertiesPath].
///
/// A Flutter project's `android/app/build.gradle` passes it to `file()`,
/// which resolves it from `android/app/`: so a relative path in a
/// `key.properties` inside an `android/` folder starts there. Anywhere
/// else, it starts from the file's own folder.
String resolveStoreFile(String propertiesPath, String storeFile, Host host) {
  final path = host.path;
  if (path.isAbsolute(storeFile)) return path.normalize(storeFile);
  final folder = path.dirname(propertiesPath);
  final base = path.basename(folder) == 'android'
      ? path.join(folder, 'app')
      : folder;
  return path.normalize(path.join(base, storeFile));
}
