import '../../core/format/format.dart';
import 'apk_report.dart';
import 'findings.dart';
import 'signature.dart';

/// How the signers of two APKs compare, by certificate SHA-256.
enum SignerVerdict {
  /// The same set of signer certificates: one installs as an update over
  /// the other.
  same,

  /// The compared APK's key was rotated from the reference's (APK Signature
  /// Scheme v3): Android accepts it as an update.
  rotated,

  /// Not the same signers: Android refuses one as an update over the other.
  different,

  /// One of them has no signer at all.
  unsigned,

  /// A signature couldn't be read, so the signers weren't compared.
  unknown,
}

/// One value of the reference APK next to the same value of the compared
/// one.
class ComparedField {
  const ComparedField(
    this.section,
    this.label,
    this.reference,
    this.candidate, {
    this.level = FindingLevel.info,
    this.note,
    this.blocksUpdate = false,
  });

  /// `Signature`, `Manifest`, `Contents` or `File`.
  final String section;
  final String label;

  /// `null` when that APK doesn't have it (a second signer, a launcher).
  final String? reference;
  final String? candidate;

  /// How much the difference matters. Meaningless when the values are the
  /// same.
  final FindingLevel level;

  /// Why the difference matters, for the ones that do.
  final String? note;

  /// Whether the difference stops the compared APK from installing as an
  /// update over the reference.
  final bool blocksUpdate;

  bool get differs => reference != candidate;
}

/// A part of the report that wasn't compared: the reason for each side
/// that couldn't be read, `null` for a side that could.
class NotCompared {
  const NotCompared(this.section, {this.reference, this.candidate});

  final String section;
  final String? reference;
  final String? candidate;
}

/// What differs between a reference APK (a previous release, the installed
/// app) and the APK compared with it.
class ApkComparison {
  const ApkComparison({
    required this.signer,
    required this.fields,
    required this.sameFile,
    this.referenceSigners = const [],
    this.candidateSigners = const [],
    this.permissionsAdded = const [],
    this.permissionsRemoved = const [],
    this.notCompared = const [],
  });

  final SignerVerdict signer;

  /// Each side's signer certificates, by SHA-256 (normalized). Empty when
  /// the signature couldn't be read.
  final List<String> referenceSigners;
  final List<String> candidateSigners;

  /// Every value compared, in the report's order.
  final List<ComparedField> fields;

  /// The two files have the same SHA-256. Never for an app installed as
  /// splits, which isn't one file.
  final bool sameFile;

  /// Permissions the compared APK asks for and the reference doesn't.
  final List<String> permissionsAdded;
  final List<String> permissionsRemoved;
  final List<NotCompared> notCompared;

  /// The values that differ, worst first, in the report's order otherwise.
  List<ComparedField> get differences => [
    for (final level in FindingLevel.values.reversed)
      ...fields.where((field) => field.differs && field.level == level),
  ];

  List<ComparedField> get identical =>
      fields.where((field) => !field.differs).toList();

  /// The differences that stop the compared APK from installing as an
  /// update over the reference.
  List<ComparedField> get updateBlockers =>
      fields.where((field) => field.differs && field.blocksUpdate).toList();
}

