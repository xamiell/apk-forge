import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/failure.dart';
import '../../domain/signing/keystore.dart';
import '../../services/signing_service.dart';
import '../forms.dart';
import '../providers.dart';
import '../task_notifier.dart';
import '../toolchain_notifier.dart';

/// Reads the keys of the keystore in Sign, with its password.
class LoadKeysAction {
  const LoadKeysAction({
    required this.task,
    required this.toolchain,
    required this.form,
    required this.keystore,
    required this.onLoaded,
  });

  final TaskRunner task;
  final ToolchainSource toolchain;
  final SigningForm Function() form;
  final KeystoreService keystore;

  /// Gets the keys read, for Sign to offer.
  final void Function(List<KeystoreEntry> entries) onLoaded;

  Future<void> run() async {
    final form = this.form();
    await task.run('Load keys', (executor) async {
      final keytool = (await toolchain()).keytool;
      if (keytool == null) {
        throw const ToolFailure(
          'keytool was not found',
          details: ['Install a JDK, or set JAVA_HOME.'],
        );
      }
      final entries = await keystore.listEntries(
        executor,
        keytool: keytool,
        keystorePath: form.keystorePath.trim(),
        password: form.storePassword,
      );
      onLoaded(entries);
      for (final entry in entries) {
        executor.log.info(
          '${entry.alias}: ${entry.owner ?? '?'}'
          '${entry.canSign ? '' : ' (certificate only)'}',
        );
      }
      executor.log.success(
        '${entries.length} key${entries.length == 1 ? '' : 's'} loaded.',
      );
    });
  }
}

final loadKeysActionProvider = Provider(
  (ref) => LoadKeysAction(
    task: ref.watch(taskProvider.notifier),
    toolchain: () => ref.read(toolchainProvider.future),
    form: () => ref.read(signingFormProvider),
    keystore: ref.watch(keystoreServiceProvider),
    onLoaded: ref.watch(signingFormProvider.notifier).setEntries,
  ),
);
