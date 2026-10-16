import 'package:apk_forge/core/zip/zip_directory.dart';
import 'package:apk_forge/domain/analysis/apk_report.dart';
import 'package:apk_forge/domain/analysis/badging.dart';
import 'package:apk_forge/domain/analysis/findings.dart';
import 'package:apk_forge/domain/analysis/signature.dart';
import 'package:apk_forge/domain/signing/keystore.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fakes.dart';

ZipEntry _entry(String name) => ZipEntry(
  name: name,
  compressedSize: 1,
  uncompressedSize: 1,
  isCompressed: false,
);

ApkContents _contents(List<String> names) =>
    ApkContents.fromEntries(names.map(_entry).toList());

ApkReport _report({
  ApkContents contents = const ApkContents(),
  Badging? badging = const Badging(targetSdk: 36),
  SignatureReport? signature,
}) => ApkReport(
  path: '/a.apk',
  sizeBytes: 1,
  md5: 'm',
  sha256: 's',
  contents: contents,
  badging: badging,
  badgingError: badging == null ? 'aapt2 was not found.' : null,
  signature: signature,
  signatureError: signature == null ? 'apksigner was not found.' : null,
);

void main() {
  group('ApkContents', () {
    test('groups native libraries by ABI and spots a release Flutter app', () {
      final contents = _contents([
        'lib/arm64-v8a/libflutter.so',
        'lib/arm64-v8a/libapp.so',
        'lib/armeabi-v7a/libflutter.so',
        'lib/armeabi-v7a/libapp.so',
        'classes.dex',
      ]);

      expect(contents.nativeLibraries, {
        'arm64-v8a': ['libapp.so', 'libflutter.so'],
        'armeabi-v7a': ['libapp.so', 'libflutter.so'],
      });
      expect(contents.flutter, FlutterCompilation.aot);
      expect(contents.abisWithoutFlutterEngine, isEmpty);
    });

    test('a debug Flutter app has the JIT kernel', () {
      final contents = _contents([
        'lib/x86_64/libflutter.so',
        'assets/flutter_assets/kernel_blob.bin',
      ]);

      expect(contents.flutter, FlutterCompilation.jit);
    });

    test('an ABI with only a plugin\'s library has no Flutter engine', () {
      final contents = _contents([
        'lib/arm64-v8a/libflutter.so',
        'lib/arm64-v8a/libapp.so',
        'lib/x86/libsqlite3.so',
      ]);

      expect(contents.abisWithoutFlutterEngine, ['x86']);
    });

    test('a native app that isn\'t Flutter has no engine to miss', () {
      final contents = _contents(['lib/arm64-v8a/libnative.so']);

      expect(contents.isFlutterApp, isFalse);
      expect(contents.abisWithoutFlutterEngine, isEmpty);
    });

    test('a v1 signature needs the manifest and a signature block', () {
      expect(
        _contents([
          'META-INF/MANIFEST.MF',
          'META-INF/CERT.SF',
          'META-INF/CERT.RSA',
        ]).hasJarSignature,
        isTrue,
      );
      expect(
        _contents(['META-INF/MANIFEST.MF', 'META-INF/KEY.EC']).hasJarSignature,
        isTrue,
      );
      // Gradle's metadata under META-INF/ is not a signature.
      expect(
        _contents(['META-INF/com/android/build/gradle/app-metadata.properties'])
            .hasJarSignature,
        isFalse,
      );
    });
  });

  group('apkFindings', () {
    final debugSigned = parseApksignerVerify(
      fixture('apksigner_verify_debug_key.txt'),
    );
    final testSigned = parseApksignerVerify(
      fixture('apksigner_verify_test_key.txt'),
    );
    final keys = parseKeytoolList(fixture('keytool_list.txt'));

    test('the debug key is a warning; a release build is fine', () {
      final findings = apkFindings(_report(signature: debugSigned));

      expect(findings.map((f) => f.title), [
        'Signed with the Android debug key',
        'Release build (not debuggable)',
      ]);
    });

    test('says which loaded key signed it', () {
      final findings = apkFindings(
        _report(signature: testSigned),
        keystoreEntries: keys,
      );

      expect(findings.first.level, FindingLevel.ok);
      expect(
        findings.map((f) => f.title),
        contains('Signed with your key “forge-test”'),
      );
    });

    test('warns when the loaded keystore did not sign it', () {
      final findings = apkFindings(
        _report(signature: debugSigned),
        keystoreEntries: keys,
      );

      expect(
        findings.map((f) => f.title),
        contains('Not signed with the loaded keystore'),
      );
    });

    test('a signature that does not verify comes first, as an error', () {
      final unsigned = parseApksignerVerify(
        fixture('apksigner_verify_unsigned.txt'),
      );
      final findings = apkFindings(_report(signature: unsigned));

      expect(findings.first.level, FindingLevel.error);
      expect(findings.first.title, 'The signature does not verify');
      expect(findings.first.detail, 'Missing META-INF/MANIFEST.MF');
    });

    test('v1 alone is an error for targetSdk 30+', () {
      const v1Only = SignatureReport(
        verifies: true,
        schemes: {'v1': true, 'v2': false, 'v3': false},
        signers: [
          SignerCertificate(
            label: 'Signer #1',
            distinguishedName: 'CN=Release',
          ),
        ],
      );

      expect(
        apkFindings(_report(signature: v1Only)).first.title,
        'No v2 or v3 signature',
      );
      expect(
        apkFindings(
          _report(signature: v1Only, badging: const Badging(targetSdk: 29)),
        ).map((f) => f.title),
        isNot(contains('No v2 or v3 signature')),
      );
    });

    test('reports a debug build and a missing engine', () {
      final findings = apkFindings(
        _report(
          signature: testSigned,
          badging: const Badging(targetSdk: 36, debuggable: true),
          contents: _contents([
            'lib/arm64-v8a/libflutter.so',
            'lib/x86/libplugin.so',
          ]),
        ),
      );

      expect(findings.first.title, 'No Flutter engine for x86');
      expect(
        findings.map((f) => f.title),
        contains('Debug build (debuggable)'),
      );
    });

    test('a missing tool is a warning, not a crash', () {
      final findings = apkFindings(_report(badging: null));

      expect(
        findings.map((f) => f.title),
        containsAll(['Signature not checked', 'Build type unknown']),
      );
    });
  });
}
