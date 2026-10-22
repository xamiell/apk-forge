/// `bundletool` arguments, after its launch arguments (`-jar <jar>` for a
/// jar), that print its version.
List<String> bundletoolVersionArguments(List<String> launch) => [
  ...launch,
  'version',
];

final _version = RegExp(r'^\d+(\.\d+)+\S*$');

/// The version `bundletool version` prints (`1.18.3`); `null` when it
/// printed something else.
String? parseBundletoolVersion(Iterable<String> lines) {
  for (final line in lines) {
    final trimmed = line.trim();
    if (_version.hasMatch(trimmed)) return trimmed;
  }
  return null;
}

/// `bundletool` arguments, after its launch arguments, that print
/// [bundle]'s manifest as XML: aapt2 can't read a bundle's.
List<String> bundletoolDumpManifestArguments(
  List<String> launch,
  String bundle,
) => [...launch, 'dump', 'manifest', '--bundle=$bundle'];

/// `bundletool` arguments, after its launch arguments, that make the APKs
/// for the device [serial] from [bundle], as a store would, signed with
/// [keystore]'s [alias].
///
/// The passwords are read from files ([storePasswordFile],
/// [keyPasswordFile]): bundletool takes them as an argument or a file
/// only, and an argument would show in `ps`.
List<String> bundletoolBuildApksArguments(
  List<String> launch, {
  required String bundle,
  required String output,
  required String serial,
  required String adb,
  required String keystore,
  required String alias,
  required String storePasswordFile,
  required String keyPasswordFile,
}) => [
  ...launch,
  'build-apks',
  '--bundle=$bundle',
  '--output=$output',
  '--connected-device',
  '--device-id=$serial',
  '--adb=$adb',
  '--ks=$keystore',
  '--ks-key-alias=$alias',
  '--ks-pass=file:$storePasswordFile',
  '--key-pass=file:$keyPasswordFile',
];

/// `bundletool` arguments, after its launch arguments, that install the
/// APKs `build-apks` made on the device [serial].
List<String> bundletoolInstallApksArguments(
  List<String> launch, {
  required String apks,
  required String serial,
  required String adb,
  required bool allowDowngrade,
}) => [
  ...launch,
  'install-apks',
  '--apks=$apks',
  '--device-id=$serial',
  '--adb=$adb',
  if (allowDowngrade) '--allow-downgrade',
];
