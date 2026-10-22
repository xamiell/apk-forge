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
import 'package:apk_forge/domain/profiles/run_report.dart';
import 'package:apk_forge/domain/profiles/target_problems.dart';
import 'package:apk_forge/domain/signing/signing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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
  FileProbe? probe,
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
  // Every target's key file and folder exist unless the test says otherwise.
  probe:
      probe ??
      FakeFileProbe(
        files: {for (final t in targets) t.keyProperties},
        directories: {for (final t in targets) t.outputDir},
      ),
  date: _date,
);

/// A run with every detail #14 records: one target signed, one failed, one
/// skipped.
ProfileRunRecord _run() => ProfileRunRecord(
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
      minSdk: 24,
      unsigned: true,
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
      setup: TargetSetup(
        abi: 'arm64-v8a',
        cut: true,
        keyProperties: '/keys/key.properties',
        keyAlias: 'upload',
        schemes: SigningSchemes(v1: true, v2: true, v3: true, v4: true),
        schemesFromDefaults: false,
      ),
      signerDistinguishedName: 'CN=APK Forge Test, O=Example, C=US',
      verifiedSchemes: {
        'v1': false,
        'v2': true,
        'v3': true,
        'v3.1': false,
        'v4': true,
      },
      hasJarSignature: true,
      outputSha256: 'ef56',
    ),
    TargetResult(
      target: 'Tablet',
      input: 'app-release.apk',
      status: TargetStatus.failed,
      reason: '/out/tablet is not writable',
      setup: TargetSetup(
        abi: 'arm64-v8a',
        cut: true,
        keyProperties: '/keys/key.properties',
        keyAlias: 'upload',
        schemes: SigningSchemes(v1: true, v2: true, v3: true, v4: true),
        schemesFromDefaults: false,
        copiedFrom: 'Phone',
      ),
    ),
    TargetResult(
      target: 'Emulator',
      input: 'app-release.apk',
      status: TargetStatus.skipped,
      reason: 'No Flutter engine for x86_64',
      setup: TargetSetup(
        abi: 'x86_64',
        cut: false,
        keyProperties: '/keys/other/key.properties',
        schemes: SigningSchemes.automatic(),
        schemesFromDefaults: true,
      ),
    ),
  ],
  fileNamePattern: '{name}-{target}',
  inputChecks: const InputChecks(
    packageName: 'com.example.app',
    mustBeUnsigned: true,
  ),
  buildToolsVersion: '36.0.0',
);