/// Compares [candidate] with [reference], as an update over it: a lower
/// versionCode, another package or another signer would be refused.
///
/// A part that either report couldn't read (a missing tool, not an APK) is
/// listed in [ApkComparison.notCompared] instead of showing as a
/// difference.
///
/// [referenceIsSplit]: the reference is an app installed as several APKs,
/// `base.apk` and its splits. Its size is theirs together, and it has no
/// hash of its own: its MD5 and SHA-256 aren't compared, and it's never the
/// same file as the candidate.
ApkComparison compareApks(
  ApkReport reference,
  ApkReport candidate, {
  bool referenceIsSplit = false,
}) {
  final fields = <ComparedField>[];
  final notCompared = <NotCompared>[];
  final verdict = signerVerdict(reference.signature, candidate.signature);

  // Signature.
  final referenceSignature = reference.signature;
  final candidateSignature = candidate.signature;
  if (referenceSignature == null || candidateSignature == null) {
    notCompared.add(
      NotCompared(
        'Signature',
        reference: referenceSignature == null
            ? reference.signatureError ?? 'Not checked.'
            : null,
        candidate: candidateSignature == null
            ? candidate.signatureError ?? 'Not checked.'
            : null,
      ),
    );
  } else {
    fields.add(
      ComparedField(
        'Signature',
        'Verifies',
        _yesNo(referenceSignature.verifies),
        _yesNo(candidateSignature.verifies),
        level: candidateSignature.verifies
            ? FindingLevel.info
            : FindingLevel.error,
        note: candidateSignature.verifies
            ? null
            : 'Android refuses to install an APK whose signature does not '
                  'verify.',
        blocksUpdate: !candidateSignature.verifies,
      ),
    );
    fields.add(
      ComparedField(
        'Signature',
        'Schemes',
        describeSchemes(
          referenceSignature.schemes,
          hasJarSignature: reference.hasJarSignature,
        ),
        describeSchemes(
          candidateSignature.schemes,
          hasJarSignature: candidate.hasJarSignature,
        ),
        note: _v4Unchecked(referenceSignature, candidateSignature),
      ),
    );
    fields.addAll(
      _signerFields(
        referenceSignature.signers,
        candidateSignature.signers,
        verdict,
      ),
    );
    if (referenceSignature.lineage.isNotEmpty ||
        candidateSignature.lineage.isNotEmpty) {
      fields.add(
        ComparedField(
          'Signature',
          'Key lineage',
          _lineage(referenceSignature.lineage),
          _lineage(candidateSignature.lineage),
        ),
      );
    }
  }

  // Manifest.
  final referenceBadging = reference.badging;
  final candidateBadging = candidate.badging;
  var added = <String>[];
  var removed = <String>[];
  if (referenceBadging == null || candidateBadging == null) {
    notCompared.add(
      NotCompared(
        'Manifest',
        reference: referenceBadging == null
            ? reference.badgingError ?? 'Not read.'
            : null,
        candidate: candidateBadging == null
            ? candidate.badgingError ?? 'Not read.'
            : null,
      ),
    );
  } else {
    final otherPackage =
        referenceBadging.packageName != candidateBadging.packageName;
    fields.add(
      ComparedField(
        'Manifest',
        'Package',
        referenceBadging.packageName,
        candidateBadging.packageName,
        level: otherPackage ? FindingLevel.error : FindingLevel.info,
        note: otherPackage
            ? 'Another package: Android installs it as a separate app, not '
                  'as an update.'
            : null,
        blocksUpdate: otherPackage,
      ),
    );
    fields.add(
      ComparedField(
        'Manifest',
        'Label',
        referenceBadging.label,
        candidateBadging.label,
      ),
    );
    fields.add(
      ComparedField(
        'Manifest',
        'Version name',
        referenceBadging.versionName,
        candidateBadging.versionName,
      ),
    );
    final referenceCode = int.tryParse(referenceBadging.versionCode ?? '');
    final candidateCode = int.tryParse(candidateBadging.versionCode ?? '');
    final downgrade =
        referenceCode != null &&
        candidateCode != null &&
        candidateCode < referenceCode;
    fields.add(
      ComparedField(
        'Manifest',
        'Version code',
        referenceBadging.versionCode,
        candidateBadging.versionCode,
        level: downgrade ? FindingLevel.error : FindingLevel.info,
        note: downgrade
            ? 'Lower: Android refuses it as an update '
                  '(INSTALL_FAILED_VERSION_DOWNGRADE) unless a downgrade is '
                  'allowed.'
            : null,
        blocksUpdate: downgrade,
      ),
    );
    final referenceMin = referenceBadging.minSdk;
    final candidateMin = candidateBadging.minSdk;
    final minRaised =
        referenceMin != null &&
        candidateMin != null &&
        candidateMin > referenceMin;
    fields.add(
      ComparedField(
        'Manifest',
        'Min SDK',
        _sdk(referenceMin),
        _sdk(candidateMin),
        level: minRaised ? FindingLevel.warning : FindingLevel.info,
        note: minRaised
            ? 'Raised: devices below API $candidateMin can no longer '
                  'install it.'
            : null,
      ),
    );
    fields.add(
      ComparedField(
        'Manifest',
        'Target SDK',
        _sdk(referenceBadging.targetSdk),
        _sdk(candidateBadging.targetSdk),
      ),
    );
    fields.add(
      ComparedField(
        'Manifest',
        'Compile SDK',
        _sdk(referenceBadging.compileSdk),
        _sdk(candidateBadging.compileSdk),
      ),
    );
    final becameDebug =
        candidateBadging.debuggable && !referenceBadging.debuggable;
    fields.add(
      ComparedField(
        'Manifest',
        'Build type',
        _buildType(referenceBadging.debuggable),
        _buildType(candidateBadging.debuggable),
        level: becameDebug ? FindingLevel.warning : FindingLevel.info,
        note: becameDebug
            ? 'A debug build (debuggable): a store or a TMS rejects it.'
            : null,
      ),
    );
    fields.add(
      ComparedField(
        'Manifest',
        'Launcher',
        referenceBadging.launchableActivity,
        candidateBadging.launchableActivity,
      ),
    );
    final referencePermissions = referenceBadging.permissions.toSet();
    final candidatePermissions = candidateBadging.permissions.toSet();
    added = candidatePermissions.difference(referencePermissions).toList()
      ..sort();
    removed = referencePermissions.difference(candidatePermissions).toList()
      ..sort();
    fields.add(
      ComparedField(
        'Manifest',
        'Permissions',
        _permissionCount(referencePermissions.length),
        [
          _permissionCount(candidatePermissions.length),
          if (added.isNotEmpty) '${added.length} added',
          if (removed.isNotEmpty) '${removed.length} removed',
        ].join(', '),
        level: added.isEmpty ? FindingLevel.info : FindingLevel.warning,
        note: added.isEmpty
            ? null
            : 'Asks for ${added.length} more '
                  'permission${added.length == 1 ? '' : 's'}.',
      ),
    );
  }

  // Contents.
  if (reference.contentsError != null || candidate.contentsError != null) {
    notCompared.add(
      NotCompared(
        'Contents',
        reference: reference.contentsError,
        candidate: candidate.contentsError,
      ),
    );
  } else {
    fields.addAll(_contentFields(reference.contents, candidate.contents));
  }

  // File.
  fields.add(
    ComparedField(
      'File',
      'Size',
      formatBytes(reference.sizeBytes),
      formatBytes(candidate.sizeBytes),
    ),
  );
  if (!referenceIsSplit) {
    fields.add(ComparedField('File', 'MD5', reference.md5, candidate.md5));
    fields.add(
      ComparedField('File', 'SHA-256', reference.sha256, candidate.sha256),
    );
  }

  return ApkComparison(
    signer: verdict,
    fields: fields,
    sameFile: !referenceIsSplit && reference.sha256 == candidate.sha256,
    referenceSigners: [
      for (final signer in referenceSignature?.signers ?? const [])
        ?signer.sha256,
    ],
    candidateSigners: [
      for (final signer in candidateSignature?.signers ?? const [])
        ?signer.sha256,
    ],
    permissionsAdded: added,
    permissionsRemoved: removed,
    notCompared: notCompared,
  );
}

