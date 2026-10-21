// Runs the app's services against the real tools, end to end: read the
// keystore, build a Flutter project split per ABI with obfuscation, sign
// every APK, analyze each one, split a universal build per ABI and sign the
// splits, run a signing profile on the universal build with two throwaway
// keys, check that a wrong password fails cleanly, and make a new key of
// each type the way Sign's New key does. The unit tests use recorded
// output; this proves the tools still print what the parsers expect.
//
// Usage (the password comes from the environment, never the command line):
//
//   APK_FORGE_SMOKE_PASS=… dart run tool/smoke.dart <flutter project> <keystore> <alias> <output dir>
//
// Use a throwaway project and keystore; it writes APKs and symbols.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:apk_forge/core/format/format.dart';
import 'package:apk_forge/core/logging/log_entry.dart';
import 'package:apk_forge/core/process/command.dart';
import 'package:apk_forge/core/process/process_runner.dart';
import 'package:apk_forge/core/system/host.dart';
import 'package:apk_forge/core/system/shell_environment.dart';
import 'package:apk_forge/core/zip/zip_directory.dart';
import 'package:apk_forge/domain/analysis/apk_report.dart';
import 'package:apk_forge/domain/analysis/findings.dart';
import 'package:apk_forge/domain/analysis/signature.dart';
import 'package:apk_forge/domain/build/build_options.dart';
import 'package:apk_forge/domain/failure.dart';
import 'package:apk_forge/domain/profiles/profile.dart';
import 'package:apk_forge/domain/profiles/profile_plan.dart';
import 'package:apk_forge/domain/profiles/profile_run.dart';
import 'package:apk_forge/domain/signing/abi_split.dart';
import 'package:apk_forge/domain/signing/keystore.dart';
import 'package:apk_forge/domain/signing/new_key.dart';
import 'package:apk_forge/domain/signing/signing.dart';
import 'package:apk_forge/domain/tools/toolchain.dart';
import 'package:apk_forge/services/apk_analyzer.dart';
import 'package:apk_forge/services/apk_split_service.dart';
import 'package:apk_forge/services/flutter_build_service.dart';
import 'package:apk_forge/services/new_key_service.dart';
import 'package:apk_forge/services/profile_runner.dart';
import 'package:apk_forge/services/signing_service.dart';
import 'package:apk_forge/services/tool_executor.dart';

