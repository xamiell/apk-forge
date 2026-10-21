import 'package:apk_forge/domain/build/build_options.dart';
import 'package:apk_forge/domain/profiles/profile.dart';
import 'package:apk_forge/domain/profiles/profile_run.dart';
import 'package:apk_forge/state/forms.dart';
import 'package:apk_forge/state/profiles.dart';
import 'package:apk_forge/state/providers.dart';
import 'package:apk_forge/state/toolchain_notifier.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every setting as this version saves it. A field renamed on one side only
/// (read or write) loses what users saved, and these tests fail.
Map<SettingsKey, Map<String, Object?>> savedByThisVersion() => {
  SettingsKey.defaults: {
    'abis': ['arm64-v8a', 'x86_64'],
    'schemes': {'v1': true, 'v2': true, 'v3': false, 'v4': null},
    'folded': true,
  },
  SettingsKey.build: {
    'projectDir': '/w/app',
    'mode': 'debug',
    'packaging': 'splitPerAbi',
    'obfuscate': true,
    'symbolsDir': '/w/symbols',
    'signAfterBuild': false,
  },
  SettingsKey.signing: {
    'keystorePath': '/k/release.jks',
    'alias': 'upload',
    'keyUsesStorePassword': false,
    'outputDir': '/w/out',
  },
  SettingsKey.tools: {
    'flutterSdk': '/sdk/flutter',
    'androidSdk': '/sdk/android',
    'buildToolsVersion': '35.0.0',
    'jdkHome': '/jdk/21',
    'bundletool': '/tools/bundletool-all-1.18.3.jar',
  },
  SettingsKey.profiles: {
    'profiles': [
      {
        'id': 'p1',
        'name': 'Release',
        'input': {'packageName': 'com.example.app', 'mustBeUnsigned': true},
        'targets': [
          {
            'id': 't1',
            'name': 'Phone',
            'abi': 'arm64-v8a',
            'keyProperties': '/k/key.properties',
            'schemes': {'v1': false, 'v2': true, 'v3': true, 'v4': false},
            'outputDir': '/w/phone',
          },
          {
            'id': 't2',
            'name': 'Kiosk',
            'abi': null,
            'keyProperties': '/k/key.properties',
            'schemes': null,
            'outputDir': '/w/kiosk',
          },
        ],
        'fileNamePattern': '{name}-{target}-{versionName}',
        'afterRun': 'nothing',
      },
    ],
    'selected': 'p1',
  },
  SettingsKey.profileHistory: {
    'runs': [
      {
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
            'minSdk': 24,
            'unsigned': true,
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
            'setup': {
              'abi': 'arm64-v8a',
              'cut': true,
              'keyProperties': '/k/key.properties',
              'keyAlias': 'upload',
              'schemes': {'v1': false, 'v2': true, 'v3': true, 'v4': false},
              'schemesFromDefaults': false,
              'copiedFrom': null,
            },
            'signerDistinguishedName': 'CN=Example',
            'verifiedSchemes': {
              'v1': false,
              'v2': true,
              'v3': true,
              'v3.1': false,
              'v4': false,
            },
            'hasJarSignature': false,
            'outputSha256': 'ef56',
          },
          {
            'target': 'Kiosk',
            'input': 'app-release.apk',
            'status': 'skipped',
            'outputPath': null,
            'sizeBytes': null,
            'signerSha256': null,
            'reason': 'No native code for x86_64',
            'setup': {
              'abi': 'universal',
              'cut': false,
              'keyProperties': '/k/key.properties',
              'keyAlias': null,
              'schemes': {'v1': null, 'v2': null, 'v3': null, 'v4': null},
              'schemesFromDefaults': true,
              'copiedFrom': null,
            },
            'signerDistinguishedName': null,
            'verifiedSchemes': null,
            'hasJarSignature': null,
            'outputSha256': null,
          },
        ],
        'cancelled': false,
        'fileNamePattern': '{name}-{target}-{versionName}',
        'inputChecks': {
          'packageName': 'com.example.app',
          'mustBeUnsigned': true,
        },
        'buildToolsVersion': '36.0.0',
      },
    ],
  },
};

