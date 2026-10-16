/// What `aapt2 dump badging` says about the APK's manifest.
class Badging {
  const Badging({
    this.packageName,
    this.versionCode,
    this.versionName,
    this.minSdk,
    this.targetSdk,
    this.compileSdk,
    this.label,
    this.debuggable = false,
    this.nativeCode = const [],
    this.permissions = const [],
    this.launchableActivity,
  });

  final String? packageName;
  final String? versionCode;
  final String? versionName;
  final int? minSdk;
  final int? targetSdk;
  final int? compileSdk;
  final String? label;

  /// `android:debuggable="true"`: what Android itself treats as a debug
  /// build. Gradle sets it for the debug build type.
  final bool debuggable;

  /// The ABIs the manifest side of the APK advertises (`native-code:`).
  final List<String> nativeCode;
  final List<String> permissions;
  final String? launchableActivity;
}

final _quoted = RegExp(r"(\w+)='([^']*)'");
final _sdkLine = RegExp(
  r"^(minSdkVersion|sdkVersion|targetSdkVersion):'(\d+)'",
);
final _labelLine = RegExp(r"^application-label:'(.*)'$");
final _listValue = RegExp(r"'([^']*)'");

Badging parseBadging(Iterable<String> lines) {
  String? packageName;
  String? versionCode;
  String? versionName;
  int? minSdk;
  int? targetSdk;
  int? compileSdk;
  String? label;
  var debuggable = false;
  var nativeCode = <String>[];
  final permissions = <String>[];
  String? launchable;

  Map<String, String> attributes(String line) => {
    for (final match in _quoted.allMatches(line))
      match.group(1)!: match.group(2)!,
  };

  for (final line in lines) {
    if (line.startsWith('package:')) {
      final values = attributes(line);
      packageName = values['name'];
      versionCode = values['versionCode'];
      versionName = values['versionName'];
      compileSdk = int.tryParse(values['compileSdkVersion'] ?? '');
      continue;
    }
    final sdk = _sdkLine.firstMatch(line);
    if (sdk != null) {
      final value = int.parse(sdk.group(2)!);
      if (sdk.group(1) == 'targetSdkVersion') {
        targetSdk = value;
      } else {
        minSdk = value;
      }
      continue;
    }
    if (line == 'application-debuggable') {
      debuggable = true;
      continue;
    }
    final labelMatch = _labelLine.firstMatch(line);
    if (labelMatch != null) {
      label = labelMatch.group(1);
      continue;
    }
    if (line.startsWith('native-code:')) {
      nativeCode = _listValue.allMatches(line).map((m) => m.group(1)!).toList();
      continue;
    }
    if (line.startsWith('uses-permission:')) {
      final name = attributes(line)['name'];
      if (name != null) permissions.add(name);
      continue;
    }
    if (line.startsWith('launchable-activity:')) {
      launchable = attributes(line)['name'];
    }
  }

  return Badging(
    packageName: packageName,
    versionCode: versionCode,
    versionName: versionName,
    minSdk: minSdk,
    targetSdk: targetSdk,
    compileSdk: compileSdk,
    label: label,
    debuggable: debuggable,
    nativeCode: nativeCode,
    permissions: permissions,
    launchableActivity: launchable,
  );
}
