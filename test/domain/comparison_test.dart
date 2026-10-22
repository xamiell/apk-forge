import 'package:apk_forge/core/zip/zip_directory.dart';
import 'package:apk_forge/domain/analysis/apk_report.dart';
import 'package:apk_forge/domain/analysis/badging.dart';
import 'package:apk_forge/domain/analysis/comparison.dart';
import 'package:apk_forge/domain/analysis/findings.dart';
import 'package:apk_forge/domain/analysis/signature.dart';
import 'package:apk_forge/domain/devices/installed_apk.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fakes.dart';

ApkContents _contents(List<String> names) => ApkContents.fromEntries([
  for (final name in names)
    ZipEntry(
      name: name,
      compressedSize: 1,
      uncompressedSize: 1,
      isCompressed: false,
    ),
]);

final _flutterArm64 = _contents([
  'lib/arm64-v8a/libapp.so',
  'lib/arm64-v8a/libflutter.so',
  'classes.dex',
]);

final _release = parseBadging(fixture('aapt2_badging_release.txt'));
final _debug = parseBadging(fixture('aapt2_badging_debug.txt'));
final _testKey = parseApksignerVerify(fixture('apksigner_verify_test_key.txt'));
final _debugKey = parseApksignerVerify(
  fixture('apksigner_verify_debug_key.txt'),
);

ApkReport _report({
  String sha256 = 'aaaa',
  int size = 14800000,
  ApkContents? contents,
  String? contentsError,
  Badging? badging,
  String? badgingError,
  SignatureReport? signature,
  String? signatureError,
}) => ApkReport(
  path: '/apks/app.apk',
  sizeBytes: size,
  md5: 'md5-$sha256',
  sha256: sha256,
  contents: contents ?? _flutterArm64,
  contentsError: contentsError,
  badging: badging,
  badgingError: badgingError,
  signature: signature,
  signatureError: signatureError,
);

SignerCertificate _signer(String sha256) => SignerCertificate(
  label: 'Signer',
  distinguishedName: 'CN=$sha256',
  sha256: sha256,
);

ComparedField _field(ApkComparison comparison, String label) =>
    comparison.fields.singleWhere((field) => field.label == label);

