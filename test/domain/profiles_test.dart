import 'dart:convert';

import 'package:apk_forge/core/system/host.dart';
import 'package:apk_forge/core/zip/zip_directory.dart';
import 'package:apk_forge/domain/analysis/apk_report.dart';
import 'package:apk_forge/domain/analysis/badging.dart';
import 'package:apk_forge/domain/analysis/signature.dart';
import 'package:apk_forge/domain/build/build_options.dart';
import 'package:apk_forge/domain/profiles/key_properties.dart';
import 'package:apk_forge/domain/profiles/profile.dart';
import 'package:apk_forge/domain/profiles/profile_plan.dart';
import 'package:apk_forge/domain/profiles/profile_run.dart';
import 'package:apk_forge/domain/signing/signing.dart';
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

/// A universal Flutter APK with an engine for each of [abis].
ApkContents _flutter(List<String> abis, {List<String> pluginOnly = const []}) =>
    _contents([
      'classes.dex',
      for (final abi in abis) ...[
        'lib/$abi/libapp.so',
        'lib/$abi/libflutter.so',
      ],
      for (final abi in pluginOnly) 'lib/$abi/libplugin.so',
    ]);

final _release = parseBadging(fixture('aapt2_badging_release.txt'));
final _unsigned = parseApksignerVerify(
  fixture('apksigner_verify_unsigned.txt'),
);
final _signed = parseApksignerVerify(fixture('apksigner_verify_test_key.txt'));

ApkReport _input({
  String path = '/ci/app-release.apk',
  ApkContents? contents,
  Badging? badging,
  SignatureReport? signature,
}) => ApkReport(
  path: path,
  sizeBytes: 1,
  md5: 'm',
  sha256: 's',
  contents: contents ?? _flutter(['arm64-v8a', 'armeabi-v7a', 'x86_64']),
  badging: badging ?? _release,
  signature: signature ?? _unsigned,
);

ProfileTarget _target(
  String name, {
  AndroidAbi? abi = AndroidAbi.arm64V8a,
  String key = '/keys/vendor/key.properties',
  String? folder,
  SigningSchemes? schemes,
}) => ProfileTarget(
  id: name.toLowerCase(),
  name: name,
  abi: abi,
  keyProperties: key,
  schemes: schemes,
  outputDir: folder ?? '/out/${name.toLowerCase()}',
);

final _date = DateTime(2026, 10, 18, 11, 52);

ProfileRunPlan _plan(
  List<ProfileTarget> targets, {
  List<ApkReport>? inputs,
  InputChecks input = const InputChecks(),
  String pattern = '{name}-{target}',
  SigningSchemes defaultSchemes = const SigningSchemes.automatic(),
  Host host = macHost,
}) => planProfileRun(
  SigningProfile(
    id: 'p',
    name: 'Release',
    input: input,
    targets: targets,
    fileNamePattern: pattern,
  ),
  inputs ?? [_input()],
  defaultSchemes: defaultSchemes,
  host: host,
  date: _date,
);

