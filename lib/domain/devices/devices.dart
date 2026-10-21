/// A device as `adb devices -l` lists it.
class AndroidDevice {
  const AndroidDevice({
    required this.serial,
    required this.state,
    this.model,
    this.product,
    this.abis = const [],
  });

  final String serial;

  /// `device` when it's ready; `unauthorized` until the user accepts the
  /// RSA prompt on the device; `offline`, `recovery`, `sideload`…
  final String state;
  final String? model;
  final String? product;

  /// `ro.product.cpu.abilist`, in the device's order of preference. Empty
  /// until it's read, and for devices that aren't ready.
  final List<String> abis;

  bool get isReady => state == 'device';

  String get displayName => (model ?? product ?? serial).replaceAll('_', ' ');

  AndroidDevice withAbis(List<String> abis) => AndroidDevice(
    serial: serial,
    state: state,
    model: model,
    product: product,
    abis: abis,
  );
}

List<AndroidDevice> parseAdbDevices(Iterable<String> lines) {
  final devices = <AndroidDevice>[];
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty ||
        line.startsWith('List of devices') ||
        line.startsWith('*')) {
      continue;
    }
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final properties = <String, String>{};
    for (final part in parts.skip(2)) {
      final colon = part.indexOf(':');
      if (colon > 0) {
        properties[part.substring(0, colon)] = part.substring(colon + 1);
      }
    }
    devices.add(
      AndroidDevice(
        serial: parts[0],
        state: parts[1],
        model: properties['model'],
        product: properties['product'],
      ),
    );
  }
  return devices;
}

/// `arm64-v8a,armeabi-v7a,armeabi` → the list, in order.
List<String> parseAbiList(String output) => output
    .trim()
    .split(',')
    .map((abi) => abi.trim())
    .where((abi) => abi.isNotEmpty)
    .toList();

/// Whether a device with [deviceAbis] can run an APK with native code for
/// [apkAbis]. An APK without native code runs anywhere; a device whose ABIs
/// weren't read gets the benefit of the doubt.
bool isAbiCompatible(Iterable<String> apkAbis, List<String> deviceAbis) {
  if (apkAbis.isEmpty || deviceAbis.isEmpty) return true;
  return deviceAbis.any(apkAbis.contains);
}

List<String> adbInstallArguments(
  String serial,
  String apk, {
  required bool allowDowngrade,
}) => ['-s', serial, 'install', '-r', if (allowDowngrade) '-d', apk];

final _failureCode = RegExp(r'Failure \[([A-Z_]+)(?::\s*([^\]]*))?\]');

/// bundletool's form: `Error: INSTALL_FAILED_VERSION_DOWNGRADE: Downgrade…`.
final _bundletoolFailureCode = RegExp(
  r'Error: (INSTALL_[A-Z_]+)(?::\s*(.*))?$',
);

/// `INSTALL_FAILED_UPDATE_INCOMPATIBLE` and its hint, from adb's output or
/// bundletool's `install-apks`.
({String code, String? hint})? parseInstallFailure(Iterable<String> lines) {
  for (final line in lines) {
    final match =
        _failureCode.firstMatch(line) ??
        _bundletoolFailureCode.firstMatch(line);
    if (match == null) continue;
    final code = match.group(1)!;
    return (
      code: code,
      hint: installFailureHints[code] ?? match.group(2)?.trim(),
    );
  }
  return null;
}

/// What to do about the install failures that come up most.
const installFailureHints = {
  'INSTALL_FAILED_UPDATE_INCOMPATIBLE':
      'The installed app is signed with a different key. Uninstall it from '
      'the device first (its data is lost).',
  'INSTALL_FAILED_VERSION_DOWNGRADE':
      'The device has a newer versionCode. Turn on "Allow downgrade", or '
      'raise the version.',
  'INSTALL_FAILED_NO_MATCHING_ABIS':
      'The APK has no native code for this device\'s architecture.',
  'INSTALL_PARSE_FAILED_NO_CERTIFICATES': 'The APK is not signed.',
  'INSTALL_FAILED_INSUFFICIENT_STORAGE': 'The device is out of space.',
  'INSTALL_FAILED_TEST_ONLY':
      'The APK is marked test-only (built by Android Studio\'s Run).',
  'INSTALL_FAILED_VERIFICATION_FAILURE':
      'The device refused the signature. On POS hardware with a vendor '
      'whitelist, the signing certificate must be registered.',
};
