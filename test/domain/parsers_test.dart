import 'package:apk_forge/domain/analysis/badging.dart';
import 'package:apk_forge/domain/analysis/signature.dart';
import 'package:apk_forge/domain/build/flutter_build.dart';
import 'package:apk_forge/domain/devices/devices.dart';
import 'package:apk_forge/domain/signing/keystore.dart';
import 'package:apk_forge/domain/signing/signing.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fakes.dart';

void main() {
  group('parseBadging', () {
    test('reads a release split', () {
      final badging = parseBadging(fixture('aapt2_badging_release.txt'));

      expect(badging.packageName, 'io.example.sample_app');
      expect(badging.versionName, '1.0.0');
      // A split's versionCode carries the ABI's offset (arm64-v8a: 2000).
      expect(badging.versionCode, '2001');
      expect(badging.minSdk, 24);
      expect(badging.targetSdk, 36);
      expect(badging.compileSdk, 36);
      expect(badging.label, 'sample_app');
      expect(badging.debuggable, isFalse);
      expect(badging.nativeCode, ['arm64-v8a']);
      expect(badging.launchableActivity, 'io.example.sample_app.MainActivity');
    });

    test('a debug build is debuggable and lists its permissions', () {
      final badging = parseBadging(fixture('aapt2_badging_debug.txt'));

      expect(badging.debuggable, isTrue);
      expect(badging.versionCode, '1');
      expect(badging.permissions, contains('android.permission.INTERNET'));
    });

    test('takes aapt v1\'s sdkVersion as the min SDK', () {
      final badging = parseBadging([
        "sdkVersion:'21'",
        "targetSdkVersion:'34'",
      ]);

      expect(badging.minSdk, 21);
      expect(badging.targetSdk, 34);
    });

    test('lists every ABI of a universal APK', () {
      final badging = parseBadging([
        "native-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64'",
      ]);

      expect(badging.nativeCode, ['arm64-v8a', 'armeabi-v7a', 'x86_64']);
    });
  });

  group('parseApksignerVerify', () {
    test('reads the Android debug signer and the schemes', () {
      final report = parseApksignerVerify(
        fixture('apksigner_verify_debug_key.txt'),
      );

      expect(report.verifies, isTrue);
      expect(report.schemes, {
        'v1': false,
        'v2': true,
        'v3': false,
        'v3.1': false,
        'v4': false,
      });
      expect(report.signers, hasLength(1));
      final signer = report.signers.single;
      expect(signer.label, 'Signer #1');
      expect(signer.distinguishedName, 'C=US, O=Android, CN=Android Debug');
      expect(signer.isAndroidDebugKey, isTrue);
      expect(
        signer.sha256,
        'd974f284baf2467bebca0d1dd7061ce29a4fdd3efcdea70bcae1fa6351f2ae8d',
      );
      expect(signer.keyAlgorithm, 'RSA');
      expect(signer.keySize, 2048);
    });

    test('a release key is not the debug key', () {
      final report = parseApksignerVerify(
        fixture('apksigner_verify_test_key.txt'),
      );

      expect(
        report.signers.single.distinguishedName,
        'CN=APK Forge Test, O=Example, C=US',
      );
      expect(report.signers.single.isAndroidDebugKey, isFalse);
      expect(report.scheme('v3'), isTrue);
    });

    test('v1 is not verified from minSdk 24, even when it is there; v4 is, '
        'with its .idsig', () {
      // Signed with every scheme on: the APK has META-INF/UPLOAD.SF and .RSA.
      final report = parseApksignerVerify(
        fixture('apksigner_verify_all_schemes.txt'),
      );

      expect(report.verifies, isTrue);
      expect(report.schemes, {
        'v1': false,
        'v2': true,
        'v3': true,
        'v3.1': false,
        'v4': true,
      });
      expect(
        report.signers.single.distinguishedName,
        'CN=APK Forge Schemes, O=Example, C=US',
      );
    });

    test('an .idsig that does not match the APK reads v4 false, and '
        'apksigner says nothing else', () {
      // Another APK's .idsig; another key's prints the same, byte for byte.
      final report = parseApksignerVerify(
        fixture('apksigner_verify_v4_idsig_mismatch.txt'),
      );

      expect(report.verifies, isTrue);
      expect(report.schemes, {
        'v1': false,
        'v2': true,
        'v3': true,
        'v3.1': false,
        'v4': false,
      });
      expect(report.errors, isEmpty);
      expect(report.warnings, isEmpty);
      expect(
        report.signers.single.distinguishedName,
        'CN=APK Forge Idsig, O=Example, C=US',
      );
    });

    test('a corrupt .idsig stops apksigner before its verdict', () {
      final report = parseApksignerVerify(
        fixture('apksigner_verify_v4_idsig_corrupt.txt'),
      );

      expect(report.verifies, isFalse);
      expect(report.errors, ['Invalid signature version.']);
      expect(report.signers, isEmpty);
    });

    test('an unsigned APK does not verify and says why', () {
      final report = parseApksignerVerify(
        fixture('apksigner_verify_unsigned.txt'),
      );

      expect(report.verifies, isFalse);
      expect(report.errors, ['Missing META-INF/MANIFEST.MF']);
      expect(report.signers, isEmpty);
    });

    test('a file that is not a ZIP keeps the exception message', () {
      final report = parseApksignerVerify(
        fixture('apksigner_verify_not_zip.txt'),
      );

      expect(report.verifies, isFalse);
      expect(report.errors.first, 'Malformed APK: not a ZIP archive');
    });

    test('keeps the warnings apart from the errors', () {
      final report = parseApksignerVerify([
        'Verifies',
        'WARNING: META-INF/x.txt not protected by signature.',
      ]);

      expect(report.warnings, ['META-INF/x.txt not protected by signature.']);
      expect(report.errors, isEmpty);
    });

    test('a v3 rotation shows only the new key', () {
      final report = parseApksignerVerify(
        fixture('apksigner_verify_rotated_v3.txt'),
      );

      expect(report.scheme('v3'), isTrue);
      expect(report.scheme('v3.1'), isFalse);
      expect(
        report.signers.single.distinguishedName,
        'CN=APK Forge New Key, O=Example, C=US',
      );
      expect(report.lineage, isEmpty);
    });

    test('a v3.1 rotation lists a signer per API range, newest first', () {
      final report = parseApksignerVerify(
        fixture('apksigner_verify_rotated_v31.txt'),
      );

      expect(report.scheme('v3.1'), isTrue);
      expect(report.signers.map((s) => s.label), [
        'Signer (minSdkVersion=33, maxSdkVersion=2147483647)',
        'Signer (minSdkVersion=24, maxSdkVersion=32)',
      ]);
      expect(report.signers.map((s) => s.distinguishedName), [
        'CN=APK Forge New Key, O=Example, C=US',
        'CN=APK Forge Old Key, O=Example, C=US',
      ]);
      expect(report.signers.map((s) => s.apiRange), ['API 33+', 'API 24–32']);
      expect(
        parseApksignerVerify(fixture('apksigner_verify_old_key.txt'))
            .signers
            .single
            .apiRange,
        isNull,
      );
    });
  });

  group('parseApksignerLineage', () {
    test('reads the rotation, oldest key first', () {
      final lineage = parseApksignerLineage(
        fixture('apksigner_lineage_rotated.txt'),
      );

      expect(lineage.map((s) => s.distinguishedName), [
        'CN=APK Forge Old Key, O=Example, C=US',
        'CN=APK Forge New Key, O=Example, C=US',
      ]);
      // The same certificates as `verify` prints for each key.
      final oldKey = parseApksignerVerify(
        fixture('apksigner_verify_old_key.txt'),
      ).signers.single;
      final newKey = parseApksignerVerify(
        fixture('apksigner_verify_rotated_v3.txt'),
      ).signers.single;
      expect(lineage.first.sha256, oldKey.sha256);
      expect(lineage.first.sha1, oldKey.sha1);
      expect(lineage.last.sha256, newKey.sha256);
    });

    test('an APK whose key never rotated has none', () {
      expect(
        parseApksignerLineage(fixture('apksigner_lineage_none.txt')),
        isEmpty,
      );
    });

    test('withLineage keeps the rest of the report', () {
      final report =
          parseApksignerVerify(fixture('apksigner_verify_rotated_v3.txt'))
              .withLineage(
                parseApksignerLineage(fixture('apksigner_lineage_rotated.txt')),
              );

      expect(report.verifies, isTrue);
      expect(report.scheme('v2'), isTrue);
      expect(report.signers, hasLength(1));
      expect(report.lineage, hasLength(2));
    });
  });

  group('parseKeyLoadFailure', () {
    test('says which password apksigner could not use', () {
      expect(
        parseKeyLoadFailure(fixture('apksigner_sign_key_password_missing.txt')),
        KeyLoadFailure.keyPasswordMissing,
      );
      expect(
        parseKeyLoadFailure(fixture('apksigner_sign_wrong_key_password.txt')),
        KeyLoadFailure.keyPasswordWrong,
      );
      expect(
        parseKeyLoadFailure(fixture('apksigner_sign_wrong_store_password.txt')),
        KeyLoadFailure.storePasswordWrong,
      );
    });

    test('another failure is not about the key', () {
      expect(
        parseKeyLoadFailure(fixture('apksigner_verify_not_zip.txt')),
        isNull,
      );
    });
  });

  group('parseKeyOpenFailure', () {
    test('a certificate request printed: the key opens', () {
      expect(parseKeyOpenFailure(fixture('keytool_certreq_ok.txt')), isNull);
    });

    test('says which password, or which alias, is wrong', () {
      expect(
        parseKeyOpenFailure(fixture('keytool_certreq_wrong_key_password.txt')),
        'The key password (keyPassword) is wrong.',
      );
      expect(
        parseKeyOpenFailure(
          fixture('keytool_certreq_wrong_store_password.txt'),
        ),
        'The keystore password (storePassword) is wrong.',
      );
      expect(
        parseKeyOpenFailure(fixture('keytool_certreq_no_alias.txt')),
        'The keystore has no key "missing" (keyAlias).',
      );
    });

    test('another keytool error keeps its message', () {
      expect(
        parseKeyOpenFailure([
          'keytool error: java.lang.Exception: Keystore file does not exist: x',
        ]),
        'Keystore file does not exist: x',
      );
      expect(parseKeyOpenFailure(const []), 'keytool could not open the key.');
    });
  });

  group('parseKeytoolList', () {
    test('reads each alias with its first certificate', () {
      final entries = parseKeytoolList(fixture('keytool_list.txt'));

      expect(entries.map((e) => e.alias), ['forge-test', 'second-key']);
      final rsa = entries.first;
      expect(rsa.entryType, 'PrivateKeyEntry');
      expect(rsa.canSign, isTrue);
      expect(rsa.owner, 'CN=APK Forge Test, O=Example, C=US');
      expect(
        rsa.sha256,
        'b34c9445c5e411b045884f499034b5592ab109ec5cd1ca9cb584e54f582dcfa8',
      );
      expect(rsa.validUntil, 'Tue Mar 03 07:57:32 AST 2054');
      expect(rsa.keyAlgorithm, '2048-bit RSA key');
      expect(entries.last.keyAlgorithm, '256-bit EC (secp256r1) key');
    });

    test('the keystore SHA-256 matches apksigner\'s for the same key', () {
      final key = parseKeytoolList(fixture('keytool_list.txt')).first;
      final signer = parseApksignerVerify(
        fixture('apksigner_verify_test_key.txt'),
      ).signers.single;

      expect(key.sha256, signer.sha256);
    });

    test('takes the signer, not the CA, from a chain', () {
      final entries = parseKeytoolList([
        'Alias name: upload',
        'Entry type: PrivateKeyEntry',
        'Certificate chain length: 2',
        'Certificate[1]:',
        'Owner: CN=Leaf',
        '\t SHA256: AA:BB',
        'Certificate[2]:',
        'Owner: CN=Root CA',
        '\t SHA256: CC:DD',
      ]);

      expect(entries.single.owner, 'CN=Leaf');
      expect(entries.single.sha256, 'aabb');
    });

    test('a trusted certificate cannot sign', () {
      final entries = parseKeytoolList([
        'Alias name: ca',
        'Entry type: trustedCertEntry',
        'Owner: CN=CA',
      ]);

      expect(entries.single.canSign, isFalse);
    });
  });

  group('parseBuiltApks', () {
    test('reads every split, relative to the project', () {
      final apks = parseBuiltApks(
        fixture('flutter_build_split.txt'),
        projectDir: '/work/app',
        host: macHost,
      );

      expect(apks, [
        '/work/app/build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk',
        '/work/app/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk',
        '/work/app/build/app/outputs/flutter-apk/app-x86_64-release.apk',
      ]);
    });

    test('reads a debug line, which has no size', () {
      final apks = parseBuiltApks(
        fixture('flutter_build_debug.txt'),
        projectDir: '/work/app',
        host: macHost,
      );

      expect(apks, ['/work/app/build/app/outputs/flutter-apk/app-debug.apk']);
    });

    test('ignores the warnings around them', () {
      final apks = parseBuiltApks(
        [
          'Warning: The generated ELF library contains unobfuscated DWARF debugging information.',
        ],
        projectDir: '/work/app',
        host: macHost,
      );

      expect(apks, isEmpty);
    });
  });

  group('adb', () {
    test('parseAdbDevices reads ready and unauthorized devices', () {
      final devices = parseAdbDevices([
        'List of devices attached',
        '0123456789ABCDEF   device usb:1-1 product:K10 model:K10 device:K10 transport_id:1',
        'emulator-5554          unauthorized transport_id:2',
        '',
      ]);

      expect(devices.map((d) => d.serial), [
        '0123456789ABCDEF',
        'emulator-5554',
      ]);
      expect(devices.first.isReady, isTrue);
      expect(devices.first.model, 'K10');
      expect(devices.last.isReady, isFalse);
      expect(devices.last.displayName, 'emulator-5554');
    });

    test('parseAdbDevices skips the daemon start lines', () {
      final devices = parseAdbDevices([
        '* daemon not running; starting now at tcp:5037',
        '* daemon started successfully',
        'List of devices attached',
      ]);

      expect(devices, isEmpty);
    });

    test('parseAbiList keeps the device order', () {
      expect(parseAbiList('arm64-v8a,armeabi-v7a,armeabi\n'), [
        'arm64-v8a',
        'armeabi-v7a',
        'armeabi',
      ]);
    });

    test('isAbiCompatible', () {
      expect(
        isAbiCompatible(['arm64-v8a'], ['arm64-v8a', 'armeabi-v7a']),
        isTrue,
      );
      expect(
        isAbiCompatible(['x86_64'], ['arm64-v8a', 'armeabi-v7a']),
        isFalse,
      );
      // No native code runs anywhere; unknown device ABIs get the benefit of the doubt.
      expect(isAbiCompatible([], ['arm64-v8a']), isTrue);
      expect(isAbiCompatible(['x86_64'], []), isTrue);
    });

    test('parseInstallFailure reads the code and gives the hint', () {
      final failure = parseInstallFailure([
        'Performing Streamed Install',
        'adb: failed to install app.apk: Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package signatures do not match newer version; ignoring!]',
      ]);

      expect(failure!.code, 'INSTALL_FAILED_UPDATE_INCOMPATIBLE');
      expect(failure.hint, contains('different key'));
    });

    test('parseInstallFailure falls back to adb\'s own message', () {
      final failure = parseInstallFailure([
        'Failure [INSTALL_FAILED_OTHER: something odd]',
      ]);

      expect(failure!.hint, 'something odd');
    });

    test('adbInstallArguments', () {
      expect(adbInstallArguments('S1', '/a.apk', allowDowngrade: false), [
        '-s',
        'S1',
        'install',
        '-r',
        '/a.apk',
      ]);
      expect(adbInstallArguments('S1', '/a.apk', allowDowngrade: true), [
        '-s',
        'S1',
        'install',
        '-r',
        '-d',
        '/a.apk',
      ]);
    });
  });
}
