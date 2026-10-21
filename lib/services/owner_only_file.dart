import 'dart:io';

import '../core/process/command.dart';
import '../core/system/host.dart';
import '../domain/failure.dart';
import '../domain/signing/new_key.dart';
import 'tool_executor.dart';

/// Writes [content] to [file], which must not exist, readable by its owner
/// only before anything goes in: a password never sits in a file others
/// can read. Windows has no file modes, so there the file takes its
/// folder's permissions.
Future<void> writeOwnerOnly(
  ToolExecutor executor,
  Host host,
  File file,
  String content,
) async {
  try {
    await file.create(exclusive: true);
  } on FileSystemException catch (error) {
    throw _writeFailure(file, error);
  }
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

ToolFailure _writeFailure(File file, FileSystemException error) => ToolFailure(
  'Could not write ${file.path}',
  details: [error.osError?.message ?? error.message],
);