/// The verdicts a comparison opens with, worst first. [reference] and
/// [candidate] name the two sides ("the installed app", "the selected APK").
List<Finding> comparisonFindings(
  ApkComparison comparison, {
  required String reference,
  required String candidate,
}) {
  final findings = <Finding>[
    switch (comparison.signer) {
      SignerVerdict.same => Finding(
        FindingLevel.ok,
        'Same signer',
        'Signed with the same certificate '
            '(SHA-256 ${_digests(comparison.candidateSigners)}): one installs '
            'as an update over the other.',
      ),
      SignerVerdict.rotated => Finding(
        FindingLevel.warning,
        'Key rotated',
        'Signed with a newer key, rotated from the one $reference is signed '
            'with (APK Signature Scheme v3). Android still accepts it as an '
            'update.',
      ),
      SignerVerdict.different => Finding(
        FindingLevel.error,
        'Different signer',
        'Android refuses one as an update over the other '
            '(INSTALL_FAILED_UPDATE_INCOMPATIBLE).\n'
            '${_capitalized(reference)}: '
            'SHA-256 ${_digests(comparison.referenceSigners)}\n'
            '${_capitalized(candidate)}: '
            'SHA-256 ${_digests(comparison.candidateSigners)}',
      ),
      SignerVerdict.unsigned => const Finding(
        FindingLevel.error,
        'Not signed',
        'One of them has no signer: Android refuses to install it.',
      ),
      SignerVerdict.unknown => const Finding(
        FindingLevel.warning,
        'Signers not compared',
        'A signature could not be read.',
      ),
    },
  ];

  final blockers = comparison.updateBlockers;
  if (blockers.isNotEmpty) {
    findings.add(
      Finding(
        FindingLevel.error,
        'Won\'t install as an update over $reference',
        [
          for (final field in blockers)
            '${field.label}: ${field.note ?? 'differs.'}',
        ].join('\n'),
      ),
    );
  } else if ((comparison.signer == SignerVerdict.same ||
          comparison.signer == SignerVerdict.rotated) &&
      comparison.notCompared.isEmpty) {
    findings.add(
      Finding(FindingLevel.ok, 'Installs as an update over $reference'),
    );
  }

  if (comparison.sameFile) {
    findings.add(
      const Finding(
        FindingLevel.info,
        'The same file',
        'Both have the same SHA-256.',
      ),
    );
  }

  for (final part in comparison.notCompared) {
    findings.add(
      Finding(
        FindingLevel.warning,
        '${part.section} not compared',
        [
          if (part.reference != null)
            '${_capitalized(reference)}: ${part.reference}',
          if (part.candidate != null)
            '${_capitalized(candidate)}: ${part.candidate}',
        ].join('\n'),
      ),
    );
  }

  return [
    for (final level in FindingLevel.values.reversed)
      ...findings.where((finding) => finding.level == level),
  ];
}

