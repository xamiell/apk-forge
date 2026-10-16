import '../../core/format/format.dart';
import 'devices.dart';

/// What a connected device says about itself.
///
/// Read with one `adb shell` call (see [deviceInfoScript]): every system
/// property plus a few commands for what properties don't hold (screen,
/// memory, storage, battery, kernel, page size).
class DeviceInfo {
  const DeviceInfo({
    required this.serial,
    this.properties = const {},
    this.screenSize,
    this.screenSizeOverride,
    this.density,
    this.densityOverride,
    this.pageSize,
    this.memoryKb,
    this.dataTotalKb,
    this.dataFreeKb,
    this.battery,
    this.kernel,
  });

  final String serial;

  /// `getprop`, as `ro.build.version.release` → `14`.
  final Map<String, String> properties;

  /// `wm size`: the panel's real size, and the one the system draws at when
  /// someone changed it.
  final String? screenSize;
  final String? screenSizeOverride;
  final int? density;
  final int? densityOverride;

  /// Memory page size in bytes. 16384 on the Android 15+ devices that need
  /// native libraries aligned to 16 KB.
  final int? pageSize;
  final int? memoryKb;
  final int? dataTotalKb;
  final int? dataFreeKb;
  final BatteryInfo? battery;
  final String? kernel;

  String? property(String key) {
    final value = properties[key]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  String? get manufacturer => property('ro.product.manufacturer');
  String? get brand => property('ro.product.brand');
  String? get model => property('ro.product.model');

  /// The codename (`emu64a`, `shiba`, `D30M`).
  String? get device => property('ro.product.device');

  String? get androidVersion =>
      property('ro.build.version.release_or_codename') ??
      property('ro.build.version.release');
  int? get sdk => int.tryParse(property('ro.build.version.sdk') ?? '');
  String? get securityPatch => property('ro.build.version.security_patch');
  String? get buildId => property('ro.build.display.id');
  String? get fingerprint => property('ro.build.fingerprint');

  /// `user`, `userdebug` or `eng`. Devices in the field run `user`.
  String? get buildType => property('ro.build.type');

  /// `release-keys`, or `test-keys` on a build signed with AOSP's public keys.
  String? get buildTags => property('ro.build.tags');

  /// In the device's order of preference: Android installs the first one
  /// the APK has native code for.
  List<String> get abis => parseAbiList(
    property('ro.product.cpu.abilist') ?? property('ro.product.cpu.abi') ?? '',
  );

  /// The chip, from what each Android version exposes: `ro.soc.*` (12+),
  /// else the board or hardware name.
  String? get soc {
    final named = [
      property('ro.soc.manufacturer'),
      property('ro.soc.model'),
    ].nonNulls.join(' ');
    if (named.isNotEmpty) return named;
    return property('ro.board.platform') ?? property('ro.hardware');
  }

  bool get isDebuggable => property('ro.debuggable') == '1';

  bool get isEmulator =>
      property('ro.kernel.qemu') == '1' ||
      property('ro.boot.qemu') == '1' ||
      (property('ro.hardware')?.contains('ranchu') ?? false);

  String? get locale =>
      property('persist.sys.locale') ?? property('ro.product.locale');
  String? get timeZone => property('persist.sys.timezone');

  /// `Google sdk_gphone64_arm64`, without repeating a brand the model
  /// already starts with (`samsung SM-A515F`, not `samsung samsung …`).
  String get displayName {
    final maker = manufacturer;
    final name = model ?? device ?? serial;
    if (maker == null || name.toLowerCase().startsWith(maker.toLowerCase())) {
      return name;
    }
    return '$maker $name';
  }
}

enum BatteryStatus {
  unknown('Unknown'),
  charging('Charging'),
  discharging('Discharging'),
  notCharging('Not charging'),
  full('Full');

  const BatteryStatus(this.label);
  final String label;

  /// `BatteryManager.BATTERY_STATUS_*`: 1 unknown … 5 full.
  static BatteryStatus fromCode(int? code) => switch (code) {
    2 => charging,
    3 => discharging,
    4 => notCharging,
    5 => full,
    _ => unknown,
  };
}

class BatteryInfo {
  const BatteryInfo({
    this.level,
    this.status = BatteryStatus.unknown,
    this.temperatureC,
  });

