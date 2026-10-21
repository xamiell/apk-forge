import '../../core/format/format.dart';
import '../analysis/signature.dart';
import 'keystore.dart';
import 'signing.dart';

/// `jarsigner` arguments that sign [input], an App Bundle without a JAR
/// signature, into [output] with [request]'s key. The passwords are read
/// from the environment, as apksigner's are, and jarsigner reads the
/// keystore's type itself.
///
/// A bundle carries a JAR signature only: [request]'s schemes don't apply.
/// The store signs the APKs it makes from it.
List<String> jarsignerSignArguments(
  SigningRequest request, {
  required String input,
  required String output,
}) => [
  // English messages, whatever the system language: the parsers read them.
  '-J-Duser.language=en',
  '-J-Duser.country=US',
  '-keystore',
  request.keystorePath,
  '-storepass:env',
  keystorePasswordVariable,
  if (request.keyPassword != null) ...['-keypass:env', keyPasswordVariable],
  '-signedjar',
  output,
  input,
  request.alias,
];

/// `jarsigner` arguments that check [jar]'s signature.
List<String> jarsignerVerifyArguments(String jar) => [
  '-J-Duser.language=en',
  '-J-Duser.country=US',
  '-verify',
  jar,
];

/// `keytool` arguments that print the certificates of [jar]'s signers, with
/// their SHA-256: `jarsigner -verify` names no fingerprint.
List<String> keytoolPrintJarCertificatesArguments(String jar) => [
  '-J-Duser.language=en',
  '-J-Duser.country=US',
  '-printcert',
  '-jarfile',
  jar,
];

/// What `jarsigner -verify` said of a JAR or App Bundle.
enum JarVerdict { verified, unsigned, invalid }

class JarVerification {
  const JarVerification(this.verdict, {this.reason});

  final JarVerdict verdict;

  /// Why it's [JarVerdict.invalid], in jarsigner's words.
  final String? reason;
}

final _jarsignerError = RegExp(
  r'^jarsigner(?: error)?: (?:[\w.$]+(?:Exception|Error): )?(.+)$',
);

/// Reads `jarsigner -verify`: `jar verified.`, `jar is unsigned.`, or an
/// error such as a signature that no longer matches the files.
JarVerification parseJarsignerVerify(Iterable<String> lines) {
  final all = [
    for (final line in lines)
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (all.contains('jar verified.')) {
    return const JarVerification(JarVerdict.verified);
  }
  if (all.contains('jar is unsigned.')) {
    return const JarVerification(JarVerdict.unsigned);
  }
  for (final line in all) {
    if (_jarsignerError.firstMatch(line) case final match?) {
      return JarVerification(JarVerdict.invalid, reason: match.group(1));
    }
  }
  return JarVerification(
    JarVerdict.invalid,
    reason: all.isEmpty ? null : all.last,
  );
}

/// One signer of a JAR or App Bundle, by its first certificate.
class JarSigner {
  const JarSigner({this.owner, this.sha256, this.sha1, this.keyAlgorithm});

  final String? owner;

  /// Normalized with [normalizeDigest], ready to compare with keytool's.
  final String? sha256;
  final String? sha1;

  /// As keytool says it: `2048-bit RSA key`.
  final String? keyAlgorithm;
}

/// The signers `keytool -printcert -jarfile` lists. An unsigned file has
/// none (`Not a signed jar file`).
List<JarSigner> parseJarSigners(Iterable<String> lines) {
  final signers = <JarSigner>[];
  var inSigner = false;
  var inFirstCertificate = false;
  String? owner;
  String? sha256;
  String? sha1;
  String? keyAlgorithm;

  void flush() {
    if (inSigner) {
      signers.add(
        JarSigner(
          owner: owner,
          sha256: sha256,
          sha1: sha1,
          keyAlgorithm: keyAlgorithm,
        ),
      );
    }
    owner = sha256 = sha1 = keyAlgorithm = null;
  }

  for (final raw in lines) {
    final line = raw.trim();
    if (line.startsWith('Signer #')) {
      flush();
      inSigner = true;
    } else if (line.startsWith('Certificate #')) {
      // A chain lists several certificates; the signer is the first one.
      inFirstCertificate = line.startsWith('Certificate #1:');
    } else if (inFirstCertificate &&
        owner == null &&
        line.startsWith('Owner: ')) {
      owner = line.substring('Owner: '.length);
    } else if (inFirstCertificate &&
        sha256 == null &&
        line.startsWith('SHA256: ')) {
      sha256 = normalizeDigest(line.substring('SHA256: '.length));
    } else if (inFirstCertificate &&
        sha1 == null &&
        line.startsWith('SHA1: ')) {
      sha1 = normalizeDigest(line.substring('SHA1: '.length));
    } else if (inFirstCertificate &&
        keyAlgorithm == null &&
        line.startsWith(_keyAlgorithm)) {
      keyAlgorithm = line.substring(_keyAlgorithm.length);
    }
  }
  flush();
  return signers;
}

const _keyAlgorithm = 'Subject Public Key Algorithm: ';
final _keySize = RegExp(r'^(\d+)-bit (\S+)');

/// A bundle's JAR signature, as Analyze shows an APK's: `v1` is the JAR
/// signature, and the other schemes don't apply to a bundle.
SignatureReport bundleSignatureReport(
  JarVerification verification,
  List<JarSigner> signers,
) {
  final verified = verification.verdict == JarVerdict.verified;
  return SignatureReport(
    verifies: verified,
    schemes: {'v1': verified},
    signers: [
      for (final (index, signer) in signers.indexed)
        SignerCertificate(
          label: 'Signer #${index + 1}',
          distinguishedName: signer.owner,
          sha256: signer.sha256,
          sha1: signer.sha1,
          keyAlgorithm: _keySize
              .firstMatch(signer.keyAlgorithm ?? '')
              ?.group(2),
          keySize: int.tryParse(
            _keySize.firstMatch(signer.keyAlgorithm ?? '')?.group(1) ?? '',
          ),
        ),
    ],
    errors: [
      if (verification.verdict == JarVerdict.unsigned)
        'The bundle is not signed.',
      ?verification.reason,
    ],
  );
}
