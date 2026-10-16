/// One call to an external program: what runs, where, and which values must
/// never reach the screen.
class Command {
  const Command(
    this.executable,
    this.arguments, {
    this.workingDirectory,
    this.environment = const {},
    this.secrets = const [],
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;

  /// Added on top of the base environment.
  ///
  /// Passwords travel here (`apksigner --ks-pass env:NAME`,
  /// `keytool -storepass:env NAME`) and never in [arguments], which any user
  /// on the machine can read with `ps` while the program runs.
  final Map<String, String> environment;

  /// Values masked wherever they show up in the log, output included.
  final List<String> secrets;

  /// The command as a shell line, for the log. [environment] is left out on
  /// purpose: it is where the secrets are.
  String get displayLine =>
      [executable, ...arguments].map(shellQuote).join(' ');
}

final _safeShellWord = RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$');

/// Quotes [word] so the log line can be pasted into a POSIX shell.
String shellQuote(String word) {
  if (word.isEmpty) return "''";
  if (_safeShellWord.hasMatch(word)) return word;
  return "'${word.replaceAll("'", r"'\''")}'";
}

/// Replaces every non-empty [secrets] value in [text] with `••••`.
String maskSecrets(String text, Iterable<String> secrets) {
  var masked = text;
  for (final secret in secrets) {
    if (secret.isEmpty) continue;
    masked = masked.replaceAll(secret, '••••');
  }
  return masked;
}