void main() {
  group('compareApks', () {
    test('the same APK: the same signer, and nothing differs', () {
      final apk = _report(badging: _release, signature: _testKey);

      final comparison = compareApks(apk, apk);

      expect(comparison.signer, SignerVerdict.same);
      expect(comparison.sameFile, isTrue);
      expect(comparison.differences, isEmpty);
      expect(comparison.updateBlockers, isEmpty);
      expect(comparison.identical, hasLength(comparison.fields.length));
      expect(comparison.notCompared, isEmpty);
    });

    test('a debug build over the release: another key, a lower versionCode, '
        'a new permission', () {
      final comparison = compareApks(
        _report(badging: _release, signature: _testKey),
        _report(sha256: 'bbbb', badging: _debug, signature: _debugKey),
      );

      expect(comparison.signer, SignerVerdict.different);
      expect(comparison.sameFile, isFalse);
      expect(comparison.updateBlockers.map((f) => f.label), [
        'Signer SHA-256',
        'Version code',
      ]);

      final versionCode = _field(comparison, 'Version code');
      expect(versionCode.reference, '2001');
      expect(versionCode.candidate, '1');
      expect(versionCode.note, contains('INSTALL_FAILED_VERSION_DOWNGRADE'));

      final signer = _field(comparison, 'Signer SHA-256');
      expect(signer.reference, startsWith('B3:4C:94:45'));
      expect(signer.candidate, startsWith('D9:74:F2:84'));
      expect(signer.note, contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE'));
      expect(_field(comparison, 'Signer').candidate, contains('Android Debug'));

      expect(comparison.permissionsAdded, ['android.permission.INTERNET']);
      expect(comparison.permissionsRemoved, isEmpty);
      final permissions = _field(comparison, 'Permissions');
      expect(permissions.reference, '1 permission');
      expect(permissions.candidate, '2 permissions, 1 added');
      expect(permissions.level, FindingLevel.warning);

      final buildType = _field(comparison, 'Build type');
      expect([buildType.reference, buildType.candidate], ['Release', 'Debug']);
      expect(buildType.level, FindingLevel.warning);

      // The debug key only signs with v2; the test key with v2 and v3.
      expect(_field(comparison, 'Schemes').candidate, 'v2');

      // Errors first, then warnings, then the rest.
      final levels = comparison.differences.map((f) => f.level).toList();
      expect(levels.first, FindingLevel.error);
      expect(levels.last, FindingLevel.info);
      expect(
        comparison.differences.map((f) => f.label),
        isNot(contains('Package')),
      );
    });

    test('v4 that only one APK could check is noted, not called '
        'missing', () {
      final checked = parseApksignerVerify(
        fixture('apksigner_verify_all_schemes.txt'),
      ).withV4SignatureFile('/apks/app.apk.idsig');
      final unchecked = parseApksignerVerify(
        fixture('apksigner_verify_v4_idsig_mismatch.txt'),
      );

      final schemes = _field(
        compareApks(
          _report(badging: _release, signature: checked),
          _report(badging: _release, signature: unchecked),
        ),
        'Schemes',
      );

      expect([schemes.reference, schemes.candidate], ['v2, v3, v4', 'v2, v3']);
      expect(schemes.note, contains('.idsig'));
      expect(schemes.level, FindingLevel.info);

      // One that was checked and failed is a real difference: no note.
      final failed = _field(
        compareApks(
          _report(badging: _release, signature: checked),
          _report(
            badging: _release,
            signature: unchecked.withV4SignatureFile('/apks/app.apk.idsig'),
          ),
        ),
        'Schemes',
      );
      expect(failed.note, isNull);
    });

    test('a higher versionCode with the same key is a normal update', () {
      final comparison = compareApks(
        _report(badging: _debug, signature: _testKey),
        _report(sha256: 'bbbb', badging: _release, signature: _testKey),
      );

      expect(comparison.signer, SignerVerdict.same);
      expect(comparison.updateBlockers, isEmpty);
      expect(_field(comparison, 'Version code').level, FindingLevel.info);
      expect(comparison.permissionsRemoved, ['android.permission.INTERNET']);
      expect(_field(comparison, 'Permissions').level, FindingLevel.info);
    });

    test('another package can never be an update', () {
      final comparison = compareApks(
        _report(badging: _release, signature: _testKey),
        _report(
          sha256: 'bbbb',
          badging: const Badging(
            packageName: 'com.other.app',
            versionCode: '2001',
          ),
          signature: _testKey,
        ),
      );

      final package = _field(comparison, 'Package');
      expect(package.candidate, 'com.other.app');
      expect(package.level, FindingLevel.error);
      expect(comparison.updateBlockers.map((f) => f.label), ['Package']);
    });

    test('as many permissions, but not the same ones, still differ', () {
      Badging asking(List<String> permissions) => Badging(
        packageName: 'io.example.app',
        versionCode: '1',
        permissions: permissions,
      );

      final comparison = compareApks(
        _report(badging: asking(['android.permission.CAMERA', 'b.READ'])),
        _report(badging: asking(['b.READ', 'android.permission.INTERNET'])),
      );

      final permissions = _field(comparison, 'Permissions');
      expect(permissions.reference, '2 permissions');
      expect(permissions.candidate, '2 permissions, 1 added, 1 removed');
      expect(permissions.differs, isTrue);
      expect(comparison.permissionsAdded, ['android.permission.INTERNET']);
      expect(comparison.permissionsRemoved, ['android.permission.CAMERA']);
    });

    test('several signers match only as a whole, in any order', () {
      SignatureReport signedBy(List<String> digests) => SignatureReport(
        verifies: true,
        signers: [for (final digest in digests) _signer(digest)],
      );

      expect(
        signerVerdict(signedBy(['aa', 'bb']), signedBy(['bb', 'aa'])),
        SignerVerdict.same,
      );
      expect(
        signerVerdict(signedBy(['aa', 'bb']), signedBy(['aa'])),
        SignerVerdict.different,
      );
      // An extra v1/v2 signer is not a rotation.
      expect(
        signerVerdict(signedBy(['aa']), signedBy(['aa', 'bb'])),
        SignerVerdict.different,
      );

      final comparison = compareApks(
        _report(badging: _release, signature: signedBy(['aa', 'bb'])),
        _report(badging: _release, signature: signedBy(['aa'])),
      );
      // The second signer is missing on one side: a row with nothing there.
      expect(_field(comparison, 'Signer 2 SHA-256').candidate, isNull);
      expect(_field(comparison, 'Signer 1 SHA-256').differs, isFalse);
    });

    group('a rotated key', () {
      final oldKey = parseApksignerVerify(
        fixture('apksigner_verify_old_key.txt'),
      );
      final lineage = parseApksignerLineage(
        fixture('apksigner_lineage_rotated.txt'),
      );
      final rotatedV3 = parseApksignerVerify(
        fixture('apksigner_verify_rotated_v3.txt'),
      ).withLineage(lineage);
      final rotatedV31 = parseApksignerVerify(
        fixture('apksigner_verify_rotated_v31.txt'),
      ).withLineage(lineage);

      test('v3: flagged, and still an update', () {
        final comparison = compareApks(
          _report(badging: _release, signature: oldKey),
          _report(sha256: 'bbbb', badging: _release, signature: rotatedV3),
        );

        expect(comparison.signer, SignerVerdict.rotated);
        expect(comparison.updateBlockers, isEmpty);
        final signer = _field(comparison, 'Signer SHA-256');
        expect(signer.differs, isTrue);
        expect(signer.level, FindingLevel.warning);
        expect(signer.note, contains('still accepts it as an update'));
        final keys = _field(comparison, 'Key lineage');
        expect(keys.reference, 'None');
        expect(
          keys.candidate,
          'CN=APK Forge Old Key, O=Example, C=US → '
          'CN=APK Forge New Key, O=Example, C=US',
        );

        final titles = comparisonFindings(
          comparison,
          reference: 'the installed app',
          candidate: 'the selected APK',
        ).map((f) => f.title);
        expect(titles, [
          'Key rotated',
          'Installs as an update over the installed app',
        ]);
      });

      test('v3 without its lineage would look like another key', () {
        final verifyOnly = parseApksignerVerify(
          fixture('apksigner_verify_rotated_v3.txt'),
        );

        expect(signerVerdict(oldKey, verifyOnly), SignerVerdict.different);
      });

      test('v3.1: the old key lines up with the old key', () {
        final comparison = compareApks(
          _report(badging: _release, signature: oldKey),
          _report(sha256: 'bbbb', badging: _release, signature: rotatedV31),
        );

        expect(comparison.signer, SignerVerdict.rotated);
        expect(
          signerVerdict(
            oldKey,
            parseApksignerVerify(fixture('apksigner_verify_rotated_v31.txt')),
          ),
          SignerVerdict.rotated,
        );
        final older = _field(comparison, 'Signer (API 24–32) SHA-256');
        expect(older.differs, isFalse);
        final newer = _field(comparison, 'Signer (API 33+) SHA-256');
        expect(newer.reference, isNull);
        expect(newer.candidate, startsWith('AA:D1:7C:F9'));
        expect(newer.level, FindingLevel.warning);
        expect(comparison.updateBlockers, isEmpty);
      });

      test('going back to the older key is not an update', () {
        final comparison = compareApks(
          _report(badging: _release, signature: rotatedV3),
          _report(sha256: 'bbbb', badging: _release, signature: oldKey),
        );

        expect(comparison.signer, SignerVerdict.different);
        expect(comparison.updateBlockers.map((f) => f.label), [
          'Signer SHA-256',
        ]);
      });
    });

    test('an unsigned APK: its signature does not verify', () {
      final unsigned = parseApksignerVerify(
        fixture('apksigner_verify_unsigned.txt'),
      );

      final comparison = compareApks(
        _report(badging: _release, signature: _testKey),
        _report(sha256: 'bbbb', badging: _release, signature: unsigned),
      );

      expect(comparison.signer, SignerVerdict.unsigned);
      final verifies = _field(comparison, 'Verifies');
      expect([verifies.reference, verifies.candidate], ['Yes', 'No']);
      expect(verifies.blocksUpdate, isTrue);
      expect(verifies.level, FindingLevel.error);
    });

    test('a raised minSdk loses devices; a lowered one does not', () {
      Badging badging(int minSdk) => Badging(
        packageName: 'io.example.app',
        versionCode: '1',
        minSdk: minSdk,
      );
      ApkComparison minSdk(int from, int to) => compareApks(
        _report(badging: badging(from)),
        _report(badging: badging(to)),
      );

      final raised = _field(minSdk(24, 26), 'Min SDK');
      expect(raised.level, FindingLevel.warning);
      expect(raised.note, contains('below API 26'));
      expect(_field(minSdk(26, 24), 'Min SDK').level, FindingLevel.info);
    });

    test('a lost ABI and an ABI without the engine', () {
      final comparison = compareApks(
        _report(
          contents: _contents([
            'lib/arm64-v8a/libapp.so',
            'lib/arm64-v8a/libflutter.so',
            'lib/armeabi-v7a/libapp.so',
            'lib/armeabi-v7a/libflutter.so',
          ]),
        ),
        _report(
          contents: _contents([
            'lib/arm64-v8a/libapp.so',
            'lib/arm64-v8a/libflutter.so',
            'lib/x86/libsqlite3.so',
          ]),
        ),
      );

      final abis = _field(comparison, 'ABIs');
      expect(abis.reference, 'arm64-v8a, armeabi-v7a');
      expect(abis.candidate, 'arm64-v8a, x86');
      expect(abis.level, FindingLevel.warning);
      expect(abis.note, contains('armeabi-v7a'));

      final engine = _field(comparison, 'ABIs without the Flutter engine');
      expect(engine.candidate, 'x86');
      expect(engine.level, FindingLevel.error);
    });

    test('an app installed as splits compares as a whole', () {
      List<ZipEntry> entries(List<String> names) => [
        for (final name in names)
          ZipEntry(
            name: name,
            compressedSize: 1,
            uncompressedSize: 1,
            isCompressed: false,
          ),
      ];
      // base.apk has no native code; its ABI split has it.
      final installed = _report(
        badging: _release,
        signature: _testKey,
        contents: installedContents(
          entries(['AndroidManifest.xml', 'classes.dex']),
          [
            entries(['lib/arm64-v8a/libapp.so', 'lib/arm64-v8a/libflutter.so']),
          ],
        ),
      );

      final comparison = compareApks(
        installed,
        _report(sha256: 'bbbb', badging: _release, signature: _testKey),
      );

      expect(_field(comparison, 'ABIs').differs, isFalse);
      expect(_field(comparison, 'Flutter build').differs, isFalse);
      expect(comparison.signer, SignerVerdict.same);
      expect(comparison.updateBlockers, isEmpty);
    });

    test('an app installed as splits has no hash: never the same file', () {
      // Its hashes are base.apk's; bundletool's base-master.apk is that
      // same file, without the split's native code.
      final installed = _report(
        size: 15100000,
        badging: _release,
        signature: _testKey,
      );
      final baseMaster = _report(
        size: 787811,
        contents: _contents(['AndroidManifest.xml', 'classes.dex']),
        badging: _release,
        signature: _testKey,
      );

      final comparison = compareApks(
        installed,
        baseMaster,
        referenceIsSplit: true,
      );

      expect(comparison.sameFile, isFalse);
      expect(
        comparison.fields.map((f) => f.label),
        isNot(anyOf(contains('MD5'), contains('SHA-256'))),
      );
      expect(_field(comparison, 'Size').differs, isTrue);
      expect(
        comparisonFindings(
          comparison,
          reference: 'the installed app',
          candidate: 'the selected APK',
        ).map((f) => f.title),
        isNot(contains('The same file')),
      );
    });

    test('dropping native code altogether loses no device', () {
      final comparison = compareApks(
        _report(contents: _flutterArm64),
        _report(contents: _contents(['classes.dex'])),
      );

      final abis = _field(comparison, 'ABIs');
      expect(abis.candidate, 'None (runs on any ABI)');
      expect(abis.level, FindingLevel.info);
    });

    test('a debug Flutter build over a release one', () {
      final comparison = compareApks(
        _report(contents: _flutterArm64),
        _report(
          contents: _contents([
            'lib/arm64-v8a/libflutter.so',
            'assets/flutter_assets/kernel_blob.bin',
          ]),
        ),
      );

      final flutter = _field(comparison, 'Flutter build');
      expect(flutter.candidate, 'JIT (debug)');
      expect(flutter.level, FindingLevel.warning);
    });

    test('a part that could not be read is not compared, not a difference', () {
      final comparison = compareApks(
        _report(badging: _release, signature: _testKey),
        _report(
          sha256: 'bbbb',
          badgingError: 'aapt2 was not found (Android SDK build-tools).',
          signature: _testKey,
        ),
      );

      expect(comparison.notCompared, hasLength(1));
      final manifest = comparison.notCompared.single;
      expect(manifest.section, 'Manifest');
      expect(manifest.reference, isNull);
      expect(manifest.candidate, contains('aapt2 was not found'));
      expect(comparison.fields.where((f) => f.section == 'Manifest'), isEmpty);
      expect(comparison.signer, SignerVerdict.same);
    });

    test('an unreadable signature leaves the signers unknown', () {
      final comparison = compareApks(
        _report(badging: _release, signatureError: 'apksigner was not found.'),
        _report(badging: _release, signature: _testKey),
      );

      expect(comparison.signer, SignerVerdict.unknown);
      final signature = comparison.notCompared.single;
      expect(signature.section, 'Signature');
      expect(signature.reference, 'apksigner was not found.');
      expect(signature.candidate, isNull);
      expect(comparison.fields.where((f) => f.section == 'Signature'), isEmpty);
    });
  });

  group('installSignerWarning', () {
    test('another key: Android refuses the update, and why it matters', () {
      final warning = installSignerWarning(_testKey, _debugKey)!;

      expect(warning, contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE'));
      expect(warning, contains('uninstalled first, which deletes its data'));
      expect(warning, contains('B3:4C:94:45…58:2D:CF:A8'));
      expect(warning, contains('this APK: D9:74:F2:84…51:F2:AE:8D'));
    });

    test('the same key, or a key rotated from it, installs as an update', () {
      final oldKey = parseApksignerVerify(
        fixture('apksigner_verify_old_key.txt'),
      );
      final rotated =
          parseApksignerVerify(fixture('apksigner_verify_rotated_v3.txt'))
              .withLineage(
                parseApksignerLineage(fixture('apksigner_lineage_rotated.txt')),
              );

      expect(installSignerWarning(_testKey, _testKey), isNull);
      expect(installSignerWarning(oldKey, rotated), isNull);
    });

    test('nothing to compare: no warning', () {
      final unsigned = parseApksignerVerify(
        fixture('apksigner_verify_unsigned.txt'),
      );

      expect(installSignerWarning(null, _testKey), isNull);
      expect(installSignerWarning(_testKey, null), isNull);
      expect(installSignerWarning(_testKey, unsigned), isNull);
    });
  });

  group('comparisonFindings', () {
    List<Finding> findings(ApkComparison comparison) => comparisonFindings(
      comparison,
      reference: 'the installed app',
      candidate: 'the selected APK',
    );

    test('the same signer and nothing in the way: an update', () {
      final result = findings(
        compareApks(
          _report(badging: _debug, signature: _testKey),
          _report(sha256: 'bbbb', badging: _release, signature: _testKey),
        ),
      );

      expect(result.map((f) => f.title), [
        'Same signer',
        'Installs as an update over the installed app',
      ]);
      expect(result.every((f) => f.level == FindingLevel.ok), isTrue);
    });

    test('the blockers, each with its reason, before the rest', () {
      final result = findings(
        compareApks(
          _report(badging: _release, signature: _testKey),
          _report(sha256: 'bbbb', badging: _debug, signature: _debugKey),
        ),
      );

      expect(result.map((f) => f.title), [
        'Different signer',
        'Won\'t install as an update over the installed app',
      ]);
      // Both signers, short, so the wrong key stands out.
      expect(result[0].detail!.split('\n').skip(1), [
        'The installed app: SHA-256 B3:4C:94:45…58:2D:CF:A8',
        'The selected APK: SHA-256 D9:74:F2:84…51:F2:AE:8D',
      ]);
      final blockers = result[1].detail!.split('\n');
      expect(blockers, hasLength(2));
      expect(
        blockers[0],
        startsWith('Signer SHA-256: Signed with another key'),
      );
      expect(blockers[1], startsWith('Version code: Lower'));
    });

    test('the same file, and what could not be compared on which side', () {
      final apk = _report(
        badgingError: 'aapt2 was not found (Android SDK build-tools).',
        signature: _testKey,
      );

      final result = findings(compareApks(apk, apk));

      expect(result.map((f) => f.title), [
        'Manifest not compared',
        'The same file',
        'Same signer',
      ]);
      expect(
        result.first.detail,
        'The installed app: aapt2 was not found (Android SDK build-tools).\n'
        'The selected APK: aapt2 was not found (Android SDK build-tools).',
      );
    });
  });
}