/// `AB:CD:EF:01…23:45:67:89`, or several joined.
String _digests(List<String> digests) =>
    digests.isEmpty ? '?' : digests.map(shortDigest).join(', ');

String _capitalized(String text) =>
    text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);

/// The Install panel's warning for an APK signed with another key than the
/// app installed from it: `null` when it would install as an update (the
/// same signer, or a key rotated from the installed one), or when the two
/// signers can't be compared.
String? installSignerWarning(SignatureReport? installed, SignatureReport? apk) {
  if (signerVerdict(installed, apk) != SignerVerdict.different) return null;
  return 'Signed with another key than the installed app '
      '(${_digests(_signerDigests(installed!).toList())}; this APK: '
      '${_digests(_signerDigests(apk!).toList())}). Android will refuse the '
      'update (INSTALL_FAILED_UPDATE_INCOMPATIBLE); installing it would need '
      'the app uninstalled first, which deletes its data.';
}

/// Whether two signatures have the same signers. Android's rule for an
/// update: the same set of certificates, whatever their order.
SignerVerdict signerVerdict(
  SignatureReport? reference,
  SignatureReport? candidate,
) {
  if (reference == null || candidate == null) return SignerVerdict.unknown;
  final referenceDigests = _signerDigests(reference);
  final candidateDigests = _signerDigests(candidate);
  if (referenceDigests.isEmpty || candidateDigests.isEmpty) {
    return SignerVerdict.unsigned;
  }
  if (referenceDigests.length == candidateDigests.length &&
      referenceDigests.containsAll(candidateDigests)) {
    return SignerVerdict.same;
  }
  // A rotation keeps the older keys: in the v3 lineage, or as the signers
  // of the older API levels in a v3.1 signature. Several v1/v2 signers are
  // not a rotation: Android wants the same set.
  final rotatedFrom = {
    for (final signer in candidate.lineage) ?signer.sha256,
    for (final signer in candidate.signers)
      if (signer.apiRange != null) ?signer.sha256,
  };
  return rotatedFrom.containsAll(referenceDigests)
      ? SignerVerdict.rotated
      : SignerVerdict.different;
}

