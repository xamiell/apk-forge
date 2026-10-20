import '../system/host.dart';

/// `/a/long/way/out/phone/app.apk` → `…/phone/app.apk`: the file and its
/// folder, for a table cell. Show the whole path in a tooltip.
String shortPath(String path, Host host) {
  final p = host.path;
  final folder = p.basename(p.dirname(path));
  final short = '…${p.separator}$folder${p.separator}${p.basename(path)}';
  return short.length < path.length ? short : path;
}

/// `15728640` → `15.0 MB`.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

/// Lowercase hex without separators, so keytool's `B3:4C:…` and apksigner's
/// `b34c…` compare equal.
String normalizeDigest(String digest) =>
    digest.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '').toLowerCase();

/// `b34c94…` → `B3:4C:94:…`, the form keytool and the Play Console show.
String colonDigest(String digest) {
  final hex = normalizeDigest(digest).toUpperCase();
  final pairs = <String>[];
  for (var index = 0; index + 1 < hex.length; index += 2) {
    pairs.add(hex.substring(index, index + 2));
  }
  return pairs.join(':');
}

/// The first and last characters, enough to recognise a digest at a glance.
String shortDigest(String digest) {
  final colon = colonDigest(digest);
  if (colon.length <= 23) return colon;
  return '${colon.substring(0, 11)}…${colon.substring(colon.length - 11)}';
}

/// `2026-10-19 09:05`: a moment to the minute, as the history shows it.
String formatDateTime(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

/// `42 s`, `2 min 5 s`, `1 h 3 min`: how long a run took.
String formatDuration(Duration duration) {
  final seconds = duration.inSeconds.remainder(60);
  final minutes = duration.inMinutes.remainder(60);
  if (duration.inHours > 0) return '${duration.inHours} h $minutes min';
  if (duration.inMinutes > 0) return '$minutes min $seconds s';
  return '${duration.inSeconds} s';
}