void main() {
  group('key.properties', () {
    test('reads the file a Flutter project keeps in android/', () {
      final keys = parseKeyProperties(
        'storePassword=store secret\n'
        'keyPassword=key secret\n'
        'keyAlias=upload\n'
        'storeFile=../upload-keystore.jks\n',
      );

      expect(keys.storeFile, '../upload-keystore.jks');
      expect(keys.keyAlias, 'upload');
      expect(keys.storePassword, 'store secret');
      expect(keys.keyPassword, 'key secret');
      expect(keys.missing, isEmpty);
      expect(keys.secrets, ['store secret', 'key secret']);
    });

    test(
      'Java properties: comments, separators, escapes and continuations',
      () {
        final values = parseJavaProperties(
          '# a comment\n'
          '! another\n'
          '   keyAlias : upload\n'
          'storeFile C:\\\\keys\\\\release.jks\n'
          r'storePassword=a\=b\:c\u0041'
          '\n'
          'keyPassword=first \\\n'
          '    second\r\n'
          'trailing=kept   \n',
        );

        expect(values['keyAlias'], 'upload');
        expect(values['storeFile'], r'C:\keys\release.jks');
        expect(values['storePassword'], 'a=b:cA');
        expect(values['keyPassword'], 'first second');
        // Java keeps a value's trailing spaces, and so does Gradle.
        expect(values['trailing'], 'kept   ');
        expect(values.containsKey('# a comment'), isFalse);
      },
    );

    test('says which fields are missing, and never prints a password', () {
      final keys = parseKeyProperties(
        'storeFile=k.jks\nstorePassword=s3cret\n',
      );

      expect(keys.missing, ['keyAlias', 'keyPassword']);
      expect('$keys', isNot(contains('s3cret')));
      expect(parseKeyProperties('').missing, hasLength(4));
    });

    test('the editor\'s summary: where, which alias, what is missing', () {
      final summary = summarizeKeyProperties(
        '/keys/vendor/key.properties',
        'storeFile=vendor.jks\nkeyAlias=vendor\nstorePassword=s3cret\n',
        macHost,
        (path) => path == '/keys/vendor/vendor.jks',
      );

      expect(summary.keystorePath, '/keys/vendor/vendor.jks');
      expect(summary.keystoreExists, isTrue);
      expect(summary.alias, 'vendor');
      expect(summary.hasStorePassword, isTrue);
      expect(summary.hasKeyPassword, isFalse);
      expect(summary.problems, ['It has no keyPassword.']);

      final noKeystore = summarizeKeyProperties(
        '/keys/key.properties',
        'storeFile=gone.jks\nkeyAlias=a\nstorePassword=s\nkeyPassword=k\n',
        macHost,
        (_) => false,
      );
      expect(noKeystore.problems, [
        'The keystore /keys/gone.jks does not exist.',
      ]);
    });

    test('a relative storeFile resolves as Gradle resolves it', () {
      // Inside a Flutter project's android/: from android/app/.
      expect(
        resolveStoreFile(
          '/work/app/android/key.properties',
          '../upload.jks',
          macHost,
        ),
        '/work/app/android/upload.jks',
      );
      expect(
        resolveStoreFile(
          '/work/app/android/key.properties',
          'upload.jks',
          macHost,
        ),
        '/work/app/android/app/upload.jks',
      );
      // Anywhere else: from the file's own folder.
      expect(
        resolveStoreFile('/keys/vendor/key.properties', 'vendor.jks', macHost),
        '/keys/vendor/vendor.jks',
      );
      expect(
        resolveStoreFile('/keys/key.properties', '/abs/release.jks', macHost),
        '/abs/release.jks',
      );
      const windows = Host(os: HostOs.windows, environment: {});
      expect(
        resolveStoreFile(r'C:\keys\key.properties', 'release.jks', windows),
        r'C:\keys\release.jks',
      );
    });
  });

  group('profile', () {
    test('round-trips through JSON with paths and choices only', () {
      final profile = SigningProfile(
        id: 'p1',
        name: 'Release',
        input: const InputChecks(
          packageName: 'com.example.app',
          mustBeUnsigned: true,
        ),
        targets: [
          _target(
            'Phone',
            schemes: const SigningSchemes(v1: false, v2: true, v3: true),
          ),
          _target('Emulator', abi: null),
        ],
        fileNamePattern: '{name}-{target}-{versionName}',
        afterRun: AfterRun.nothing,
      );

      final json = jsonDecode(jsonEncode(profile.toJson()));
      final back = SigningProfile.fromJson(json as Map<String, Object?>);

      expect(back.toJson(), profile.toJson());
      expect(back.targets.first.abi, AndroidAbi.arm64V8a);
      expect(back.targets.last.abi, isNull);
      expect(back.targets.first.schemes?.v1, isFalse);
      // No schemes of its own: it follows Defaults.
      expect(back.targets.last.schemes, isNull);
      expect(back.input.packageName, 'com.example.app');
      expect(back.keyFiles, ['/keys/vendor/key.properties']);
    });

    test('exported, imported, and what to pick again on another machine', () {
      final profile = SigningProfile(
        id: 'p1',
        name: 'Release',
        targets: [_target('Phone'), _target('Tablet')],
      );

      final text = exportProfile(profile);
      final back = importProfile(text);

      expect(back.toJson(), profile.toJson());
      expect(text, contains('"format": "apk-forge-profile"'));
      expect(
        missingProfilePaths(back, FakeFileProbe(directories: {'/out/phone'})),
        ['/keys/vendor/key.properties', '/out/tablet'],
      );
      expect(() => importProfile('not json'), throwsFormatException);
      expect(() => importProfile('{"format": "other"}'), throwsFormatException);
    });

    test('a blank package name takes any package', () {
      expect(
        InputChecks.fromJson(const {'packageName': '  '}).packageName,
        isNull,
      );
    });

    test('the file name pattern fills its tokens', () {
      expect(
        profileFileName(
          '{name}-{target}-{abi}-{versionName}-{versionCode}-{date}',
          name: 'app-release',
          target: 'Phone',
          abi: 'arm64-v8a',
          versionName: '1.4.0',
          versionCode: '140',
          date: _date,
        ),
        'app-release-Phone-arm64-v8a-1.4.0-140-20261018.apk',
      );
    });

    test('a file name never holds a path separator', () {
      expect(
        profileFileName(
          '{target}.apk',
          name: 'x',
          target: 'Kiosk/Lobby: 2',
          abi: 'universal',
          date: _date,
        ),
        'Kiosk_Lobby_ 2.apk',
      );
    });

    test('an empty pattern or an unknown token is a problem', () {
      expect(fileNamePatternProblems(' '), isNotEmpty);
      expect(
        fileNamePatternProblems('{name}-{device}').single,
        contains('{device}'),
      );
      expect(
        fileNamePatternProblems(SigningProfile.defaultFileNamePattern),
        isEmpty,
      );
    });
  });

  group('planProfileRun', () {
    test('one job per target, cut to its ABI, named by the pattern', () {
      final plan = _plan([
        _target('Phone'),
        _target('Kiosk', abi: AndroidAbi.armeabiV7a),
      ], pattern: '{name}-{target}-{versionName}');

      expect(plan.canRun, isTrue);
      expect(plan.problems, isEmpty);
      expect(plan.jobs.map((job) => job.abi), [
        AndroidAbi.arm64V8a,
        AndroidAbi.armeabiV7a,
      ]);
      expect(plan.jobs.map((job) => job.outputs.single.path), [
        '/out/phone/app-release-Phone-1.0.0.apk',
        '/out/kiosk/app-release-Kiosk-1.0.0.apk',
      ]);
      expect(plan.outputCount, 2);
    });

    test('targets that share the ABI, the key and the schemes sign once', () {
      final plan = _plan([
        _target('Phone'),
        _target('Tablet'),
        _target('Other key', key: '/keys/release/key.properties'),
        _target('Other schemes', schemes: const SigningSchemes(v1: true)),
      ]);

      expect(plan.jobs, hasLength(3));
      expect(plan.jobs.first.outputs.map((output) => output.target.name), [
        'Phone',
        'Tablet',
      ]);
      expect(plan.outputCount, 4);
    });

    test('a target without schemes of its own signs with Defaults\'', () {
      const defaults = SigningSchemes(v1: false, v2: true, v3: true);
      final plan = _plan([
        _target('Phone'),
        _target('Same as Defaults', schemes: defaults),
        _target('Auto', schemes: const SigningSchemes.automatic()),
      ], defaultSchemes: defaults);

      expect(plan.jobs, hasLength(2));
      expect(plan.jobs.first.schemes.label, 'v2, v3');
      expect(plan.jobs.first.outputs.map((output) => output.target.name), [
        'Phone',
        'Same as Defaults',
      ]);
      expect(plan.jobs.last.schemes.isAutomatic, isTrue);
    });

    test('schemes apksigner cannot sign with are a problem', () {
      final followsDefaults = _plan([
        _target('Phone'),
      ], defaultSchemes: const SigningSchemes(v1: false, v2: false, v3: false));
      final own = _plan([
        _target(
          'Phone',
          schemes: const SigningSchemes(
            v1: true,
            v2: false,
            v3: false,
            v4: true,
          ),
        ),
      ], defaultSchemes: const SigningSchemes(v1: false));

      expect(followsDefaults.problems, [
        'Signature schemes in Defaults: Mark v1, v2 or v3.',
      ]);
      expect(own.problems, ['Phone: v4 needs v2 or v3.']);
      expect(own.canRun, isFalse);
    });

    test('a target the input cannot serve is skipped, with the reason', () {
      final plan = _plan(
        [
          _target('Phone'),
          _target('Emulator', abi: AndroidAbi.x8664),
          _target('Kiosk', abi: AndroidAbi.armeabiV7a),
        ],
        inputs: [
          _input(contents: _flutter(['arm64-v8a'], pluginOnly: ['x86_64'])),
        ],
      );

      expect(
        plan.skipped.map((skip) => '${skip.target.name}: ${skip.reason}'),
        [
          'Emulator: No Flutter engine for x86_64',
          'Kiosk: No native code for armeabi-v7a',
        ],
      );
      expect(plan.jobs.single.outputs.single.target.name, 'Phone');
      expect(plan.canRun, isTrue);
    });

    test('nothing to cut: no native code, one ABI, or universal', () {
      final noNative = _plan(
        [_target('Phone'), _target('Emulator', abi: AndroidAbi.x8664)],
        inputs: [
          _input(contents: _contents(['classes.dex'])),
        ],
      );
      expect(noNative.skipped, isEmpty);
      expect(noNative.jobs.single.abi, isNull);

      final oneAbi = _plan(
        [_target('Phone')],
        inputs: [
          _input(contents: _flutter(['arm64-v8a'])),
        ],
      );
      expect(oneAbi.jobs.single.abi, isNull);

      final universal = _plan([_target('All', abi: null)]);
      expect(universal.jobs.single.abi, isNull);
      expect(
        universal.jobs.single.outputs.single.path,
        '/out/all/app-release-All.apk',
      );
    });

    test('the input checks stop the run before anything is signed', () {
      final wrongPackage = _plan([
        _target('Phone'),
      ], input: const InputChecks(packageName: 'com.example.other'));
      expect(wrongPackage.canRun, isFalse);
      expect(
        wrongPackage.problems.single,
        'app-release.apk is io.example.sample_app, not com.example.other.',
      );

      final alreadySigned = _plan(
        [_target('Phone')],
        inputs: [_input(signature: _signed)],
        input: const InputChecks(mustBeUnsigned: true),
      );
      expect(
        alreadySigned.problems.single,
        contains('already signed by CN=APK Forge Test'),
      );

      final unsigned = _plan(
        [_target('Phone')],
        input: const InputChecks(
          packageName: 'io.example.sample_app',
          mustBeUnsigned: true,
        ),
      );
      expect(unsigned.problems, isEmpty);
    });

    test('a package that could not be read cannot be checked', () {
      final plan = planProfileRun(
        SigningProfile(
          id: 'p',
          name: 'Release',
          input: const InputChecks(packageName: 'com.example.app'),
          targets: [_target('Phone')],
        ),
        defaultSchemes: const SigningSchemes.automatic(),
        [
          ApkReport(
            path: '/ci/app.apk',
            sizeBytes: 1,
            md5: 'm',
            sha256: 's',
            contents: _flutter(['arm64-v8a']),
            badgingError: 'aapt2 was not found.',
          ),
        ],
        host: macHost,
        date: _date,
      );

      expect(plan.problems.single, contains('aapt2 was not found.'));
    });

    test('two targets writing one file, or over the input, is a problem', () {
      final collide = _plan([
        _target('Phone', folder: '/out'),
        _target('Tablet', folder: '/out'),
      ], pattern: '{name}');
      expect(
        collide.problems.single,
        contains('Phone and Tablet would both write /out/app-release.apk'),
      );

      final overInput = _plan([
        _target('Phone', abi: null, folder: '/ci'),
      ], pattern: '{name}');
      expect(overInput.problems.single, contains('would write over its input'));
    });

    test('a target without a key file or a folder, no target, no input', () {
      final plan = _plan([
        const ProfileTarget(id: 't', name: 'Phone'),
      ], inputs: const []);

      expect(plan.problems, [
        'Pick an APK to run the profile on.',
        'Phone: choose its key.properties file.',
        'Phone: choose its output folder.',
      ]);
      expect(_plan(const []).problems, contains('The profile has no targets.'));
    });

    test('several inputs: each one through every target', () {
      final plan = _plan(
        [_target('Phone')],
        inputs: [
          _input(),
          _input(path: '/ci/app-beta.apk'),
        ],
      );

      expect(plan.jobs.map((job) => job.outputs.single.path), [
        '/out/phone/app-release-Phone.apk',
        '/out/phone/app-beta-Phone.apk',
      ]);
    });
  });

  group('run record', () {
    test('round-trips through JSON and sums up the results', () {
      final record = ProfileRunRecord(
        profileId: 'p1',
        profileName: 'Release',
        startedAt: _date,
        finishedAt: _date.add(const Duration(seconds: 9)),
        inputs: const [
          RunInput(
            name: 'app-release.apk',
            sha256: 'abcd',
            packageName: 'com.example.app',
            versionName: '1.4.0',
            versionCode: '140',
          ),
        ],
        results: const [
          TargetResult(
            target: 'Phone',
            input: 'app-release.apk',
            status: TargetStatus.signed,
            outputPath: '/out/phone/app-Phone.apk',
            sizeBytes: 14800000,
            signerSha256: 'b34c',
          ),
          TargetResult(
            target: 'Tablet',
            input: 'app-release.apk',
            status: TargetStatus.failed,
            reason: '/out/tablet is not writable',
          ),
          TargetResult(
            target: 'Emulator',
            input: 'app-release.apk',
            status: TargetStatus.skipped,
            reason: 'No Flutter engine for x86_64',
          ),
        ],
      );

      final back = ProfileRunRecord.fromJson(
        jsonDecode(jsonEncode(record.toJson())) as Map<String, Object?>,
      );

      expect(back.toJson(), record.toJson());
      expect(back.summary, '1 signed · 1 failed · 1 skipped');
      expect(back.finishedAt.difference(back.startedAt).inSeconds, 9);
    });
  });
}
