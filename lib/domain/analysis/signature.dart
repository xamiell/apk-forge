import '../../core/format/format.dart';

class SignerCertificate {
  const SignerCertificate({
    required this.label,
    this.distinguishedName,
    this.sha256,
    this.sha1,
    this.keyAlgorithm,
    this.keySize,
  });

  /// `Signer #1`, or `Signer (minSdkVersion=33, …)` for a v3.1 rotation.
  final String label;
  final String? distinguishedName;

  /// Normalized with [normalizeDigest].
  final String? sha256;
  final String? sha1;
  final String? keyAlgorithm;
  final int? keySize;

  /// Android Studio's debug key (`CN=Android Debug, O=Android, C=US`, in any
  /// order: apksigner prints it reversed).
  bool get isAndroidDebugKey =>
      distinguishedName
          ?.split(',')
          .map((part) => part.trim())
          .contains('CN=Android Debug') ??
      false;
}

/// What `apksigner verify --verbose --print-certs` reports.
class SignatureReport {
  const SignatureReport({
    required this.verifies,
    this.schemes = const {},
    this.signers = const [],
    this.errors = const [],
    this.warnings = const [],
  });

  final bool verifies;

  /// `v1`, `v2`, `v3`, `v3.1`, `v4` → whether apksigner verified it.
  ///
  /// apksigner only checks the schemes the APK's minSdk range needs: an APK
  /// with minSdk 24+ reports `v1: false` even when it carries a v1
  /// signature, since Android 7+ ignores it. See [ApkReport.hasJarSignature].
  final Map<String, bool> schemes;
  final List<SignerCertificate> signers;
  final List<String> errors;
  final List<String> warnings;

  bool scheme(String name) => schemes[name] ?? false;
}

final _schemeLine = RegExp(
  r'^Verified using (v[\d.]+) scheme \([^)]*\): (true|false)',
);
final _signerLine = RegExp(r'^(Signer (?:#\d+|\([^)]*\))) (.+?): (.*)$');

SignatureReport parseApksignerVerify(Iterable<String> lines) {
  var verifies = false;
  var sawVerdict = false;
  final schemes = <String, bool>{};
  final signers = <String, Map<String, String>>{};
  final errors = <String>[];
  final warnings = <String>[];

  for (final raw in lines) {
    final line = raw.trim();
    if (line == 'Verifies') {
      verifies = true;
      sawVerdict = true;
      continue;
    }
    if (line == 'DOES NOT VERIFY') {
      verifies = false;
      sawVerdict = true;
      continue;
    }
    final scheme = _schemeLine.firstMatch(line);
    if (scheme != null) {
      schemes[scheme.group(1)!] = scheme.group(2) == 'true';
      continue;
    }
    final signer = _signerLine.firstMatch(line);
    if (signer != null) {
      signers.putIfAbsent(signer.group(1)!, () => {})[signer.group(2)!] = signer
          .group(3)!;
      continue;
    }
    if (line.startsWith('ERROR: ')) {
      errors.add(line.substring(7));
    } else if (line.startsWith('WARNING: ')) {
      warnings.add(line.substring(9));
    } else if (!sawVerdict && line.contains('Exception')) {
      // A crash instead of a verdict: "…ApkFormatException: Malformed APK:
      // not a ZIP archive". Keep the message, drop the class name.
      final colon = line.indexOf(': ');
      errors.add(colon >= 0 ? line.substring(colon + 2) : line);
    }
  }

  return SignatureReport(
    verifies: verifies,
    schemes: schemes,
    signers: [
      for (final MapEntry(key: label, value: fields) in signers.entries)
        SignerCertificate(
          label: label,
          distinguishedName: fields['certificate DN'],
          sha256: _digest(fields['certificate SHA-256 digest']),
          sha1: _digest(fields['certificate SHA-1 digest']),
          keyAlgorithm: fields['key algorithm'],
          keySize: int.tryParse(fields['key size (bits)'] ?? ''),
        ),
    ],
    errors: errors,
    warnings: warnings,
  );
}

String? _digest(String? value) => value == null ? null : normalizeDigest(value);