  final int? level;
  final BatteryStatus status;
  final double? temperatureC;
}

const _marker = '__APK_FORGE__';

/// The commands [parseDeviceInfo] reads, as one `adb shell` argument.
/// A command the device doesn't have just leaves its section empty.
String deviceInfoScript() => [
  'echo $_marker:props',
  'getprop',
  'echo $_marker:wm_size',
  'wm size',
  'echo $_marker:wm_density',
  'wm density',
  'echo $_marker:page_size',
  'getconf PAGE_SIZE',
  'echo $_marker:meminfo',
  'head -n 1 /proc/meminfo',
  'echo $_marker:df',
  'df -k /data',
  'echo $_marker:battery',
  'dumpsys battery',
  'echo $_marker:kernel',
  'uname -r',
].join('; ');

final _property = RegExp(r'^\[(.+?)\]: \[(.*)\]$');
final _wm = RegExp(r'^(Physical|Override) (size|density): (\S+)');
final _battery = RegExp(r'^\s*(level|status|temperature): (-?\d+)');

DeviceInfo parseDeviceInfo(String serial, Iterable<String> lines) {
  final sections = <String, List<String>>{};
  var current = '';
  for (final line in lines) {
    if (line.startsWith('$_marker:')) {
      current = line.substring(_marker.length + 1).trim();
      sections[current] = [];
    } else {
      sections.putIfAbsent(current, () => []).add(line);
    }
  }
  List<String> section(String name) => sections[name] ?? const [];

  final properties = <String, String>{
    for (final line in section('props'))
      if (_property.firstMatch(line) case final match?)
        match.group(1)!: match.group(2)!,
  };

  String? size, sizeOverride;
  int? density, densityOverride;
  for (final line in [...section('wm_size'), ...section('wm_density')]) {
    final match = _wm.firstMatch(line.trim());
    if (match == null) continue;
    final physical = match.group(1) == 'Physical';
    final value = match.group(3)!;
    if (match.group(2) == 'size') {
      physical ? size = value : sizeOverride = value;
    } else {
      physical
          ? density = int.tryParse(value)
          : densityOverride = int.tryParse(value);
    }
  }

  return DeviceInfo(
    serial: serial,
    properties: properties,
    screenSize: size,
    screenSizeOverride: sizeOverride,
    density: density,
    densityOverride: densityOverride,
    pageSize: int.tryParse(section('page_size').join().trim()),
    memoryKb: _memTotal(section('meminfo')),
    dataTotalKb: _df(section('df'))?.total,
    dataFreeKb: _df(section('df'))?.free,
    battery: _parseBattery(section('battery')),
    kernel: section('kernel')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .firstOrNull,
  );
}

int? _memTotal(List<String> lines) {
  for (final line in lines) {
    final match = RegExp(r'^MemTotal:\s+(\d+)\s*kB').firstMatch(line.trim());
    if (match != null) return int.parse(match.group(1)!);
  }
  return null;
}

/// `df -k`: a header, then `filesystem 1K-blocks used available use% mount`.
/// A long filesystem name can push the numbers to the next line, so the
/// tokens after the header are read as one row.
({int total, int free})? _df(List<String> lines) {
  final header = lines.indexWhere((line) => line.startsWith('Filesystem'));
  if (header < 0) return null;
  final tokens = lines
      .skip(header + 1)
      .join(' ')
      .split(RegExp(r'\s+'))
      .where((token) => token.isNotEmpty)
      .toList();
  if (tokens.length < 6) return null;
  final total = int.tryParse(tokens[1]);
  final free = int.tryParse(tokens[3]);
  if (total == null || free == null) return null;
  return (total: total, free: free);
}

BatteryInfo? _parseBattery(List<String> lines) {
  int? level, status, temperature;
  for (final line in lines) {
    final match = _battery.firstMatch(line);
    if (match == null) continue;
    final value = int.parse(match.group(2)!);
    switch (match.group(1)) {
      case 'level':
        level ??= value;
      case 'status':
        status ??= value;
      case 'temperature':
        temperature ??= value;
    }
  }
  if (level == null && status == null) return null;
  return BatteryInfo(
    level: level,
    status: BatteryStatus.fromCode(status),
    // dumpsys reports tenths of a degree.
    temperatureC: temperature == null ? null : temperature / 10,
  );
}

/// The device as plain text, to paste in an issue or a chat.
String deviceInfoSummary(DeviceInfo info) {
  final battery = info.battery;
  final lines = <String, String?>{
    'Device': info.displayName,
    'Serial': info.serial,
    'Android': '${info.androidVersion ?? '?'} (API ${info.sdk ?? '?'})',
    'Security patch': info.securityPatch,
    'Build': info.buildId,
    'Build type': [info.buildType, info.buildTags].nonNulls.join(' · '),
    'Fingerprint': info.fingerprint,
    'Kernel': info.kernel,
    'Manufacturer': info.manufacturer,
    'Brand': info.brand,
    'Model': info.model,
    'Codename': info.device,
    'Chip': info.soc,
    'ABIs': info.abis.join(', '),
    'Page size': info.pageSize == null ? null : formatBytes(info.pageSize!),
    'RAM': info.memoryKb == null ? null : formatBytes(info.memoryKb! * 1024),
    'Screen': info.screenSize == null
        ? null
        : '${info.screenSize}${info.density == null ? '' : ' · ${info.density} dpi'}',
    'Battery': battery == null
        ? null
        : '${battery.level ?? '?'}% · ${battery.status.label}',
    'Locale': info.locale,
    'Time zone': info.timeZone,
  };
  return [
    for (final MapEntry(:key, :value) in lines.entries)
      if (value != null && value.isNotEmpty) '$key: $value',
  ].join('\n');
}

// ------------------------------------------------- The APK on the device

/// A package as `dumpsys package` reports it on the device.
class InstalledPackage {
  const InstalledPackage({
    required this.versionCode,
    this.versionName,
    this.lastUpdate,
  });

