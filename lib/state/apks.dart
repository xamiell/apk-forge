import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/analysis/apk_report.dart';
import '../domain/analysis/comparison.dart';
import '../services/tool_executor.dart';
import 'log_notifier.dart';
import 'providers.dart';
import 'toolchain_notifier.dart';

enum ApkOrigin {
  built('Built'),
  signed('Signed'),
  opened('Opened');

  const ApkOrigin(this.label);
  final String label;
}

class ApkItem {
  const ApkItem(this.path, this.origin);

  final String path;
  final ApkOrigin origin;
}

class ApkList {
  const ApkList({this.items = const [], this.selectedPath});

  /// Newest first.
  final List<ApkItem> items;
  final String? selectedPath;

  ApkItem? get selected {
    for (final item in items) {
      if (item.path == selectedPath) return item;
    }
    return null;
  }
}

/// The APKs of this session: built, signed or opened. Not saved: the files
/// may be gone next time.
final apkListProvider = NotifierProvider<ApkListNotifier, ApkList>(
  ApkListNotifier.new,
);

class ApkListNotifier extends Notifier<ApkList> {
  @override
  ApkList build() => const ApkList();

  /// Adds [path] on top, or moves it there if it's listed, and re-reads its
  /// report: the file may have changed (signed again to the same name).
  ///
  /// Without [select] it's still selected when nothing is: a list with
  /// APKs always has one selected.
  void add(String path, ApkOrigin origin, {bool select = true}) {
    final items = [
      ApkItem(path, origin),
      ...state.items.where((item) => item.path != path),
    ];
    state = ApkList(
      items: items,
      selectedPath: select || state.selectedPath == null
          ? path
          : state.selectedPath,
    );
    ref.invalidate(apkReportProvider(path));
  }

  void select(String path) =>
      state = ApkList(items: state.items, selectedPath: path);

  void remove(String path) {
    final items = state.items.where((item) => item.path != path).toList();
    final selected = state.selectedPath == path
        ? (items.isEmpty ? null : items.first.path)
        : state.selectedPath;
    state = ApkList(items: items, selectedPath: selected);
  }
}

/// The analysis of one APK, read once and kept until the file is added
/// again.
final apkReportProvider = FutureProvider.family<ApkReport, String>((
  ref,
  path,
) async {
  final toolchain = await ref.watch(toolchainProvider.future);
  final log = ref.read(logProvider.notifier);
  log.step('Analyze ${ref.read(hostProvider).path.basename(path)}');
  final executor = ToolExecutor(ref.read(processRunnerProvider), log);
  final report = await ref
      .read(apkAnalyzerProvider)
      .analyze(executor, toolchain: toolchain, path: path);
  log.info(
    report.signature == null
        ? 'Read. Signature not checked: ${report.signatureError}'
        : report.signature!.verifies
        ? 'Read. The signature verifies.'
        : 'Read. The signature does NOT verify.',
  );
  return report;
});

/// [candidate] compared with [reference] as an update over it, from their
/// reports: nothing is read twice.
final apkComparisonProvider =
    FutureProvider.family<
      ApkComparison,
      ({String reference, String candidate})
    >((ref, pair) async {
      final reference = await ref.watch(
        apkReportProvider(pair.reference).future,
      );
      final candidate = await ref.watch(
        apkReportProvider(pair.candidate).future,
      );
      return compareApks(reference, candidate);
    });
