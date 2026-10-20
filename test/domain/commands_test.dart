import 'package:apk_forge/core/process/command.dart';
import 'package:apk_forge/core/system/host.dart';
import 'package:apk_forge/domain/build/build_options.dart';
import 'package:apk_forge/domain/build/flutter_build.dart';
import 'package:apk_forge/domain/signing/keystore.dart';
import 'package:apk_forge/domain/signing/signing.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fakes.dart';

void main() {
  group('flutterBuildArguments', () {
    test('a universal release with every ABI', () {
      expect(flutterBuildArguments(const BuildOptions()), [
        'build',
        'apk',
        '--release',
        '--target-platform',
        'android-arm,android-arm64,android-x64',
      ]);
    });

    test('split per ABI for the ABIs chosen, in a fixed order', () {
      final options = const BuildOptions().copyWith(
        abis: {AndroidAbi.x8664, AndroidAbi.arm64V8a},
        packaging: ApkPackaging.splitPerAbi,
      );

      expect(flutterBuildArguments(options), [
        'build',
        'apk',
        '--release',
        '--target-platform',
        'android-arm64,android-x64',
        '--split-per-abi',
      ]);
    });

    test('one ABI never splits: the output would still be one APK', () {
      final options = const BuildOptions().copyWith(
        abis: {AndroidAbi.x8664},
        packaging: ApkPackaging.splitPerAbi,
      );

      expect(options.canSplit, isFalse);
      expect(options.effectivePackaging, ApkPackaging.universal);
      expect(
        flutterBuildArguments(options),
        isNot(contains('--split-per-abi')),
      );
      // The choice is kept for when more ABIs are selected again.
      expect(options.packaging, ApkPackaging.splitPerAbi);
      expect(
        options
            .copyWith(abis: {AndroidAbi.x8664, AndroidAbi.arm64V8a})
            .effectivePackaging,
        ApkPackaging.splitPerAbi,
      );
    });

    test('the output summary says how many APKs, and with what', () {
      const every = BuildOptions();
      final two = every.copyWith(abis: {AndroidAbi.arm64V8a, AndroidAbi.x8664});

      expect(every.outputSummary, 'One APK with every architecture.');
      expect(
        two.outputSummary,
        'One APK with the 2 architectures in Defaults.',
      );
      expect(
        two.copyWith(packaging: ApkPackaging.splitPerAbi).outputSummary,
        'One APK per architecture: 2 APKs.',
      );
      expect(
        every
            .copyWith(
              abis: {AndroidAbi.x8664},
              packaging: ApkPackaging.splitPerAbi,
            )
            .outputSummary,
        'One APK for x86_64. Split needs two or more architectures.',
      );
      expect(
        every.copyWith(abis: {}).outputSummary,
        'Choose an architecture in Defaults.',
      );
    });

    test('obfuscation adds the symbols folder', () {
      final options = const BuildOptions().copyWith(
        obfuscate: true,
        symbolsDir: ' /work/symbols ',
      );

      expect(
        flutterBuildArguments(options),
        containsAllInOrder(['--obfuscate', '--split-debug-info=/work/symbols']),
      );
    });

    test('a debug build never obfuscates, even if the switch was left on', () {
      final options = const BuildOptions().copyWith(
        mode: BuildMode.debug,
        obfuscate: true,
        symbolsDir: '/s',
      );
      final arguments = flutterBuildArguments(options);

      expect(arguments, contains('--debug'));
      expect(arguments, isNot(contains('--obfuscate')));
    });
  });

  group('buildProblems', () {
    final probe = FakeFileProbe(
      files: {'/work/app/pubspec.yaml', '/work/lib/pubspec.yaml'},
      directories: {'/work/app/android'},
    );

    test('none for a Flutter project with Android', () {
      expect(
        buildProblems(
          const BuildOptions(projectDir: '/work/app'),
          macHost,
          probe,
        ),
        isEmpty,
      );
    });

    test('names each missing piece', () {
      expect(buildProblems(const BuildOptions(), macHost, probe), [
        'Choose the Flutter project folder.',
      ]);
      expect(
        buildProblems(
          const BuildOptions(projectDir: '/work/empty'),
          macHost,
          probe,
        ).single,
        contains('no pubspec.yaml'),
      );
      expect(
        buildProblems(
          const BuildOptions(projectDir: '/work/lib'),
          macHost,
          probe,
        ).single,
        contains('no android/'),
      );
      expect(
        buildProblems(
          const BuildOptions(projectDir: '/work/app', abis: {}),
          macHost,
          probe,
        ),
        ['Choose at least one architecture in Defaults.'],
      );
      expect(
        buildProblems(
          const BuildOptions(projectDir: '/work/app', obfuscate: true),
          macHost,
          probe,
        ),
        ['Obfuscation needs a folder for the symbols.'],
      );
    });
  });

  group('signing', () {
    const request = SigningRequest(
      keystorePath: '/keys/release.jks',
      storePassword: 's3cret!',
      alias: 'upload',
      keyPassword: 'k3y-pass',
    );

    test('verify prints the certificates, and checks v4 with its .idsig; '
        'lineage prints the rotation', () {
      expect(apksignerVerifyArguments('/a b/app.apk'), [
        'verify',
        '--verbose',
        '--print-certs',
        '/a b/app.apk',
      ]);
      expect(
        apksignerVerifyArguments(
          '/a b/app.apk',
          v4SignatureFile: '/a b/app.apk.idsig',
        ),
        [
          'verify',
          '--verbose',
          '--print-certs',
          '--v4-signature-file',
          '/a b/app.apk.idsig',
          '/a b/app.apk',
        ],
      );
      expect(apksignerLineageArguments('/a b/app.apk'), [
        'lineage',
        '--in',
        '/a b/app.apk',
        '--print-certs',
      ]);
    });

    test('the key check reads both passwords from the environment', () {
      expect(keytoolCertreqArguments('/keys/release.jks', 'upload'), [
        '-J-Duser.language=en',
        '-J-Duser.country=US',
        '-certreq',
        '-keystore',
        '/keys/release.jks',
        '-alias',
        'upload',
        '-storepass:env',
        keystorePasswordVariable,
        '-keypass:env',
        keyPasswordVariable,
      ]);
    });

    test('the passwords travel in the environment, never in the arguments', () {
      final arguments = apksignerSignArguments(
        request,
        input: '/a.apk',
        output: '/a-signed.apk',
      );

      expect(arguments, [
        'sign',
        '--ks',
        '/keys/release.jks',
        '--ks-pass',
        'env:$keystorePasswordVariable',
        '--ks-key-alias',
        'upload',
        '--key-pass',
        'env:$keyPasswordVariable',
        '--out',
        '/a-signed.apk',
        '/a.apk',
      ]);
      expect(arguments.join(' '), isNot(contains('s3cret!')));
      expect(request.environment, {
        keystorePasswordVariable: 's3cret!',
        keyPasswordVariable: 'k3y-pass',
      });
    });

    test('a key that shares the keystore password sends no --key-pass', () {
      const shared = SigningRequest(
        keystorePath: '/k.jks',
        storePassword: 'p',
        alias: 'a',
      );

      expect(
        apksignerSignArguments(shared, input: 'i', output: 'o'),
        isNot(contains('--key-pass')),
      );
      expect(shared.environment.keys, [keystorePasswordVariable]);
    });

    test('only the schemes chosen are passed', () {
      const custom = SigningRequest(
        keystorePath: '/k.jks',
        storePassword: 'p',
        alias: 'a',
        schemes: SigningSchemes(v1: true, v2: true, v3: false, v4: false),
      );

      expect(
        apksignerSignArguments(custom, input: 'i', output: 'o'),
        containsAllInOrder([
          '--v1-signing-enabled', 'true', //
          '--v2-signing-enabled', 'true',
          '--v3-signing-enabled', 'false',
          '--v4-signing-enabled', 'false',
        ]),
      );
      expect(
        apksignerSignArguments(
          request,
          input: 'i',
          output: 'o',
        ).where((a) => a.contains('signing-enabled')),
        isEmpty,
      );
    });

    test('schemes: their label, their JSON, and what apksigner refuses', () {
      const chosen = SigningSchemes(v1: false, v2: true, v3: true, v4: false);

      expect(const SigningSchemes.automatic().label, 'Auto');
      expect(chosen.label, 'v2, v3');
      expect(
        const SigningSchemes(v1: false, v2: false, v3: false, v4: false).label,
        'none marked',
      );
      expect(SigningSchemes.fromJson(chosen.toJson()).label, 'v2, v3');
      expect(SigningSchemes.fromJson(null).isAutomatic, isTrue);

      // apksigner 36 writes an APK with no signature, and exits 0.
      expect(
        const SigningSchemes(v1: false, v2: false, v3: false).problem,
        'Mark v1, v2 or v3.',
      );
      // It throws: v4 signing requires at least v2 or v3.
      expect(
        const SigningSchemes(v1: true, v2: false, v3: false, v4: true).problem,
        'v4 needs v2 or v3.',
      );
      // A scheme left to apksigner: it signs with v2 and v3.
      expect(const SigningSchemes(v1: false).problem, isNull);
      expect(const SigningSchemes.automatic().problem, isNull);
      expect(chosen.problem, isNull);
    });

    test('a problem with the schemes in Defaults says where they are', () {
      expect(
        defaultSchemesProblem(
          const SigningSchemes(v1: false, v2: false, v3: false),
        ),
        'Signature schemes in Defaults: Mark v1, v2 or v3.',
      );
      expect(defaultSchemesProblem(const SigningSchemes.automatic()), isNull);
    });

    test(
      'keytool lists in English and reads the password from the environment',
      () {
        final arguments = keytoolListArguments('/k.jks');

        expect(arguments.take(2), [
          '-J-Duser.language=en',
          '-J-Duser.country=US',
        ]);
        expect(
          arguments,
          containsAllInOrder(['-storepass:env', keystorePasswordVariable]),
        );
      },
    );

    test('signedApkPath never overwrites the original', () {
      expect(
        signedApkPath('/out/app-release.apk', null, macHost),
        '/out/app-release-signed.apk',
      );
      expect(
        signedApkPath('/out/app-release.apk', '/signed', macHost),
        '/signed/app-release-signed.apk',
      );
      expect(
        signedApkPath('/out/app-signed.apk', null, macHost),
        '/out/app-signed-signed.apk',
      );
      // Only when the name would be the input itself does it number the copy.
      expect(
        signedApkPath('/out/app.apk', ' ', macHost),
        '/out/app-signed.apk',
      );
    });

    test('signedApkPath on Windows', () {
      const windows = Host(os: HostOs.windows, environment: {});

      expect(
        signedApkPath(r'C:\out\app.apk', r'D:\signed', windows),
        r'D:\signed\app-signed.apk',
      );
    });

    test('withDefaultOutputDir fills the folder only when none was chosen', () {
      expect(request.withDefaultOutputDir('/ci').outputDir, '/ci');
      expect(request.withDefaultOutputDir('/ci').secrets, request.secrets);

      const chosen = SigningRequest(
        keystorePath: '/k.jks',
        storePassword: 'p',
        alias: 'a',
        outputDir: '/signed',
      );
      expect(chosen.withDefaultOutputDir('/ci').outputDir, '/signed');
    });

    test('zipalign aligns to 16 KB pages when build-tools can', () {
      expect(zipalignArguments('/a.apk', supportsPageSize: true), [
        '-c',
        '-P',
        '16',
        '4',
        '/a.apk',
      ]);
      expect(
        zipalignArguments('/a.apk', output: '/b.apk', supportsPageSize: false),
        ['-f', '-p', '4', '/a.apk', '/b.apk'],
      );
    });
  });

  group('Command', () {
    test('displayLine quotes what a shell would split', () {
      const command = Command('/sdk/apksigner', [
        'sign',
        '--ks',
        '/My Keys/r.jks',
        "it's",
      ]);

      expect(
        command.displayLine,
        "/sdk/apksigner sign --ks '/My Keys/r.jks' 'it'\\''s'",
      );
    });

    test('maskSecrets hides every occurrence and ignores empty secrets', () {
      expect(
        maskSecrets('pass=abc and abc', ['abc', '']),
        'pass=•••• and ••••',
      );
    });
  });
}
