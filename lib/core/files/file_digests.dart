import 'dart:io';

import 'package:crypto/crypto.dart';

/// [path]'s MD5 (what TMS and store consoles show) and SHA-256, in one read,
/// as lowercase hex.
Future<({String md5, String sha256})> fileDigests(String path) async {
  final md5Sink = _DigestSink();
  final sha256Sink = _DigestSink();
  final md5Input = md5.startChunkedConversion(md5Sink);
  final sha256Input = sha256.startChunkedConversion(sha256Sink);
  await for (final chunk in File(path).openRead()) {
    md5Input.add(chunk);
    sha256Input.add(chunk);
  }
  md5Input.close();
  sha256Input.close();
  return (md5: md5Sink.value.toString(), sha256: sha256Sink.value.toString());
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