Future<void> main(List<String> args) async {
  if (args.length != 4) {
    stderr.writeln(
      'Usage: APK_FORGE_SMOKE_PASS=… dart run tool/smoke.dart <project> <keystore> <alias> <output dir>',
    );
    exit(64);
  }
  final [project, keystore, alias, outputDir] = args;
  final password = Platform.environment['APK_FORGE_SMOKE_PASS'];
  if (password == null || password.isEmpty) {
    stderr.writeln('Set APK_FORGE_SMOKE_PASS.');
    exit(64);
  }

  final environment = await loadShellEnvironment(
    Host.current(Platform.environment),
  );
  final host = Host.current(environment);
  final toolchain = ToolchainLocator(
    host: host,
    probe: const IoFileProbe(),
  ).locate(const ToolOverrides());
  final log = _PrintLog([password]);
  final executor = ToolExecutor(IoProcessRunner(host), log);
  var failures = 0;

  void check(bool condition, String what) {
    if (condition) {
      stdout.writeln('  PASS  $what');
    } else {
      failures++;
      stdout.writeln('  FAIL  $what');
    }
  }

  stdout.writeln('\n== Keystore');
  final entries = await const KeystoreService().listEntries(
    executor,
    keytool: toolchain.keytool!,
    keystorePath: keystore,
    password: password,
  );
  final key = entries.firstWhere((entry) => entry.alias == alias);
  check(
    key.sha256 != null,
    'keytool gives "$alias" a SHA-256 (${shortDigest(key.sha256!)})',
  );

  stdout.writeln('\n== Build (release, split per ABI, obfuscated)');
  final options = BuildOptions(
    projectDir: project,
    packaging: ApkPackaging.splitPerAbi,
    obfuscate: true,
    // A new folder each run: Flutter skips the Dart compile, and the
    // symbols with it, when nothing changed since the last build.
    symbolsDir: host.path.join(
      outputDir,
      'symbols-${DateTime.now().millisecondsSinceEpoch}',
    ),
  );
  final apks = await FlutterBuildService(host: host)
      .build(executor, flutter: toolchain.flutter!, options: options);
  check(
    apks.length == 3,
    'three APKs reported: ${apks.map(host.path.basename).join(', ')}',
  );
  check(
    apks.every((apk) => File(apk).existsSync()),
    'every reported APK exists',
  );
  check(
    Directory(options.symbolsDir)
        .listSync()
        .any((file) => file.path.endsWith('.symbols')),
    'the obfuscation symbols were written',
  );

  stdout.writeln('\n== Sign and analyze');
  final request = SigningRequest(
    keystorePath: keystore,
    storePassword: password,
    alias: alias,
    outputDir: outputDir,
  );
  for (final apk in apks) {
    final signed = await ApkSigningService(host: host).sign(
      executor,
      toolchain: toolchain,
      input: apk,
      request: request,
      expectedSha256: key.sha256,
    );
    final report = await const ApkAnalyzer().analyze(
      executor,
      toolchain: toolchain,
      path: signed.path,
    );
    final abi = report.contents.nativeLibraries.keys.join(',');
    check(
      report.signature?.verifies ?? false,
      '${host.path.basename(signed.path)} verifies',
    );
    check(
      report.signature?.signers.single.sha256 == key.sha256,
      '  signed with "$alias"',
    );
    check(report.isDebuggable == false, '  release (not debuggable)');
    check(
      report.contents.abisWithoutFlutterEngine.isEmpty,
      '  Flutter engine for $abi',
    );
    check(
      report.badging?.nativeCode.join(',') == abi,
      '  manifest and files agree on the ABI ($abi)',
    );
    final titles = apkFindings(
      report,
      keystoreEntries: entries,
    ).map((f) => '${f.level.name}: ${f.title}');
    stdout.writeln('        findings: ${titles.join(' | ')}');
  }

  stdout.writeln('\n== Split a universal APK per ABI, then sign');
  final universal = (await FlutterBuildService(host: host).build(
    executor,
    flutter: toolchain.flutter!,
    options: BuildOptions(projectDir: project),
  )).single;
  final universalReport = await const ApkAnalyzer().analyze(
    executor,
    toolchain: toolchain,
    path: universal,
  );
  final universalEntries = await readZipDirectory(universal);
  await ApkSplitService(host: host).withSplits(
    executor,
    input: universal,
    use: (splits) async {
      check(
        splits.map((split) => split.abi).join(',') ==
            'arm64-v8a,armeabi-v7a,x86_64',
        'one split per ABI: ${splits.map((split) => split.abi).join(', ')}',
      );
      for (final split in splits) {
        final signed = await ApkSigningService(host: host).sign(
          executor,
          toolchain: toolchain,
          input: split.path,
          request: request,
          expectedSha256: key.sha256,
        );
        final report = await const ApkAnalyzer().analyze(
          executor,
          toolchain: toolchain,
          path: signed.path,
        );
        check(
          report.signature?.verifies ?? false,
          '${host.path.basename(signed.path)} verifies, '
          '${formatBytes(report.sizeBytes)} of '
          '${formatBytes(universalReport.sizeBytes)}',
        );
        check(
          report.signature?.signers.single.sha256 == key.sha256,
          '  signed with "$alias"',
        );
        check(
          report.contents.nativeLibraries.keys.join(',') == split.abi &&
              report.contents.abisWithoutFlutterEngine.isEmpty,
          '  only ${split.abi} native code, with the Flutter engine',
        );
        check(
          report.badging?.nativeCode.join(',') == split.abi,
          '  aapt2 reads native-code: ${report.badging?.nativeCode.join(', ')}',
        );
        check(
          report.badging?.versionCode != null &&
              report.badging?.versionCode ==
                  universalReport.badging?.versionCode,
          '  same versionCode as the universal APK '
          '(${report.badging?.versionCode})',
        );
        final names = [
          for (final entry in await readZipDirectory(signed.path))
            if (!isJarSignatureFile(entry.name)) entry.name,
        ];
        final expected = [
          for (final entry in universalEntries)
            if (keepsEntryForAbi(entry.name, split.abi)) entry.name,
        ];
        check(
          names.join('\n') == expected.join('\n'),
          '  every other file of the universal APK is there '
          '(${names.length} files)',
        );
        final align = await executor.run(
          Command(
            toolchain.zipalign!,
            zipalignArguments(
              signed.path,
              supportsPageSize: toolchain.zipalignSupportsPageSize,
            ),
          ),
          echoOutput: false,
        );
        check(align.succeeded, '  zipalign -c accepts the signed APK');
      }
    },
  );

  stdout.writeln('\n== Run a profile on the universal APK');
  await _runProfile(
    executor,
    log,
    host: host,
    toolchain: toolchain,
    universal: universalReport,
    outputDir: outputDir,
    check: check,
  );

  stdout.writeln('\n== Wrong password');
  final earlier = File(signedApkPath(apks.first, outputDir, host));
  final earlierBytes = earlier.readAsBytesSync();
  try {
    await ApkSigningService(host: host).sign(
      executor,
      toolchain: toolchain,
      input: apks.first,
      request: SigningRequest(
        keystorePath: keystore,
        storePassword: 'wrong-$password',
        alias: alias,
        outputDir: outputDir,
      ),
    );
    check(false, 'a wrong password fails');
  } on ToolFailure catch (failure) {
    const wrong = KeyLoadFailure.storePasswordWrong;
    check(
      failure.title == wrong.problem,
      'a wrong password says so: ${failure.title}',
    );
    check(
      failure.details.contains(wrong.fix),
      '  with what to do: ${failure.details.join(' / ')}',
    );
    check(
      !failure.toString().contains(password),
      '  without the password in the error',
    );
  }
  check(
    earlier.readAsBytesSync().length == earlierBytes.length &&
        !File('${earlier.path}.partial').existsSync(),
    '  the earlier signed APK is intact and no .partial is left',
  );

  stdout.writeln('\n== New key');
  await _newKeys(
    executor,
    log,
    host: host,
    toolchain: toolchain,
    apk: apks.first,
    check: check,
  );

  stdout.writeln(
    failures == 0 ? '\nAll checks passed.' : '\n$failures check(s) failed.',
  );
  exit(failures == 0 ? 0 : 1);
}

