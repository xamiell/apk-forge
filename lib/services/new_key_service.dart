import 'dart:io';

import '../core/process/command.dart';
import '../core/system/host.dart';
import '../domain/failure.dart';
import '../domain/profiles/key_properties.dart';
import '../domain/signing/keystore.dart';
import '../domain/signing/new_key.dart';
import 'tool_executor.dart';

/// Makes a new upload key: the keystore, with keytool, and the
/// `key.properties` Gradle reads next to it, readable by its owner only.
///
/// It writes both or neither. A keystore or `key.properties` already there
/// stops it before keytool runs, since keytool would add the key to an
/// existing keystore; a failure afterwards deletes what it wrote.
class NewKeyService {
  const NewKeyService({required this.host});

  final Host host;

  static const _failed = 'keytool could not make the key';

  Future<void> create(
    ToolExecutor executor, {
    required String keytool,
    required NewKeyRequest request,
  }) async {
    final keystore = File(request.keystorePath);
    final properties = File(request.keyPropertiesPath);
    for (final file in [keystore, properties]) {
      if (await file.exists()) {
        throw ToolFailure(
          'Nothing was written',
          details: ['${file.path} already exists.'],
        );
      }
    }

    final result = await executor.run(
      Command(
        keytool,
        keytoolGenerateKeyArguments(
          request.keystorePath,
          request.alias,
          distinguishedName: request.distinguishedName,
          validityDays: request.validityDays,
          storeType: request.type,
        ),
        environment: request.environment,
        secrets: request.secrets,
      ),
    );
    if (!result.succeeded) {
      // keytool writes the keystore last, but a cancelled one may leave
      // part of it.
      await _delete(keystore);
      if (parseKeytoolError(result.allLines) case final reason?) {
        throw ToolFailure(_failed, details: [reason]);
      }
      throw ToolFailure.fromResult(_failed, result, secrets: request.secrets);
    }

    try {
      await _writeOwnerOnly(
        executor,
        properties,
        formatKeyProperties(request.keyProperties),
      );
    } on Object {
      await _delete(properties);
      await _delete(keystore);
      rethrow;
    }
  }

  /// Writes [content] to [file], which must not exist, readable by its
  /// owner before the passwords go in.
  Future<void> _writeOwnerOnly(
    ToolExecutor executor,
    File file,
    String content,
  ) async {
    try {
      await file.create(exclusive: true);
    } on FileSystemException catch (error) {
      throw _writeFailure(file, error);
    }
    // Windows has no file modes: the file takes the folder's permissions.
    if (host.os != HostOs.windows) {
      final chmod = await executor.run(
        Command('/bin/chmod', ownerOnlyArguments(file.path)),
        echoOutput: false,
      );
      if (!chmod.succeeded) {
        throw ToolFailure.fromResult(
          'Could not make ${file.path} private',
          chmod,
        );
      }
    }
    try {
      await file.writeAsString(content, flush: true);
    } on FileSystemException catch (error) {
      throw _writeFailure(file, error);
    }
  }

  ToolFailure _writeFailure(File file, FileSystemException error) =>
      ToolFailure(
        'Could not write ${file.path}',
        details: [error.osError?.message ?? error.message],
      );

  Future<void> _delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Nothing more to do: the failure that got here is the one to show.
    }
  }
}
