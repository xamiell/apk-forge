import '../../core/system/host.dart';
import '../analysis/apk_report.dart';

/// What splitting one APK per ABI makes.
class AbiSplitPlan {
  const AbiSplitPlan({required this.abis, this.withoutEngine = const []});

  /// The `lib/` folders that each get an APK of their own.
  final List<String> abis;

  /// The ABIs left out: a Flutter app's native code for them has no engine,
  /// so an APK for one of them would crash at launch.
  final List<String> withoutEngine;

  /// With fewer than two ABIs there's nothing to split.
  bool get canSplit => abis.length > 1;
}

/// One APK per ABI that [contents] has native code for.
AbiSplitPlan planAbiSplit(ApkContents contents) {
  final withoutEngine = contents.abisWithoutFlutterEngine;
  return AbiSplitPlan(
    abis: [
      for (final abi in contents.nativeLibraries.keys)
        if (!withoutEngine.contains(abi)) abi,
    ],
    withoutEngine: withoutEngine,
  );
}

/// Whether the APK for [abi] keeps [entryName]: everything but the other
/// ABIs' `lib/` folders and the v1 signature files, which no longer match.
///
/// The code, the resources and the manifest are the same for every ABI.
bool keepsEntryForAbi(String entryName, String abi) {
  final parts = entryName.split('/');
  if (parts.length >= 3 && parts[0] == 'lib') return parts[1] == abi;
  return !isJarSignatureFile(entryName);
}

/// `META-INF/MANIFEST.MF` and the files of a v1 (JAR) signature, which
/// apksigner writes again when it signs with v1. Other `META-INF/` files
/// (`services/`, library versions) belong to the app.
bool isJarSignatureFile(String entryName) {
  final parts = entryName.split('/');
  if (parts.length != 2 || parts[0] != 'META-INF') return false;
  final name = parts[1].toUpperCase();
  return name == 'MANIFEST.MF' ||
      name.startsWith('SIG-') ||
      RegExp(r'\.(SF|RSA|DSA|EC)$').hasMatch(name);
}

/// `app-release.apk` → `app-release-arm64-v8a.apk`. Signing then adds
/// `-signed`.
String abiSplitFileName(String input, String abi, Host host) =>
    '${host.path.basenameWithoutExtension(input)}-$abi.apk';
