import 'package:apk_forge/core/zip/zip_directory.dart';
import 'package:apk_forge/domain/analysis/apk_report.dart';
import 'package:apk_forge/domain/analysis/badging.dart';
import 'package:apk_forge/domain/analysis/findings.dart';
import 'package:apk_forge/domain/analysis/signature.dart';
import 'package:apk_forge/domain/signing/abi_split.dart';
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
  test('describeSchemes never calls a v1 signature apksigner skipped '
      'missing', () {
    const v2v3 = {
      'v1': false,
      'v2': true,
      'v3': true,
      'v3.1': false,
      'v4': false,
    };

    expect(describeSchemes(v2v3, hasJarSignature: false), 'v2, v3');
    expect(describeSchemes(v2v3, hasJarSignature: true), 'v2, v3, v1 present');
    expect(
      describeSchemes(const {'v1': true, 'v2': true}, hasJarSignature: true),
      'v1, v2',
    );
    expect(
      describeSchemes(const {'v1': false, 'v2': false}, hasJarSignature: false),
      'None',
    );
  });

  group('schemeStatus', () {
    const idsig = '/apks/app.apk.idsig';
    final allSchemes = parseApksignerVerify(
      fixture('apksigner_verify_all_schemes.txt'),
    );
    final v4False = parseApksignerVerify(
      fixture('apksigner_verify_v4_idsig_mismatch.txt'),
    );

    SchemeStatus v4(SignatureReport signature) =>
        schemeStatus(signature, 'v4', hasJarSignature: false);

    test('v4 without an .idsig next to the APK is not checked, not '
        'missing', () {
      final signature = parseApksignerVerify(
        fixture('apksigner_verify_test_key.txt'),
      );

      final status = v4(signature);

      expect(status.state, SchemeState.unchecked);
      expect(status.description, startsWith('Not checked'));
      expect(status.description, contains('.idsig'));
      expect(signature.v4Problem, isNull);
    });

    test('v4 verified with its .idsig', () {
      final signature = allSchemes.withV4SignatureFile(idsig);

      expect(v4(signature).state, SchemeState.verified);
      expect(signature.v4Problem, isNull);
    });

    test('an .idsig that does not match the APK fails v4, and says so', () {
      final signature = v4False.withV4SignatureFile(idsig);

      final status = v4(signature);

      expect(status.state, SchemeState.failed);
      expect(
        signature.v4Problem,
        "The .idsig next to this APK doesn't match it: it was written for "
        'another APK or another signature.',
      );
      expect(status.description, signature.v4Problem);
    });

    test('a corrupt .idsig fails v4 with apksigner\'s reason', () {
      final signature = v4False.withV4SignatureFile(
        idsig,
        error: 'Invalid signature version.',
      );

      expect(v4(signature).state, SchemeState.failed);
      expect(
        signature.v4Problem,
        "The .idsig next to this APK couldn't be read: Invalid signature "
        'version.',
      );
    });

    test('the key rotation keeps the .idsig it was checked with', () {
      final signature = allSchemes.withV4SignatureFile(idsig).withLineage(
        const [SignerCertificate(label: 'Signer #1')],
      );

      expect(signature.v4SignatureFile, idsig);
      expect(signature.lineage, hasLength(1));
    });

    test('a v1 apksigner skipped is present; a scheme it lacks is not', () {
      final v1 = schemeStatus(allSchemes, 'v1', hasJarSignature: true);
      expect([v1.state, v1.label], [SchemeState.presentOnly, 'v1 present']);

      final v31 = schemeStatus(allSchemes, 'v3.1', hasJarSignature: true);
      expect([v31.state, v31.description], [SchemeState.absent, 'Not present']);
      expect(
        schemeStatus(allSchemes, 'v1', hasJarSignature: false).state,
        SchemeState.absent,
      );
      expect(
        schemeStatus(allSchemes, 'v3', hasJarSignature: false).state,
        SchemeState.verified,
      );
    });
  });

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

  group('splitting per ABI', () {
    test('one APK per ABI with native code, in the order of the folders', () {
      final plan = planAbiSplit(
        _contents([
          'lib/x86_64/libflutter.so',
          'lib/x86_64/libapp.so',
          'lib/arm64-v8a/libflutter.so',
          'lib/arm64-v8a/libapp.so',
          'lib/armeabi-v7a/libflutter.so',
          'lib/armeabi-v7a/libapp.so',
          'classes.dex',
        ]),
      );

      expect(plan.abis, ['arm64-v8a', 'armeabi-v7a', 'x86_64']);
      expect(plan.withoutEngine, isEmpty);
      expect(plan.canSplit, isTrue);
    });

    test('a Flutter ABI without the engine gets no APK', () {
      final plan = planAbiSplit(
        _contents([
          'lib/arm64-v8a/libflutter.so',
          'lib/arm64-v8a/libapp.so',
          'lib/x86_64/libflutter.so',
          'lib/x86_64/libapp.so',
          'lib/x86/libplugin.so',
        ]),
      );

      expect(plan.abis, ['arm64-v8a', 'x86_64']);
      expect(plan.withoutEngine, ['x86']);
    });

    test('a non-Flutter app splits by whatever ABIs it has', () {
      final plan = planAbiSplit(
        _contents(['lib/x86/libnative.so', 'lib/arm64-v8a/libnative.so']),
      );

      expect(plan.abis, ['arm64-v8a', 'x86']);
    });

    test('one ABI or none: nothing to split', () {
      expect(
        planAbiSplit(_contents(['lib/arm64-v8a/libflutter.so'])).canSplit,
        isFalse,
      );
      expect(planAbiSplit(_contents(['classes.dex'])).abis, isEmpty);
    });

    test('only the ABIs chosen get an APK', () {
      final universal = _contents([
        for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']) ...[
          'lib/$abi/libflutter.so',
          'lib/$abi/libapp.so',
        ],
      ]);

      final two = planAbiSplit(
        universal,
        only: {'arm64-v8a', 'armeabi-v7a', 'riscv64'},
      );
      expect(two.abis, ['arm64-v8a', 'armeabi-v7a']);
      expect(two.notChosen, ['x86_64']);
      expect(two.missing, ['riscv64']);
      expect(two.canSplit, isTrue);

      // One chosen out of three: still a cut, without the other two.
      final one = planAbiSplit(universal, only: {'arm64-v8a'});
      expect(one.abis, ['arm64-v8a']);
      expect(one.canSplit, isTrue);

      final none = planAbiSplit(universal, only: {'riscv64'});
      expect(none.abis, isEmpty);
      expect(none.noneChosen, isTrue);
      expect(none.canSplit, isFalse);
    });

    group('splitAvailability', () {
      final universal = _contents([
        for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']) ...[
          'lib/$abi/libflutter.so',
          'lib/$abi/libapp.so',
        ],
      ]);
      String note(SplitAvailability availability) => switch (availability) {
        CanSplit(:final summary) => 'can: $summary',
        CannotSplit(:final reason) => 'cannot: $reason',
      };

      test('fewer than two ABIs in Defaults: never', () {
        expect(
          note(splitAvailability({'arm64-v8a'}, contents: universal)),
          'cannot: Needs two or more architectures in Defaults.',
        );
        expect(
          note(splitAvailability({})),
          'cannot: Needs two or more architectures in Defaults.',
        );
      });

      test('no APK read yet: one per ABI in Defaults', () {
        expect(
          note(splitAvailability({'arm64-v8a', 'x86_64'})),
          'can: Writes 2 signed APKs, one per architecture in Defaults: '
          'arm64-v8a, x86_64.',
        );
      });

      test('an APK: one per ABI it has, and the ones it lacks', () {
        expect(
          note(
            splitAvailability({
              'arm64-v8a',
              'armeabi-v7a',
              'riscv64',
            }, contents: universal),
          ),
          'can: Writes 2 signed APKs, one per architecture in Defaults: '
          'arm64-v8a, armeabi-v7a. It has no riscv64.',
        );
        expect(
          note(splitAvailability({'riscv64', 'x86'}, contents: universal)),
          'cannot: It has none of the architectures in Defaults.',
        );
      });

      test('an APK with one ABI, or none: nothing to split', () {
        final one = _contents([
          'lib/arm64-v8a/libflutter.so',
          'lib/arm64-v8a/libapp.so',
        ]);
        expect(
          note(splitAvailability({'arm64-v8a', 'x86_64'}, contents: one)),
          'cannot: It only has arm64-v8a: nothing to split.',
        );
        expect(
          note(
            splitAvailability({
              'arm64-v8a',
              'x86_64',
            }, contents: _contents(['classes.dex'])),
          ),
          'cannot: It has no native code: nothing to split.',
        );
      });
    });

    test('one ABI is nothing to split, whatever was chosen', () {
      final plan = planAbiSplit(
        _contents(['lib/arm64-v8a/libflutter.so', 'lib/arm64-v8a/libapp.so']),
        only: {'armeabi-v7a', 'x86_64'},
      );

      expect(plan.abis, ['arm64-v8a']);
      expect(plan.canSplit, isFalse);
      expect(plan.noneChosen, isFalse);
      expect(plan.missing, isEmpty);
    });

    test('each split keeps everything but the other ABIs and the v1 files', () {
      bool keeps(String name) => keepsEntryForAbi(name, 'arm64-v8a');

      expect(keeps('lib/arm64-v8a/libflutter.so'), isTrue);
      expect(keeps('lib/arm64-v8a/'), isTrue);
      expect(keeps('lib/x86_64/libflutter.so'), isFalse);
      expect(keeps('lib/armeabi-v7a/'), isFalse);
      expect(keeps('classes.dex'), isTrue);
      expect(keeps('resources.arsc'), isTrue);
      expect(keeps('assets/flutter_assets/AssetManifest.bin'), isTrue);
      expect(keeps('META-INF/MANIFEST.MF'), isFalse);
      expect(keeps('META-INF/CERT.RSA'), isFalse);
      expect(keeps('META-INF/services/l0'), isTrue);
    });

    test('isJarSignatureFile: the v1 signature files only', () {
      for (final name in [
        'META-INF/MANIFEST.MF',
        'META-INF/CERT.SF',
        'META-INF/CERT.RSA',
        'META-INF/upload.ec',
        'META-INF/KEY.DSA',
        'META-INF/SIG-ANDROID',
      ]) {
        expect(isJarSignatureFile(name), isTrue, reason: name);
      }
      for (final name in [
        'META-INF/androidx.core_core.version',
        'META-INF/services/l0',
        'META-INF/com/android/build/gradle/app-metadata.properties',
        'META-INF/version-control-info.textproto',
        'assets/CERT.RSA',
      ]) {
        expect(isJarSignatureFile(name), isFalse, reason: name);
      }
    });

    test('the split is named after the APK and its ABI', () {
      expect(
        abiSplitFileName('/ci/app-release.apk', 'arm64-v8a', macHost),
        'app-release-arm64-v8a.apk',
      );
    });
  });
}
