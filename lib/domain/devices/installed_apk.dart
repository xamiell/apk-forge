import 'package:path/path.dart' as p;

import '../../core/zip/zip_directory.dart';
import '../analysis/apk_report.dart';
import 'device_info.dart';

/// `adb` arguments that list the APK files [package] is installed from.
/// [package] goes into the device shell, so it must be a package name.
List<String> adbPackagePathArguments(String serial, String package) {
  if (!isValidPackageName(package)) {
    throw ArgumentError.value(package, 'package', 'Not a package name');
  }
  return ['-s', serial, 'shell', 'pm', 'path', package];
}

/// `adb` arguments that copy [remote], a file on the device, to [local].
List<String> adbPullArguments(String serial, String remote, String local) => [
  '-s',
  serial,
  'pull',
  remote,
  local,
];

/// The APK files `pm path` lists, one `package:<path>` line each. Empty when
/// the package isn't installed (it prints nothing and exits 1).
List<String> parsePackagePaths(Iterable<String> lines) => [
  for (final line in lines)
    if (line.trim() case final path
        when path.startsWith('package:/') && path.endsWith('.apk'))
      path.substring('package:'.length),
];

/// Which of an installed app's files to copy from the device to compare it.
///
/// An app installed from an App Bundle is a `base.apk` (code, manifest,
/// signature) plus config splits: one per ABI with the native code, and
/// others for languages and screen densities, which are resources only and
/// stay on the device.
class InstalledApkFiles {
  const InstalledApkFiles({
    required this.base,
    this.abiSplits = const [],
    this.notPulled = const [],
  });

  /// From [parsePackagePaths]'s list: `base.apk`, or the only file.
  factory InstalledApkFiles.from(List<String> paths) {
    final base = paths.firstWhere(
      (path) => p.posix.basename(path) == 'base.apk',
      orElse: () => paths.first,
    );
    final rest = [
      for (final path in paths)
        if (path != base) path,
    ];
    return InstalledApkFiles(
      base: base,
      abiSplits: rest.where(isAbiSplit).toList(),
      notPulled: rest.where((path) => !isAbiSplit(path)).toList(),
    );
  }

  /// Device paths.
  final String base;
  final List<String> abiSplits;
  final List<String> notPulled;

  /// Installed as several APKs: an App Bundle, or splits from a build.
  bool get isSplit => abiSplits.isNotEmpty || notPulled.isNotEmpty;

  /// `base.apk + split_config.arm64_v8a.apk`, for a comparison's header.
  String get pulledNames =>
      [base, ...abiSplits].map(p.posix.basename).join(' + ');

  String get notPulledNames => notPulled.map(p.posix.basename).join(', ');
}

final _abiSplit = RegExp(
  r'^split_config\.(arm64_v8a|armeabi_v7a|armeabi|x86_64|x86|mips64|mips)\.apk$',
);

/// `split_config.arm64_v8a.apk`: the config split with one ABI's native
/// code. Bundletool writes the ABI with `_` for `-`.
bool isAbiSplit(String path) => _abiSplit.hasMatch(p.posix.basename(path));

/// The contents of an app installed as [base] plus ABI splits: the base's
/// files, and the native code of each split.
ApkContents installedContents(
  List<ZipEntry> base,
  List<List<ZipEntry>> abiSplits,
) => ApkContents.fromEntries([
  ...base,
  for (final split in abiSplits)
    ...split.where((entry) => entry.name.startsWith('lib/')),
]);