/// Runs [universal] through a profile with two targets, each cut to its ABI
/// and signed with its own throwaway key (the second has a key password of
/// its own), the way the Profiles view's Run does: plan, open the keys, run.
Future<void> _runProfile(
  ToolExecutor executor,
  _PrintLog log, {
  required Host host,
  required Toolchain toolchain,
  required ApkReport universal,
  required String outputDir,
  required void Function(bool condition, String what) check,
}) async {
  final path = host.path;
  final keytool = toolchain.keytool!;
  final keys = await Directory.systemTemp.createTemp('apk_forge_smoke_keys_');
  final passwords = <String>[];
  try {
    final phone = await _throwawayKey(
      executor,
      host,
      keytool,
      keys.path,
      'phone',
    );
    final kiosk = await _throwawayKey(
      executor,
      host,
      keytool,
      keys.path,
      'kiosk',
      ownKeyPassword: true,
    );
    passwords.addAll([...phone.passwords, ...kiosk.passwords]);

    ProfileTarget target(
      String name,
      AndroidAbi abi,
      String keyProperties, {
      SigningSchemes? schemes,
    }) {
      final folder = path.join(outputDir, 'profile', name.toLowerCase());
      Directory(folder).createSync(recursive: true);
      return ProfileTarget(
        id: name.toLowerCase(),
        name: name,
        abi: abi,
        keyProperties: keyProperties,
        schemes: schemes,
        outputDir: folder,
      );
    }

    final profile = SigningProfile(
      id: 'smoke',
      name: 'Smoke',
      input: InputChecks(packageName: universal.badging?.packageName),
      targets: [
        target('Phone', AndroidAbi.arm64V8a, phone.keyProperties),
        target(
          'Kiosk',
          AndroidAbi.x8664,
          kiosk.keyProperties,
          schemes: const SigningSchemes(v1: true, v2: true, v3: true, v4: true),
        ),
      ],
    );
    final plan = planProfileRun(
      profile,
      [universal],
      defaultSchemes: const SigningSchemes.automatic(),
      host: host,
      probe: const IoFileProbe(),
      date: DateTime.now(),
    );
    check(
      plan.canRun && plan.jobs.length == 2,
      'the plan cuts and signs twice'
      '${plan.problems.isEmpty ? '' : ': ${plan.problems.join(' / ')}'}',
    );
    if (!plan.canRun) return;

    final keyService = ProfileKeyService(host: host);
    final opened = await keyService.open(
      executor,
      keytool: keytool,
      keyFiles: profile.keyFiles,
    );
    check(
      opened.length == 2,
      'both key.properties open, the one with its own key password too',
    );

    // The same key with a wrong key password stops before anything is
    // signed.
    final wrongPassword = 'wrong-${kiosk.passwords.last}';
    passwords.add(wrongPassword);
    final wrong = File(path.join(keys.path, 'wrong', 'key.properties'))
      ..parent.createSync()
      ..writeAsStringSync(
        _keyProperties(
          storePassword: kiosk.passwords.first,
          keyPassword: wrongPassword,
          alias: 'kiosk',
          storeFile: '../kiosk.jks',
        ),
      );
    try {
      await keyService.open(executor, keytool: keytool, keyFiles: [wrong.path]);
      check(false, 'a wrong key password stops the run');
    } on ToolFailure catch (failure) {
      check(
        failure.details.contains('The key password (keyPassword) is wrong.'),
        'a wrong key password stops the run: ${failure.details.join(' ')}',
      );
    }

    final results = await ProfileRunner(
      host: host,
      signing: ApkSigningService(host: host),
    ).run(executor, toolchain: toolchain, plan: plan, keys: opened);
    for (final result in results) {
      check(
        result.status == TargetStatus.signed,
        '${result.target}: ${result.status.label}'
        '${result.reason == null ? '' : ' (${result.reason})'}',
      );
      final output = result.outputPath;
      final setup = result.setup;
      if (output == null || setup == null) continue;
      final report = await const ApkAnalyzer().analyze(
        executor,
        toolchain: toolchain,
        path: output,
      );
      final key = opened[setup.keyProperties]!;
      check(
        report.signature?.verifies ?? false,
        '  ${path.basename(output)} verifies',
      );
      check(
        report.signature?.signers.single.sha256 == key.sha256,
        '  signed with its own key, "${key.alias}"',
      );
      check(
        setup.cut &&
            report.contents.nativeLibraries.keys.join(',') == setup.abi &&
            report.contents.abisWithoutFlutterEngine.isEmpty,
        '  only ${setup.abi} native code, with the Flutter engine',
      );
      check(
        result.outputSha256 == report.sha256,
        '  the record has its SHA-256',
      );
    }
    final kioskResult = results.firstWhere((r) => r.target == 'Kiosk');
    check(
      kioskResult.verifiedSchemes?['v4'] == true &&
          kioskResult.hasJarSignature == true,
      'Kiosk carries what it asked for: '
      '${describeSchemes(kioskResult.verifiedSchemes ?? const {}, hasJarSignature: kioskResult.hasJarSignature ?? false)}',
    );

    final record = jsonEncode([for (final r in results) r.toJson()]);
    check(!passwords.any(record.contains), 'no password in the run\'s record');
    check(
      !log.lines.any((line) => passwords.any(line.contains)),
      'no password in the log',
    );
  } finally {
    await keys.delete(recursive: true);
  }
}