/// A run as it was saved before #14.
Map<String, Object?> _oldRun() => {
  'profileId': 'p1',
  'profileName': 'Release',
  'startedAt': '2026-10-19T10:00:00.000',
  'finishedAt': '2026-10-19T10:00:42.000',
  'inputs': [
    {
      'name': 'app-release.apk',
      'sha256': 'ab12',
      'packageName': 'com.example.app',
      'versionName': '1.2.0',
      'versionCode': '12',
    },
  ],
  'results': [
    {
      'target': 'Phone',
      'input': 'app-release.apk',
      'status': 'signed',
      'outputPath': '/w/phone/app-release-Phone.apk',
      'sizeBytes': 1024,
      'signerSha256': 'cd34',
      'reason': null,
    },
  ],
  'cancelled': false,
};

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
      expect(summary.missing, ['keyPassword']);

      final noKeystore = summarizeKeyProperties(
        '/keys/key.properties',
        'storeFile=gone.jks\nkeyAlias=a\nstorePassword=s\nkeyPassword=k\n',
        macHost,
        (_) => false,
      );
      expect(noKeystore.keystorePath, '/keys/gone.jks');
      expect(noKeystore.keystoreExists, isFalse);
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

    test('exported and imported, as it was', () {
      final profile = SigningProfile(
        id: 'p1',
        name: 'Release',
        targets: [_target('Phone'), _target('Tablet')],
      );

      final text = exportProfile(profile);
      final back = importProfile(text);

      expect(back.toJson(), profile.toJson());
      expect(text, contains('"format": "apk-forge-profile"'));
      expect(() => importProfile('not json'), throwsFormatException);
      expect(() => importProfile('{"format": "other"}'), throwsFormatException);
    });

    test('a name already taken gets a number, ignoring case', () {
      expect(uniqueProfileName('Release', const []), 'Release');
      expect(uniqueProfileName('Release', ['Release']), 'Release 2');
      expect(
        uniqueProfileName('Release', ['release', 'Release 2']),
        'Release 3',
      );
      expect(
        uniqueProfileName('Release copy', ['Release', 'Release copy']),
        'Release copy 2',
      );
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

  group('targetProblems', () {
    const key = '/keys/vendor/key.properties';
    final probe = FakeFileProbe(files: {key}, directories: {'/out/phone'});
    const summary = KeyFileSummary(
      path: key,
      storeFile: 'vendor.jks',
      keystorePath: '/keys/vendor/vendor.jks',
      keystoreExists: true,
      alias: 'vendor',
    );
    List<TargetProblem> problems(
      ProfileTarget target, {
      KeyFileSummary? keySummary = summary,
    }) => targetProblems(target, probe: probe, keySummary: keySummary);

    test('a target with a key and a folder that exist has none', () {
      expect(problems(_target('Phone', folder: '/out/phone')), isEmpty);
    });

    test('no key, or a key file that does not exist', () {
      expect(problems(_target('Phone', key: '', folder: '/out/phone')), [
        const TargetProblem(TargetField.key, 'Choose its key.properties file.'),
      ]);
      expect(
        problems(
          _target('Phone', key: '/gone/key.properties', folder: '/out/phone'),
        ),
        [
          const TargetProblem(
            TargetField.key,
            'Its key.properties does not exist on this machine.',
            missingPath: '/gone/key.properties',
          ),
        ],
      );
    });

    test('a key file with fields missing, or a keystore that is gone', () {
      final phone = _target('Phone', folder: '/out/phone');

      expect(
        problems(
          phone,
          keySummary: const KeyFileSummary(
            path: key,
            missing: ['keyAlias', 'keyPassword'],
          ),
        ).map((p) => p.message),
        ['Its key.properties has no keyAlias, keyPassword.'],
      );
      expect(
        problems(
          phone,
          keySummary: const KeyFileSummary(
            path: key,
            storeFile: 'gone.jks',
            keystorePath: '/keys/vendor/gone.jks',
          ),
        ).map((p) => p.message),
        ['Its keystore does not exist: /keys/vendor/gone.jks'],
      );
      expect(
        problems(
          phone,
          keySummary: const KeyFileSummary(
            path: key,
            error: 'Permission denied',
          ),
        ).map((p) => p.message),
        ["Its key.properties can't be read: Permission denied"],
      );
      // Not read yet: only that the file exists.
      expect(problems(phone, keySummary: null), isEmpty);
    });

    test('schemes apksigner cannot sign with', () {
      expect(
        problems(
          _target(
            'Phone',
            folder: '/out/phone',
            schemes: const SigningSchemes(v1: false, v2: false, v3: false),
          ),
        ),
        [const TargetProblem(TargetField.schemes, 'Mark v1, v2 or v3.')],
      );
    });

    test('no folder, or a folder that does not exist', () {
      expect(problems(_target('Phone', folder: '')), [
        const TargetProblem(
          TargetField.outputFolder,
          'Choose its output folder.',
        ),
      ]);
      expect(problems(_target('Kiosk')), [
        const TargetProblem(
          TargetField.outputFolder,
          'Its output folder does not exist on this machine.',
          missingPath: '/out/kiosk',
        ),
      ]);
    });

    test('in the editor\'s order, and with the target\'s name elsewhere', () {
      final target = _target('Kiosk', key: '');
      final all = problems(target);

      expect(all.map((p) => p.field), [
        TargetField.key,
        TargetField.outputFolder,
      ]);
      expect(all.map((p) => describeTargetProblem(target, p)), [
        'Kiosk: Choose its key.properties file.',
        'Kiosk: Its output folder does not exist on this machine.',
      ]);
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

    test('{abi} is the ABI kept, or universal for a target that keeps all', () {
      final plan = _plan([
        _target('Phone'),
        _target('All', abi: null),
      ], pattern: '{target}-{abi}');

      expect(
        [
          for (final job in plan.jobs)
            for (final output in job.outputs) p.basename(output.path),
        ],
        ['Phone-arm64-v8a.apk', 'All-universal.apk'],
      );
      expect(_target('All', abi: null).abiName, 'universal');
      expect(_target('Phone').abiName, 'arm64-v8a');
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
        probe: FakeFileProbe(
          files: {'/keys/vendor/key.properties'},
          directories: {'/out/phone'},
        ),
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
        'Phone: Choose its key.properties file.',
        'Phone: Choose its output folder.',
      ]);
      expect(_plan(const []).problems, contains('The profile has no targets.'));
    });

    test('a key file or folder missing on this machine stops the run', () {
      final plan = _plan(
        [
          _target('Phone', key: '/elsewhere/key.properties'),
          _target('Tablet', abi: AndroidAbi.armeabiV7a),
        ],
        probe: FakeFileProbe(
          files: {'/keys/vendor/key.properties'},
          directories: {'/out/phone'},
        ),
      );

      expect(plan.problems, [
        'Phone: Its key.properties does not exist on this machine.',
        'Tablet: Its output folder does not exist on this machine.',
      ]);
      expect(plan.canRun, isFalse);
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
      final record = _run();

      final back = ProfileRunRecord.fromJson(
        jsonDecode(jsonEncode(record.toJson())) as Map<String, Object?>,
      );

      expect(back.toJson(), record.toJson());
      expect(back.summary, '1 signed · 1 failed · 1 skipped');
      expect(back.finishedAt.difference(back.startedAt).inSeconds, 9);
      expect(back.results.first.setup!.schemes.v4, isTrue);
      expect(back.results.first.verifiedSchemes!.keys, [
        'v1',
        'v2',
        'v3',
        'v3.1',
        'v4',
      ]);
      expect(back.results[1].setup!.copiedFrom, 'Phone');
      expect(back.inputChecks!.packageName, 'com.example.app');
    });

    test('a record saved before the details were kept still loads; what it '
        'lacks stays null, never guessed', () {
      final old = ProfileRunRecord.fromJson(_oldRun());

      final result = old.results.single;
      expect(result.signerSha256, 'cd34');
      expect(result.setup, isNull);
      expect(result.signerDistinguishedName, isNull);
      expect(result.verifiedSchemes, isNull);
      expect(result.hasJarSignature, isNull);
      expect(result.outputSha256, isNull);
      expect(old.inputs.single.version, '1.2.0 (12)');
      expect(old.inputs.single.minSdk, isNull);
      expect(old.inputs.single.unsigned, isNull);
      expect(old.fileNamePattern, isNull);
      expect(old.inputChecks, isNull);
      expect(old.buildToolsVersion, isNull);
      expect(old.outcome, RunOutcome.allSigned);
    });

    test('the outcome of a run as a whole, and its targets', () {
      ProfileRunRecord run(
        List<TargetStatus> statuses, {
        bool cancelled = false,
      }) => ProfileRunRecord(
        profileId: 'p1',
        profileName: 'Release',
        startedAt: _date,
        finishedAt: _date,
        inputs: const [],
        results: [
          for (final (index, status) in statuses.indexed)
            TargetResult(target: 'T$index', input: 'a.apk', status: status),
        ],
        cancelled: cancelled,
      );
      const signed = TargetStatus.signed;
      const failed = TargetStatus.failed;
      const skipped = TargetStatus.skipped;

      expect(run([signed, signed]).outcome, RunOutcome.allSigned);
      expect(run([signed, skipped]).outcome, RunOutcome.someSkipped);
      expect(run([signed, failed, skipped]).outcome, RunOutcome.someFailed);
      expect(run([failed, skipped]).outcome, RunOutcome.failed);
      expect(run([skipped]).outcome, RunOutcome.nothingSigned);
      expect(
        run([signed, skipped], cancelled: true).outcome,
        RunOutcome.cancelled,
      );
      expect(run([signed, failed]).targets, ['T0', 'T1']);
    });

    test('the versions a run signed, each once', () {
      final run = ProfileRunRecord.fromJson({
        ..._oldRun(),
        'inputs': [
          {
            'name': 'app-release.apk',
            'versionName': '1.2.0',
            'versionCode': '12',
          },
          {
            'name': 'app-arm64.apk',
            'versionName': '1.2.0',
            'versionCode': '12',
          },
          {'name': 'unread.apk'},
        ],
      });

      expect(run.versions, ['1.2.0 (12)', 'unread.apk']);
    });

    test('an input remembers its minSdk, and whether it was unsigned when '
        'that could be checked', () {
      final unsigned = RunInput.fromReport(_input(), name: 'app-release.apk');
      expect(unsigned.unsigned, isTrue);
      expect(unsigned.minSdk, 24);
      expect(unsigned.version, '1.0.0 (2001)');
      expect(unsigned.packageName, 'io.example.sample_app');

      expect(
        RunInput.fromReport(_input(signature: _signed), name: 'a.apk').unsigned,
        isFalse,
      );
      // A v1 signature that apksigner didn't report is still a signature.
      final jarOnly = _input(
        contents: _contents(['META-INF/MANIFEST.MF', 'META-INF/CERT.RSA']),
      );
      expect(RunInput.fromReport(jarOnly, name: 'a.apk').unsigned, isFalse);

      const unread = ApkReport(
        path: '/ci/a.apk',
        sizeBytes: 1,
        md5: 'm',
        sha256: 's',
        contents: ApkContents(),
        signatureError: 'apksigner was not found',
      );
      expect(RunInput.fromReport(unread, name: 'a.apk').unsigned, isNull);
    });
  });

  group('run report', () {
    List<String> lines(List<ReportLine> lines) => [
      for (final line in lines) '$line',
    ];

    test('the run, its input, then how each target was signed', () {
      final report = runReport(_run());

      expect(report.title, 'Release, 2026-10-18 11:52');
      expect(lines(report.run), [
        'Outcome: Some failed',
        'Results: 1 signed · 1 failed · 1 skipped',
        'Started: 2026-10-18 11:52',
        'Took: 9 s',
        'Profile: Release',
        'Build-tools: 36.0.0',
        'File names: {name}-{target}',
        'Input checks: Package com.example.app; must be unsigned',
      ]);
      expect(lines(report.inputs.single.lines), [
        'Package: com.example.app',
        'Version: 1.4.0 (140)',
        'minSdk: 24',
        'Signature: None: it was unsigned',
        'SHA-256: abcd',
      ]);
      final [phone, tablet, emulator] = report.targets;
      expect(phone.title, 'Phone');
      expect(lines(phone.lines), [
        'ABI: arm64-v8a: cut from the input',
        'Key alias: upload',
        'key.properties: /keys/key.properties',
        'Schemes asked: v1, v2, v3, v4 (its own)',
        'Schemes verified: v2, v3, v4, v1 present',
        'Signer: CN=APK Forge Test, O=Example, C=US',
        'Signer SHA-256: B3:4C',
        'Output: /out/phone/app-Phone.apk',
        'Size: 14.1 MB',
        'Output SHA-256: ef56',
      ]);
      expect(lines(tablet.lines), [
        'ABI: arm64-v8a',
        'Key alias: upload',
        'key.properties: /keys/key.properties',
        'Schemes asked: v1, v2, v3, v4 (its own)',
        'Signing: Shared with Phone: signed once, copied to each folder',
        'Reason: /out/tablet is not writable',
      ]);
      expect(lines(emulator.lines), [
        'ABI: x86_64',
        'Key alias: Not opened',
        'key.properties: /keys/other/key.properties',
        'Schemes asked: Auto, apksigner\'s choice by minSdk (from Defaults)',
        'Reason: No Flutter engine for x86_64',
      ]);
    });

    test('a record saved before the details says "Not recorded" and '
        'guesses nothing from the profile', () {
      final report = runReport(ProfileRunRecord.fromJson(_oldRun()));

      expect(lines(report.run).skip(5), [
        'Build-tools: Not recorded',
        'File names: Not recorded',
        'Input checks: Not recorded',
      ]);
      expect(lines(report.inputs.single.lines), [
        'Package: com.example.app',
        'Version: 1.2.0 (12)',
        'minSdk: Not recorded',
        'Signature: Not recorded',
        'SHA-256: ab12',
      ]);
      expect(lines(report.targets.single.lines), [
        'ABI: Not recorded',
        'Key alias: Not recorded',
        'key.properties: Not recorded',
        'Schemes asked: Not recorded',
        'Schemes verified: Not recorded',
        'Signer: Not recorded',
        'Signer SHA-256: CD:34',
        'Output: /w/phone/app-release-Phone.apk',
        'Size: 1.0 KB',
        'Output SHA-256: Not recorded',
      ]);
    });

    test('several inputs: each target says which one it was', () {
      final run = ProfileRunRecord.fromJson({
        ..._oldRun(),
        'inputs': [
          {'name': 'app-release.apk', 'sha256': 'ab12'},
          {'name': 'app-beta.apk', 'sha256': 'cd34'},
        ],
      });

      expect(runReport(run).targets.single.title, 'Phone · app-release.apk');
    });

    test('the text says what the screen shows, and the file is named after '
        'the run', () {
      final report = runReport(_run());

      final text = runReportText(report);

      expect(text, startsWith('APK Forge run: Release, 2026-10-18 11:52\n'));
      expect(text, contains('\nOutcome       Some failed\n'));
      expect(text, contains('\nTarget Phone: Signed\n'));
      expect(
        text,
        contains('\n  Schemes asked     v1, v2, v3, v4 (its own)\n'),
      );
      expect(text, contains('\nInput app-release.apk\n'));
      for (final line in [
        ...report.run,
        for (final input in report.inputs) ...input.lines,
        for (final target in report.targets) ...target.lines,
      ]) {
        expect(text, contains(' ${line.value}\n'));
      }
      expect(runReportFileName(_run()), 'Release run 2026-10-18 1152.txt');
      final renamed = ProfileRunRecord.fromJson({
        ..._run().toJson(),
        'profileName': 'Release 1/2',
      });
      expect(runReportFileName(renamed), 'Release 1_2 run 2026-10-18 1152.txt');
    });
  });
}