Set<String> _signerDigests(SignatureReport signature) => {
  for (final signer in signature.signers) ?signer.sha256,
};

/// The signers of both sides in pairs: the same certificate side by side
/// first, then the others in order, so a v3.1 signature lines up with an
/// older one by key rather than by position.
List<(SignerCertificate?, SignerCertificate?)> _pairSigners(
  List<SignerCertificate> reference,
  List<SignerCertificate> candidate,
) {
  final unmatched = [...candidate];
  final pairs = <(SignerCertificate?, SignerCertificate?)>[];
  final left = <SignerCertificate>[];
  for (final a in reference) {
    final i = unmatched.indexWhere(
      (b) => b.sha256 != null && b.sha256 == a.sha256,
    );
    if (i < 0) {
      left.add(a);
    } else {
      pairs.add((a, unmatched.removeAt(i)));
    }
  }
  final rest = left.length > unmatched.length ? left.length : unmatched.length;
  for (var i = 0; i < rest; i++) {
    pairs.add((
      i < left.length ? left[i] : null,
      i < unmatched.length ? unmatched[i] : null,
    ));
  }
  return pairs;
}

/// One row per certificate value, signer by signer. Only the SHA-256 is
/// what Android compares; a DN or a key size can match on another key.
List<ComparedField> _signerFields(
  List<SignerCertificate> reference,
  List<SignerCertificate> candidate,
  SignerVerdict verdict,
) {
  final pairs = _pairSigners(reference, candidate);
  final otherKey = verdict == SignerVerdict.different;
  final rotated = verdict == SignerVerdict.rotated;
  final fields = <ComparedField>[];
  for (final (i, (a, b)) in pairs.indexed) {
    final range = b?.apiRange ?? a?.apiRange;
    final name = range != null
        ? 'Signer ($range)'
        : pairs.length == 1
        ? 'Signer'
        : 'Signer ${i + 1}';
    fields.addAll([
      ComparedField(
        'Signature',
        name,
        a?.distinguishedName,
        b?.distinguishedName,
      ),
      ComparedField(
        'Signature',
        '$name SHA-256',
        _digest(a?.sha256),
        _digest(b?.sha256),
        level: otherKey
            ? FindingLevel.error
            : rotated
            ? FindingLevel.warning
            : FindingLevel.info,
        note: otherKey
            ? 'Signed with another key: Android refuses it as an update '
                  '(INSTALL_FAILED_UPDATE_INCOMPATIBLE).'
            : rotated
            ? 'Key rotated from the reference\'s: Android still accepts it '
                  'as an update.'
            : null,
        blocksUpdate: otherKey,
      ),
      ComparedField(
        'Signature',
        '$name SHA-1',
        _digest(a?.sha1),
        _digest(b?.sha1),
      ),
      ComparedField('Signature', '$name key', _key(a), _key(b)),
    ]);
  }
  return fields;
}