/// Makes a PKCS12 key, and a JKS one whose key has a password of its own,
/// as New key in Sign does. Then a profile opens each from its
/// `key.properties`, and it signs [apk].
Future<void> _newKeys(
  ToolExecutor executor,
  _PrintLog log, {
  required Host host,
  required Toolchain toolchain,
  required String apk,
  required void Function(bool condition, String what) check,
}) async {
  final keytool = toolchain.keytool!;
  final folder = await Directory.systemTemp.createTemp('apk_forge_smoke_new_');
  final today = DateTime.now();
  try {
    for (final type in KeystoreType.values) {
      final storePassword = _randomPassword();
      final keyPassword = type == KeystoreType.jks
          ? _randomPassword()
          : storePassword;
      final form = NewKeyForm(
        folder: host.path.join(folder.path, type.label),
        type: type,
        storePassword: storePassword,
        confirmStorePassword: storePassword,
        keyUsesStorePassword: type != KeystoreType.jks,
        keyPassword: keyPassword,
        confirmKeyPassword: keyPassword,
        commonName: 'APK Forge Smoke New Key',
        organization: 'Example, Inc.',
        countryCode: 'us',
      );
      Directory(form.folder).createSync();
      final problems = newKeyProblems(
        form,
        host: host,
        probe: const IoFileProbe(),
        today: today,
      );
      check(problems.isEmpty, '${type.label}: the form has no problem');
      final request = form.toRequest(host, today);
      final service = NewKeyService(host: host);
      await service.create(executor, keytool: keytool, request: request);

      final mode = File(request.keyPropertiesPath).statSync().modeString();
      check(mode == 'rw-------', '  key.properties is its owner\'s ($mode)');
      final entry = (await const KeystoreService().listEntries(
        executor,
        keytool: keytool,
        keystorePath: request.keystorePath,
        password: storePassword,
      )).single;
      check(
        entry.owner == 'CN=APK Forge Smoke New Key, O="Example, Inc.", C=US',
        '  the certificate: ${entry.owner}',
      );
      check(
        entry.validUntil?.endsWith('${today.year + 25}') ?? false,
        '  valid for 25 years: until ${entry.validUntil}',
      );

      final opened = (await ProfileKeyService(host: host).open(
        executor,
        keytool: keytool,
        keyFiles: [request.keyPropertiesPath],
      )).values.single;
      check(
        opened.sha256 == entry.sha256 && opened.keyPassword == keyPassword,
        '  a profile opens it from its key.properties',
      );
      final out = Directory(host.path.join(form.folder, 'out'))..createSync();
      final signed = await ApkSigningService(host: host).sign(
        executor,
        toolchain: toolchain,
        input: apk,
        request: opened.request(
          schemes: const SigningSchemes.automatic(),
          outputDir: out.path,
        ),
        expectedSha256: entry.sha256,
      );
      check(
        File(signed.path).existsSync(),
        '  it signs, and the APK verifies with it',
      );

      try {
        await service.create(executor, keytool: keytool, request: request);
        check(false, '  a second time, nothing is written');
      } on ToolFailure catch (failure) {
        check(
          failure.title == 'Nothing was written',
          '  a second time, nothing is written: ${failure.details.single}',
        );
      }
      check(
        !log.lines.any(
          (line) => line.contains(storePassword) || line.contains(keyPassword),
        ),
        '  no password in the log',
      );
    }
  } finally {
    await folder.delete(recursive: true);
  }
}