  final int versionCode;
  final String? versionName;
  final String? lastUpdate;
}

/// What installing an APK would do on the device.
enum InstallOutcome {
  fresh('Not installed: a fresh install.'),
  upgrade('An upgrade.'),
  reinstall('The same versionCode: a reinstall.'),
  downgrade('A downgrade: needs "Allow downgrade", or uninstalling first.');

  const InstallOutcome(this.description);
  final String description;
}

InstallOutcome installOutcome(InstalledPackage? installed, int apkVersionCode) {
  if (installed == null) return InstallOutcome.fresh;
  if (apkVersionCode > installed.versionCode) return InstallOutcome.upgrade;
  if (apkVersionCode == installed.versionCode) return InstallOutcome.reinstall;
  return InstallOutcome.downgrade;
}

final _packageName = RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$');

/// Whether [name] is a valid Android package name. It goes into a device
/// shell command, so nothing else may.
bool isValidPackageName(String name) => _packageName.hasMatch(name);

/// The `adb shell` argument that reads [package]'s installed version.
String installedPackageScript(String package) {
  if (!isValidPackageName(package)) {
    throw ArgumentError.value(package, 'package', 'Not a package name');
  }
  return "dumpsys package $package | grep -E 'versionCode=|versionName=|lastUpdateTime='";
}

final _versionCode = RegExp(r'versionCode=(\d+)');
final _versionName = RegExp(r'versionName=(.*)$');
final _lastUpdate = RegExp(r'lastUpdateTime=(.*)$');

/// `null` when the package isn't installed (grep found nothing). With
/// several entries (a system app plus its update), the first one is the
/// version that runs.
InstalledPackage? parseInstalledPackage(Iterable<String> lines) {
  int? code;
  String? name;
  String? update;
  for (final line in lines) {
    code ??= int.tryParse(_versionCode.firstMatch(line)?.group(1) ?? '');
    name ??= _versionName.firstMatch(line.trim())?.group(1)?.trim();
    update ??= _lastUpdate.firstMatch(line.trim())?.group(1)?.trim();
  }
  if (code == null) return null;
  return InstalledPackage(
    versionCode: code,
    versionName: name,
    lastUpdate: update,
  );
}

/// The ABI Android will pick for an APK on a device: the device's first
/// preference the APK has native code for. `null` when the APK has no native
/// code (any device runs it) or none matches (it won't install).
String? preferredAbi(Iterable<String> apkAbis, List<String> deviceAbis) {
  for (final abi in deviceAbis) {
    if (apkAbis.contains(abi)) return abi;
  }
  return null;
}
