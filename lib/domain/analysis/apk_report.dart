import '../../core/zip/zip_directory.dart';
import 'badging.dart';
import 'signature.dart';

/// How the Flutter part of the APK was compiled, read from its files.
enum FlutterCompilation {
  /// `lib/<abi>/libapp.so`: ahead-of-time, as release and profile builds are.
  aot,

  /// `assets/flutter_assets/kernel_blob.bin`: the JIT kernel of a debug build.
  jit,
}

/// What the APK's files say, without any external tool.
class ApkContents {
  const ApkContents({
    this.nativeLibraries = const {},
    this.hasJarSignature = false,
    this.flutter,
    this.entryCount = 0,
  });

  factory ApkContents.fromEntries(List<ZipEntry> entries) {
    final libraries = <String, List<String>>{};
    var jarSignatureFile = false;
    var jarManifest = false;
    var flutterEngine = false;
    var aot = false;
    var jit = false;

    for (final entry in entries) {
      final name = entry.name;
      final parts = name.split('/');
      if (parts.length == 3 && parts[0] == 'lib' && parts[2].endsWith('.so')) {
        libraries.putIfAbsent(parts[1], () => []).add(parts[2]);
        if (parts[2] == 'libflutter.so') flutterEngine = true;
        if (parts[2] == 'libapp.so') aot = true;
      } else if (name == 'META-INF/MANIFEST.MF') {
        jarManifest = true;
      } else if (parts.length == 2 &&
          parts[0] == 'META-INF' &&
          RegExp(r'\.(RSA|DSA|EC)$', caseSensitive: false).hasMatch(parts[1])) {
        jarSignatureFile = true;
      } else if (name == 'assets/flutter_assets/kernel_blob.bin') {
        jit = true;
      }
    }

    for (final list in libraries.values) {
      list.sort();
    }

    return ApkContents(
      nativeLibraries: Map.fromEntries(
        libraries.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
      ),
      hasJarSignature: jarManifest && jarSignatureFile,
      flutter: !flutterEngine && !jit
          ? null
          : aot
          ? FlutterCompilation.aot
          : FlutterCompilation.jit,
      entryCount: entries.length,
    );
  }

  /// ABI folder (`arm64-v8a`) → the `.so` files inside it.
  final Map<String, List<String>> nativeLibraries;

  /// `META-INF/MANIFEST.MF` plus a `.RSA`/`.DSA`/`.EC` block: a v1 (JAR)
  /// signature is present, whether or not apksigner needed to check it.
  final bool hasJarSignature;

  /// `null` when it isn't a Flutter app.
  final FlutterCompilation? flutter;
  final int entryCount;

  bool get isFlutterApp => flutter != null;

  /// ABIs that have native code but no Flutter engine. A device that picks
  /// one of them installs the app and crashes at launch
  /// (`System.loadLibrary("flutter")`): a plugin's own `.so` files make the
  /// APK advertise an ABI that `--target-platform` left out.
  List<String> get abisWithoutFlutterEngine {
    if (!isFlutterApp) return const [];
    return [
      for (final MapEntry(key: abi, value: libraries)
          in nativeLibraries.entries)
        if (!libraries.contains('libflutter.so')) abi,
    ];
  }
}

/// Everything the Analyze panel shows about one APK.
class ApkReport {
  const ApkReport({
    required this.path,
    required this.sizeBytes,
    required this.md5,
    required this.sha256,
    required this.contents,
    this.contentsError,
    this.badging,
    this.badgingError,
    this.signature,
    this.signatureError,
  });

  final String path;
  final int sizeBytes;
  final String md5;
  final String sha256;

  final ApkContents contents;
  final String? contentsError;

  /// `null` with [badgingError] set when aapt2 is missing or failed.
  final Badging? badging;
  final String? badgingError;

  /// `null` with [signatureError] set when apksigner is missing or crashed.
  final SignatureReport? signature;
  final String? signatureError;

  /// This report with other contents: an installed app's `base.apk` with
  /// the native code of its splits, or the reason they couldn't be read.
  ApkReport withContents(
    ApkContents contents, {
    String? contentsError,
    int? sizeBytes,
  }) => ApkReport(
    path: path,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    md5: md5,
    sha256: sha256,
    contents: contents,
    contentsError: contentsError,
    badging: badging,
    badgingError: badgingError,
    signature: signature,
    signatureError: signatureError,
  );

  bool get hasJarSignature => contents.hasJarSignature;

  /// Release or debug, as Android sees it: the manifest's debuggable flag.
  /// `null` when aapt2 couldn't read the manifest.
  bool? get isDebuggable => badging?.debuggable;
}