/// A new keystore in [folder] with one key, [alias], and the
/// `key.properties` that points to it from its own folder, with a relative
/// `storeFile` as Gradle projects write it.
Future<({String keyProperties, List<String> passwords})> _throwawayKey(
  ToolExecutor executor,
  Host host,
  String keytool,
  String folder,
  String alias, {
  bool ownKeyPassword = false,
}) async {
  final storePassword = _randomPassword();
  final keyPassword = ownKeyPassword ? _randomPassword() : storePassword;
  final secrets = [storePassword, keyPassword];
  final result = await executor.run(
    Command(
      keytool,
      keytoolGenerateKeyArguments(
        host.path.join(folder, '$alias.jks'),
        alias,
        distinguishedName: 'CN=APK Forge Smoke $alias, O=Example, C=US',
        // PKCS12 can't give the key a password of its own.
        validityDays: 365,
        storeType: ownKeyPassword ? KeystoreType.jks : KeystoreType.pkcs12,
      ),
      environment: {
        keystorePasswordVariable: storePassword,
        keyPasswordVariable: keyPassword,
      },
      secrets: secrets,
    ),
    echoOutput: false,
  );
  if (!result.succeeded) {
    throw ToolFailure.fromResult(
      'keytool could not make a throwaway key',
      result,
      secrets: secrets,
    );
  }
  final properties = File(host.path.join(folder, alias, 'key.properties'))
    ..parent.createSync()
    ..writeAsStringSync(
      _keyProperties(
        storePassword: storePassword,
        keyPassword: keyPassword,
        alias: alias,
        storeFile: '../$alias.jks',
      ),
    );
  return (keyProperties: properties.path, passwords: secrets);
}

String _keyProperties({
  required String storePassword,
  required String keyPassword,
  required String alias,
  required String storeFile,
}) =>
    'storePassword=$storePassword\nkeyPassword=$keyPassword\n'
    'keyAlias=$alias\nstoreFile=$storeFile\n';

String _randomPassword() {
  final random = Random.secure();
  return base64Url.encode([for (var i = 0; i < 18; i++) random.nextInt(256)]);
}

class _PrintLog implements TaskLog {
  _PrintLog(this.secrets);

  final List<String> secrets;

  /// Every line printed, to check that no password reached the log.
  final lines = <String>[];

  void _print(String prefix, String text) {
    final line = '    $prefix ${maskSecrets(text, secrets)}';
    lines.add(line);
    stdout.writeln(line);
  }

  @override
  void step(String text) => _print('▶', text);

  @override
  void command(Command command) =>
      _print('\$', maskSecrets(command.displayLine, command.secrets));

  @override
  void output(
    OutputStream stream,
    String line, {
    List<String> secrets = const [],
  }) => _print(
    stream == OutputStream.stderr ? '!' : '|',
    maskSecrets(line, secrets),
  );

  @override
  void info(String text) => _print('i', text);

  @override
  void warning(String text) => _print('w', text);

  @override
  void success(String text) => _print('✓', text);

  @override
  void error(String text) => _print('✗', text);
}
