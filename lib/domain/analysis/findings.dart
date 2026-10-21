import '../../core/format/format.dart';
import '../signing/keystore.dart';
import 'apk_report.dart';

enum FindingLevel { ok, info, warning, error }

class Finding {
  const Finding(this.level, this.title, [this.detail]);

  final FindingLevel level;
  final String title;
  final String? detail;
}

/// The checks the Analyze panel lists at the top, worst first.
///
/// [keystoreEntries] are the keys loaded in the Sign panel: when there are
/// any, the APK's signer is compared with them by SHA-256 (DNs aren't
/// compared: apksigner and keytool print them in opposite orders).
List<Finding> apkFindings(
  ApkReport report, {
  List<KeystoreEntry> keystoreEntries = const [],
}) {
  final findings = <Finding>[];
  final signature = report.signature;
  final badging = report.badging;

  // Signature.
  if (signature == null) {
    findings.add(
      Finding(
        FindingLevel.warning,
        'Signature not checked',
        report.signatureError ?? 'apksigner was not found.',
      ),
    );
  } else if (!signature.verifies) {
    findings.add(
      Finding(
        FindingLevel.error,
        'The signature does not verify',
        signature.errors.isEmpty
            ? 'Android will refuse to install it.'
            : signature.errors.join('\n'),
      ),
    );
  } else {
    final signer = signature.signers.isEmpty ? null : signature.signers.first;
    if (signer != null && signer.isAndroidDebugKey) {
      findings.add(
        const Finding(
          FindingLevel.warning,
          'Signed with the Android debug key',
          'Fine for testing. A store, a TMS or an update over a release '
              'install will reject it.',
        ),
      );
    }
    if (keystoreEntries.isNotEmpty && signer?.sha256 != null) {
      final match = keystoreEntries.where(
        (entry) => entry.sha256 == signer!.sha256,
      );
      if (match.isNotEmpty) {
        findings.add(
          Finding(
            FindingLevel.ok,
            'Signed with your key “${match.first.alias}”',
            'SHA-256 ${shortDigest(signer!.sha256!)} matches the keystore.',
          ),
        );
      } else {
        findings.add(
          Finding(
            FindingLevel.warning,
            'Not signed with the loaded keystore',
            'Signer SHA-256 ${shortDigest(signer!.sha256!)} matches none of its '
                '${keystoreEntries.length} key(s).',
          ),
        );
      }
    }
    final modernScheme = signature.scheme('v2') || signature.scheme('v3');
    final targetSdk = badging?.targetSdk;
    // A bundle carries a JAR signature only: the store signs its APKs.
    if (!report.isBundle &&
        !modernScheme &&
        targetSdk != null &&
        targetSdk >= 30) {
      findings.add(
        Finding(
          FindingLevel.error,
          'No v2 or v3 signature',
          'Apps targeting API 30+ (this one: $targetSdk) need one to install '
              'on Android 11 and later.',
        ),
      );
    }
  }

  // Release or debug.
  switch (report.isDebuggable) {
    case true:
      findings.add(
        const Finding(
          FindingLevel.info,
          'Debug build (debuggable)',
          'Slower, and anyone with adb can inspect it. Use a release build '
              'for devices in the field.',
        ),
      );
    case false:
      findings.add(
        const Finding(FindingLevel.ok, 'Release build (not debuggable)'),
      );
    case null:
      findings.add(
        Finding(
          FindingLevel.warning,
          'Build type unknown',
          report.badgingError ?? 'aapt2 could not read the manifest.',
        ),
      );
  }
  if (report.contents.flutter == FlutterCompilation.jit &&
      report.isDebuggable == false) {
    findings.add(
      const Finding(
        FindingLevel.warning,
        'Flutter code is in debug (JIT) form',
        'The manifest says release, but there is no libapp.so.',
      ),
    );
  }

  // Native code.
  final missingEngine = report.contents.abisWithoutFlutterEngine;
  if (missingEngine.isNotEmpty) {
    findings.add(
      Finding(
        FindingLevel.error,
        'No Flutter engine for ${missingEngine.join(', ')}',
        'A plugin ships native code for it, so a device that prefers it '
            'installs the app and crashes at launch. Build for that ABI too, '
            'or drop it with ndk.abiFilters in Gradle.',
      ),
    );
  }

  // Worst first, keeping the order above inside each level.
  return [
    for (final level in FindingLevel.values.reversed)
      ...findings.where((finding) => finding.level == level),
  ];
}