void main() {
  late MemorySettingsStore store;
  late ProviderContainer container;

  setUp(() {
    store = MemorySettingsStore(savedByThisVersion());
    container = ProviderContainer.test(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
  });

  test('every setting comes back with the values it was saved with', () {
    final defaults = container.read(defaultsProvider);
    expect(defaults.abis, {AndroidAbi.arm64V8a, AndroidAbi.x8664});
    expect(defaults.schemes.label, 'v1, v2');
    expect(defaults.folded, isTrue);

    final build = container.read(buildOptionsProvider);
    expect(build.projectDir, '/w/app');
    expect(build.mode, BuildMode.debug);
    expect(build.abis, defaults.abis);
    expect(build.packaging, ApkPackaging.splitPerAbi);
    expect(build.obfuscate, isTrue);
    expect(build.symbolsDir, '/w/symbols');
    expect(build.signAfterBuild, isFalse);

    final signing = container.read(signingFormProvider);
    expect(signing.keystorePath, '/k/release.jks');
    expect(signing.alias, 'upload');
    expect(signing.keyUsesStorePassword, isFalse);
    expect(signing.outputDir, '/w/out');

    final tools = container.read(toolOverridesProvider);
    expect(tools.flutterSdk, '/sdk/flutter');
    expect(tools.androidSdk, '/sdk/android');
    expect(tools.buildToolsVersion, '35.0.0');
    expect(tools.jdkHome, '/jdk/21');
    expect(tools.bundletool, '/tools/bundletool-all-1.18.3.jar');

    final profiles = container.read(profilesProvider);
    expect(profiles.selectedId, 'p1');
    final profile = profiles.selected!;
    expect(profile.name, 'Release');
    expect(profile.input.packageName, 'com.example.app');
    expect(profile.input.mustBeUnsigned, isTrue);
    expect(profile.fileNamePattern, '{name}-{target}-{versionName}');
    expect(profile.afterRun, AfterRun.nothing);
    expect(profile.targets.map((t) => t.name), ['Phone', 'Kiosk']);
    expect(profile.targets.first.abi, AndroidAbi.arm64V8a);
    expect(profile.targets.first.schemes!.label, 'v2, v3');
    expect(profile.targets.last.abi, isNull);
    expect(profile.targets.last.schemes, isNull);
    expect(profile.targets.last.outputDir, '/w/kiosk');

    final run = container.read(profileHistoryProvider).single;
    expect(run.profileName, 'Release');
    expect(run.finishedAt.difference(run.startedAt).inSeconds, 42);
    expect(run.inputs.single.versionCode, '12');
    expect(run.results.first.status, TargetStatus.signed);
    expect(run.results.first.sizeBytes, 1024);
    expect(run.results.last.reason, 'No native code for x86_64');
    expect(run.results.first.setup!.keyAlias, 'upload');
    expect(run.results.first.verifiedSchemes!['v3'], isTrue);
    expect(run.results.last.setup!.schemesFromDefaults, isTrue);
    expect(run.inputChecks!.mustBeUnsigned, isTrue);
    expect(run.buildToolsVersion, '36.0.0');
  });

  test('saving what was read writes back exactly what was saved', () {
    container.read(defaultsProvider.notifier).update((d) => d);
    container.read(buildOptionsProvider.notifier).update((o) => o);
    container.read(signingFormProvider.notifier).update((f) => f);
    container
        .read(toolOverridesProvider.notifier)
        .set(container.read(toolOverridesProvider));
    container.read(profilesProvider.notifier).select('p1');
    container.read(profileHistoryProvider.notifier).clear('no such profile');

    expect(store.values, savedByThisVersion());
  });

  test(
    'the preferences keep each setting under the name it always had',
    () async {
      SharedPreferences.setMockInitialValues({
        for (final name in [
          'defaults',
          'build',
          'signing',
          'tools',
          'profiles',
          'profile_history',
        ])
          'apk_forge.$name': '{"was": "$name"}',
      });
      final preferences = PreferencesSettingsStore(
        await SharedPreferences.getInstance(),
      );

      expect(
        {for (final key in SettingsKey.values) key: preferences.read(key)},
        {
          SettingsKey.defaults: {'was': 'defaults'},
          SettingsKey.build: {'was': 'build'},
          SettingsKey.signing: {'was': 'signing'},
          SettingsKey.tools: {'was': 'tools'},
          SettingsKey.profiles: {'was': 'profiles'},
          SettingsKey.profileHistory: {'was': 'profile_history'},
        },
      );
    },
  );
}
