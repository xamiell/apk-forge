// Runs the app's services against the real tools, end to end: read the
// keystore, build a Flutter project split per ABI with obfuscation, sign
// every APK, analyze each one, split a universal build per ABI and sign the
// splits, and check that a wrong password fails cleanly. The unit tests use recorded output; this proves the tools still
// print what the parsers expect.
//
// Usage (the password comes from the environment, never the command line):
//
//   APK_FORGE_SMOKE_PASS=… dart run tool/smoke.dart <flutter project> <keystore> <alias> <output dir>
//
// Use a throwaway project and keystore; it writes APKs and symbols.
import 'dart:io';

import 'package:apk_forge/core/format/format.dart';
import 'package:apk_forge/core/logging/log_entry.dart';
import 'package:apk_forge/core/process/command.dart';
import 'package:apk_forge/core/process/process_runner.dart';
import 'package:apk_forge/core/system/host.dart';
import 'package:apk_forge/core/system/shell_environment.dart';
import 'package:apk_forge/core/zip/zip_directory.dart';
import 'package:apk_forge/domain/analysis/findings.dart';
import 'package:apk_forge/domain/build/build_options.dart';
import 'package:apk_forge/domain/failure.dart';
import 'package:apk_forge/domain/signing/abi_split.dart';
import 'package:apk_forge/domain/signing/signing.dart';
import 'package:apk_forge/domain/tools/toolchain.dart';
import 'package:apk_forge/services/apk_analyzer.dart';
import 'package:apk_forge/services/apk_split_service.dart';
import 'package:apk_forge/services/flutter_build_service.dart';
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
    check(
      failure.title.startsWith('Signing failed'),
      'a wrong password fails: ${failure.title}',
    );
    check(
      failure.details.any((line) => line.contains('password was incorrect')),
      '  with the reason: ${failure.details.join(' / ')}',
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

  stdout.writeln(
    failures == 0 ? '\nAll checks passed.' : '\n$failures check(s) failed.',
  );
  exit(failures == 0 ? 0 : 1);
}

class _PrintLog implements TaskLog {
  _PrintLog(this.secrets);

  final List<String> secrets;

  void _print(String prefix, String text) =>
      stdout.writeln('    $prefix ${maskSecrets(text, secrets)}');

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
