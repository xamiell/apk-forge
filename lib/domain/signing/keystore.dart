import '../../core/format/format.dart';

/// One key in a keystore, as `keytool -list -v` describes it.
class KeystoreEntry {
  const KeystoreEntry({
    required this.alias,
    required this.entryType,
    this.owner,
    this.sha256,
    this.validUntil,
    this.keyAlgorithm,
  });

  final String alias;

  /// `PrivateKeyEntry` can sign; a `trustedCertEntry` can't.
  final String entryType;
  final String? owner;

  /// Normalized with [normalizeDigest], ready to compare with apksigner's.
  final String? sha256;
  final String? validUntil;

  /// For example `2048-bit RSA key`.
  final String? keyAlgorithm;

  bool get canSign => entryType == 'PrivateKeyEntry';
}

final _field = RegExp(r'^\s*([A-Za-z0-9 \[\]]+?):\s*(.*)$');
final _validity = RegExp(r'until:\s*(.+)$');

/// Reads the entries of `keytool -list -v` output.
///
/// keytool translates its labels to the system language, so it must run
/// with `-J-Duser.language=en` (see `keytoolListArguments`); this parser
/// only knows the English ones.
List<KeystoreEntry> parseKeytoolList(Iterable<String> lines) {
  final entries = <KeystoreEntry>[];
  String? alias;
  var entryType = '';
  String? owner;
  String? sha256;
  String? validUntil;
  String? keyAlgorithm;
  var inFirstCertificate = false;

  void flush() {
    if (alias != null) {
      entries.add(
        KeystoreEntry(
          alias: alias!,
          entryType: entryType,
          owner: owner,
          sha256: sha256,
          validUntil: validUntil,
          keyAlgorithm: keyAlgorithm,
        ),
      );
    }
    alias = null;
    entryType = '';
    owner = sha256 = validUntil = keyAlgorithm = null;
    inFirstCertificate = false;
  }

  for (final line in lines) {
    final match = _field.firstMatch(line);
    if (match == null) continue;
    final key = match.group(1)!.trim();
    final value = match.group(2)!.trim();

    switch (key) {
      case 'Alias name':
        flush();
        alias = value;
      case 'Entry type':
        entryType = value;
        inFirstCertificate = true;
      // A chain lists several certificates; the signer is the first one.
      case 'Certificate[2]':
        inFirstCertificate = false;
      case 'Owner' when inFirstCertificate && owner == null:
        owner = value;
      case 'Valid from' when inFirstCertificate && validUntil == null:
        validUntil = _validity.firstMatch(value)?.group(1)?.trim();
      case 'SHA256' when inFirstCertificate && sha256 == null:
        sha256 = normalizeDigest(value);
      case 'Subject Public Key Algorithm'
          when inFirstCertificate && keyAlgorithm == null:
        keyAlgorithm = value;
    }
  }
  flush();
  return entries;
}

/// The keystore environment variables. Passwords go through the
/// environment, never the command line.
const keystorePasswordVariable = 'APK_FORGE_KS_PASS';
const keyPasswordVariable = 'APK_FORGE_KEY_PASS';

List<String> keytoolListArguments(String keystorePath) => [
  // English labels, whatever the system language: the parser reads them.
  '-J-Duser.language=en',
  '-J-Duser.country=US',
  '-list',
  '-v',
  '-keystore',
  keystorePath,
  '-storepass:env',
  keystorePasswordVariable,
];

/// `keytool` arguments that open [alias]'s private key with both passwords
/// (from the environment) and print a certificate request: it fails on a
/// wrong key password, which `-list` doesn't check. It writes nothing.
List<String> keytoolCertreqArguments(String keystorePath, String alias) => [
  '-J-Duser.language=en',
  '-J-Duser.country=US',
  '-certreq',
  '-keystore',
  keystorePath,
  '-alias',
  alias,
  '-storepass:env',
  keystorePasswordVariable,
  '-keypass:env',
  keyPasswordVariable,
];

/// `keytool` arguments that make a keystore at [keystorePath] with one new
/// RSA key, [alias], both passwords read from the environment. A PKCS12
/// keystore keeps one password for the store and its key; a `JKS` one can
/// give the key its own. The app doesn't make keys: `tool/smoke.dart` makes
/// throwaway ones with it.
List<String> keytoolGenerateKeyArguments(
  String keystorePath,
  String alias, {
  required String distinguishedName,
  String storeType = 'PKCS12',
}) => [
  '-J-Duser.language=en',
  '-J-Duser.country=US',
  '-genkeypair',
  '-keystore',
  keystorePath,
  '-storetype',
  storeType,
  '-storepass:env',
  keystorePasswordVariable,
  '-keypass:env',
  keyPasswordVariable,
  '-alias',
  alias,
  '-keyalg',
  'RSA',
  '-keysize',
  '2048',
  '-validity',
  '365',
  '-dname',
  distinguishedName,
];

/// Why `keytool -certreq` couldn't open the key, in plain words; `null`
/// when it printed the request, so the key opens.
String? parseKeyOpenFailure(Iterable<String> lines) {
  final all = lines.map((line) => line.trim()).toList();
  if (all.contains('-----BEGIN NEW CERTIFICATE REQUEST-----')) return null;
  for (final line in all) {
    if (line.contains('UnrecoverableKeyException')) {
      return 'The key password (keyPassword) is wrong.';
    }
    if (isStorePasswordWrong(line)) {
      return 'The keystore password (storePassword) is wrong.';
    }
    final alias = _missingAlias.firstMatch(line);
    if (alias != null) {
      return 'The keystore has no key "${alias.group(1)}" (keyAlias).';
    }
    if (line.startsWith('keytool error: ')) {
      final message = line.substring('keytool error: '.length);
      final colon = message.indexOf(': ');
      return colon >= 0 ? message.substring(colon + 2) : message;
    }
  }
  return 'keytool could not open the key.';
}

final _missingAlias = RegExp(r'Alias <(.+)> does not exist');

/// Whether [line] is the JDK saying the keystore password is wrong, as
/// keytool and apksigner both print it. The words depend on the keystore's
/// type: "Keystore was tampered with, or password was incorrect" for JKS,
/// "keystore password was incorrect" for PKCS12.
bool isStorePasswordWrong(String line) =>
    line.contains('password was incorrect');
