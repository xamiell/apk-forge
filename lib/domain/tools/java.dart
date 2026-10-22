/// `java` arguments that print its version, on stderr.
const javaVersionArguments = ['-version'];

final _javaVersion = RegExp(r'^\S+ version "([^"]+)"');

/// The version `java -version` prints (`openjdk version "21.0.10" …` →
/// `21.0.10`); `null` when it printed something else.
String? parseJavaVersion(Iterable<String> lines) {
  for (final line in lines) {
    if (_javaVersion.firstMatch(line.trim()) case final match?) {
      return match.group(1);
    }
  }
  return null;
}
