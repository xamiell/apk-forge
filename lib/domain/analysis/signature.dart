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

  /// `API 33+` or `API 24–32` for a v3.1 signer, which signs only for those
  /// API levels; `null` for one that signs for all (`Signer #1`).
  String? get apiRange {
    final match = _apiRangeLabel.firstMatch(label);
    if (match == null) return null;
    final min = match.group(1)!;
    final max = int.parse(match.group(2)!);
    return max >= 0x7fffffff ? 'API $min+' : 'API $min–$max';
  }

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
    this.lineage = const [],
    this.errors = const [],
    this.warnings = const [],
  });

  /// This report with the certificates of its v3 key rotation, from
  /// `apksigner lineage`, which `verify` doesn't print.
  SignatureReport withLineage(List<SignerCertificate> lineage) =>
      SignatureReport(
        verifies: verifies,
        schemes: schemes,
        signers: signers,
        lineage: lineage,
        errors: errors,
        warnings: warnings,
      );

  final bool verifies;

  /// `v1`, `v2`, `v3`, `v3.1`, `v4` → whether apksigner verified it.
  ///
  /// apksigner only checks the schemes the APK's minSdk range needs: an APK
  /// with minSdk 24+ reports `v1: false` even when it carries a v1
  /// signature, since Android 7+ ignores it. See [ApkReport.hasJarSignature].
  final Map<String, bool> schemes;

  /// The certificates `verify` lists. A v3.1 rotation lists one per API
  /// range (`Signer (minSdkVersion=33, …)`), newest key first.
  final List<SignerCertificate> signers;

  /// A v3 key rotation, oldest certificate first: the keys the current one
  /// was rotated from. Empty when the key never rotated.
  final List<SignerCertificate> lineage;
  final List<String> errors;
  final List<String> warnings;

  bool scheme(String name) => schemes[name] ?? false;
}

final _apiRangeLabel = RegExp(r'minSdkVersion=(\d+), maxSdkVersion=(\d+)');

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

final _lineageLine = RegExp(
  r'^Signer #(\d+) in lineage certificate (.+?): (.*)$',
);

/// What `apksigner lineage --in <apk> --print-certs` lists: the key
/// rotation, oldest certificate first. Empty for an APK without one ("does
/// not contain a valid lineage").
List<SignerCertificate> parseApksignerLineage(Iterable<String> lines) {
  final signers = <int, Map<String, String>>{};
  for (final raw in lines) {
    final match = _lineageLine.firstMatch(raw.trim());
    if (match == null) continue;
    final number = int.parse(match.group(1)!);
    signers.putIfAbsent(number, () => {})[match.group(2)!] = match.group(3)!;
  }
  final oldestFirst = signers.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return [
    for (final MapEntry(key: number, value: fields) in oldestFirst)
      SignerCertificate(
        label: 'Signer #$number in lineage',
        distinguishedName: fields['DN'],
        sha256: _digest(fields['SHA-256 digest']),
        sha1: _digest(fields['SHA-1 digest']),
      ),
  ];
}

String? _digest(String? value) => value == null ? null : normalizeDigest(value);
