import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/format.dart';
import '../../core/system/host.dart';
import '../../domain/failure.dart';
import '../../domain/signing/keystore.dart';
import '../../domain/signing/new_key.dart';
import '../../domain/tools/toolchain.dart';
import '../../services/new_key_service.dart';
import '../../services/signing_service.dart';
import '../forms.dart';
import '../providers.dart';
import '../task_notifier.dart';
import '../toolchain_notifier.dart';

/// Makes the key the New key sheet describes, then loads it in Sign.
class NewKeyAction {
  const NewKeyAction({
    required this.task,
    required this.toolchain,
    required this.keys,
    required this.keystore,
    required this.host,
    required this.probe,
    required this.clock,
    required this.onCreated,
  });

  final TaskRunner task;
  final ToolchainSource toolchain;
  final NewKeyService keys;
  final KeystoreService keystore;
  final Host host;
  final FileProbe probe;
  final DateTime Function() clock;

  /// Gets the key just made and its keystore's keys, for Sign to use.
  final void Function(NewKeyRequest request, List<KeystoreEntry> entries)
  onCreated;

  /// Whether the key was made. A failure is the task's, in the error panel.
  Future<bool> run(NewKeyForm form) async {
    final made = await task.run('New key', (executor) async {
      final today = clock();
      final problems = newKeyProblems(
        form,
        host: host,
        probe: probe,
        today: today,
      );
      if (problems.isNotEmpty) {
        throw ToolFailure(
          'The key can\'t be made yet',
          details: [for (final problem in problems) problem.message],
        );
      }
      final keytool = (await toolchain()).keytool;
      if (keytool == null) throw keytoolMissing;

      final request = form.toRequest(host, today);
      await keys.create(executor, keytool: keytool, request: request);
      executor.log.info('Wrote ${request.keystorePath}');
      executor.log.info(
        'Wrote ${request.keyPropertiesPath}, which only you can read.',
      );

      final entries = await keystore.listEntries(
        executor,
        keytool: keytool,
        keystorePath: request.keystorePath,
        password: request.storePassword,
      );
      onCreated(request, entries);
      for (final entry in entries) {
        executor.log.info('${entry.alias}: ${entry.owner ?? '?'}');
        if (entry.sha1 case final sha1?) {
          executor.log.info('SHA-1    ${colonDigest(sha1)}');
        }
        if (entry.sha256 case final sha256?) {
          executor.log.info('SHA-256  ${colonDigest(sha256)}');
        }
      }
      executor.log.success(
        'Key made and loaded in Sign. Back up '
        '${host.path.basename(request.keystorePath)} and '
        '$keyPropertiesFileName together.',
      );
      return true;
    });
    return made ?? false;
  }
}

final newKeyActionProvider = Provider(
  (ref) => NewKeyAction(
    task: ref.watch(taskProvider.notifier),
    toolchain: () => ref.read(toolchainProvider.future),
    keys: ref.watch(newKeyServiceProvider),
    keystore: ref.watch(keystoreServiceProvider),
    host: ref.watch(hostProvider),
    probe: ref.watch(fileProbeProvider),
    clock: ref.watch(clockProvider),
    onCreated: (request, entries) => ref
        .read(signingFormProvider.notifier)
        .useKey(
          keystorePath: request.keystorePath,
          storePassword: request.storePassword,
          keyPassword: request.keyPassword == request.storePassword
              ? null
              : request.keyPassword,
          entries: entries,
          alias: request.alias,
        ),
  ),
);

/// What stops the New key sheet's [NewKeyForm] from making a key.
final newKeyProblemsProvider = Provider.autoDispose
    .family<List<NewKeyProblem>, NewKeyForm>(
      (ref, form) => newKeyProblems(
        form,
        host: ref.watch(hostProvider),
        probe: ref.watch(fileProbeProvider),
        today: ref.watch(clockProvider)(),
      ),
    );
