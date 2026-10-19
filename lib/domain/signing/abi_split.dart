import '../../core/system/host.dart';
import '../analysis/apk_report.dart';

/// What splitting one APK per ABI makes.
class AbiSplitPlan {
  const AbiSplitPlan({
    required this.abis,
    this.withoutEngine = const [],
    this.notChosen = const [],
    this.missing = const [],
  });

  /// The `lib/` folders that each get an APK of their own.
  final List<String> abis;

  /// The ABIs left out: a Flutter app's native code for them has no engine,
  /// so an APK for one of them would crash at launch.
  final List<String> withoutEngine;

  /// The APK's ABIs that weren't chosen: no APK for them.
  final List<String> notChosen;

  /// The chosen ABIs the APK has no native code for.
  final List<String> missing;

  /// Whether splitting makes something other than the APK itself: two APKs
  /// or more, or one without the ABIs that weren't chosen.
  bool get canSplit =>
      abis.length > 1 || (abis.length == 1 && notChosen.isNotEmpty);

  /// The APK has ABIs to split, but none of the chosen ones.
  bool get noneChosen => abis.isEmpty && notChosen.isNotEmpty;
}

/// One APK per ABI that [contents] has native code for. With [only], one
/// per ABI in [only] that it has.
AbiSplitPlan planAbiSplit(ApkContents contents, {Set<String>? only}) {
  final withoutEngine = contents.abisWithoutFlutterEngine;
  final usable = [
    for (final abi in contents.nativeLibraries.keys)
      if (!withoutEngine.contains(abi)) abi,
  ];
  // One ABI or none: nothing to split, whatever was chosen.
  if (only == null || usable.length < 2) {
    return AbiSplitPlan(abis: usable, withoutEngine: withoutEngine);
  }
  return AbiSplitPlan(
    abis: [...usable.where(only.contains)],
    withoutEngine: withoutEngine,
    notChosen: [...usable.where((abi) => !only.contains(abi))],
    missing: [
      for (final abi in only)
        if (!usable.contains(abi)) abi,
    ]..sort(),
  );
}

/// Whether "Split per ABI and sign" can run, and what Sign says under it.
sealed class SplitAvailability {
  const SplitAvailability();
}

/// It writes one signed APK per ABI in [abis].
final class CanSplit extends SplitAvailability {
  const CanSplit(this.abis, {this.missing = const []});

  final List<String> abis;

  /// ABIs in Defaults the APK has no native code for.
  final List<String> missing;

  /// "Writes 3 signed APKs, one per architecture in Defaults: …".
  String get summary {
    final writes = abis.length == 1
        ? 'Writes 1 signed APK, for ${abis.single}.'
        : 'Writes ${abis.length} signed APKs, one per architecture in '
              'Defaults: ${abis.join(', ')}.';
    return missing.isEmpty
        ? writes
        : '$writes It has no ${missing.join(', ')}.';
  }
}

final class CannotSplit extends SplitAvailability {
  const CannotSplit(this.reason);

  final String reason;
}

/// Whether splitting with [chosen], the ABIs in Defaults, can run on an APK
/// with [contents]. Without [contents] (no APK selected, or not read yet)
/// only the ABIs chosen decide.
SplitAvailability splitAvailability(
  Set<String> chosen, {
  ApkContents? contents,
}) {
  if (chosen.length < 2) {
    return const CannotSplit('Needs two or more architectures in Defaults.');
  }
  if (contents == null) return CanSplit(chosen.toList());
  final plan = planAbiSplit(contents, only: chosen);
  if (plan.canSplit) return CanSplit(plan.abis, missing: plan.missing);
  if (plan.noneChosen) {
    return const CannotSplit('It has none of the architectures in Defaults.');
  }
  return CannotSplit(
    plan.abis.isEmpty
        ? 'It has no native code: nothing to split.'
        : 'It only has ${plan.abis.single}: nothing to split.',
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