List<ComparedField> _contentFields(
  ApkContents reference,
  ApkContents candidate,
) {
  final referenceAbis = reference.nativeLibraries.keys.toList();
  final candidateAbis = candidate.nativeLibraries.keys.toList();
  // No native code at all runs anywhere; only a narrower set loses devices.
  final lost = candidateAbis.isEmpty
      ? const <String>[]
      : referenceAbis.where((abi) => !candidateAbis.contains(abi)).toList();
  final referenceNoEngine = reference.abisWithoutFlutterEngine;
  final candidateNoEngine = candidate.abisWithoutFlutterEngine;
  final newNoEngine = candidateNoEngine
      .where((abi) => !referenceNoEngine.contains(abi))
      .toList();
  final becameJit =
      candidate.flutter == FlutterCompilation.jit &&
      reference.flutter == FlutterCompilation.aot;

  return [
    ComparedField(
      'Contents',
      'ABIs',
      _abis(referenceAbis),
      _abis(candidateAbis),
      level: lost.isEmpty ? FindingLevel.info : FindingLevel.warning,
      note: lost.isEmpty
          ? null
          : 'No longer has ${lost.join(', ')}: devices that need '
                '${lost.length == 1 ? 'it' : 'them'} can\'t install it.',
    ),
    if (reference.isFlutterApp || candidate.isFlutterApp) ...[
      ComparedField(
        'Contents',
        'Flutter build',
        _flutter(reference.flutter),
        _flutter(candidate.flutter),
        level: becameJit ? FindingLevel.warning : FindingLevel.info,
        note: becameJit
            ? 'A debug (JIT) Flutter build: slow, and not for '
                  'release.'
            : null,
      ),
      ComparedField(
        'Contents',
        'ABIs without the Flutter engine',
        _none(referenceNoEngine),
        _none(candidateNoEngine),
        level: newNoEngine.isEmpty ? FindingLevel.info : FindingLevel.error,
        note: newNoEngine.isEmpty
            ? null
            : 'A device that picks ${newNoEngine.join(' or ')} installs it '
                  'and crashes at launch.',
      ),
    ],
    ComparedField(
      'Contents',
      'Files in the APK',
      '${reference.entryCount}',
      '${candidate.entryCount}',
    ),
  ];
}

String _yesNo(bool value) => value ? 'Yes' : 'No';

String? _digest(String? digest) => digest == null ? null : colonDigest(digest);

/// `CN=Old → CN=New`, oldest first.
String _lineage(List<SignerCertificate> lineage) => lineage.isEmpty
    ? 'None'
    : lineage
          .map(
            (signer) =>
                signer.distinguishedName ??
                (signer.sha256 == null ? '?' : shortDigest(signer.sha256!)),
          )
          .join(' → ');

String? _key(SignerCertificate? signer) {
  final algorithm = signer?.keyAlgorithm;
  if (algorithm == null) return null;
  final size = signer!.keySize;
  return size == null ? algorithm : '$algorithm $size bits';
}

String? _sdk(int? level) => level == null ? null : 'API $level';

String _buildType(bool debuggable) => debuggable ? 'Debug' : 'Release';

/// A count, so the row stays short; the names are in
/// [ApkComparison.permissionsAdded] and [ApkComparison.permissionsRemoved].
String _permissionCount(int count) => switch (count) {
  0 => 'None',
  1 => '1 permission',
  _ => '$count permissions',
};

String _abis(List<String> abis) =>
    abis.isEmpty ? 'None (runs on any ABI)' : abis.join(', ');

String _flutter(FlutterCompilation? compilation) => switch (compilation) {
  FlutterCompilation.aot => 'AOT (release or profile)',
  FlutterCompilation.jit => 'JIT (debug)',
  null => 'Not a Flutter app',
};

String _none(List<String> values) =>
    values.isEmpty ? 'None' : values.join(', ');

/// Why two APKs may differ in v4 only on paper: it's checked only with the
/// `.idsig` next to an APK, and the one without it had none.
String? _v4Unchecked(SignatureReport reference, SignatureReport candidate) {
  if (reference.scheme('v4') == candidate.scheme('v4')) return null;
  final other = reference.scheme('v4') ? candidate : reference;
  if (other.v4SignatureFile != null) return null;
  return 'v4 is checked only with an APK\'s .idsig, and one of them had '
      'none next to it.';
}
