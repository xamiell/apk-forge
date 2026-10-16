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
