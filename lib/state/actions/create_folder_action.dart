import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../profiles.dart';
import '../providers.dart';

/// Creates a target's output folder that doesn't exist yet, when the user
/// asks for it. A run never creates one on its own: a path from another
/// machine, or mistyped, would leave folders where nobody expects them.
class CreateFolderAction {
  const CreateFolderAction({required this.create, required this.onCreated});

  final FolderCreator create;

  /// After the folder exists: the targets are checked again.
  final void Function() onCreated;

  /// `null` once [path] exists, or why it couldn't be created.
  Future<String?> run(String path) async {
    try {
      await create(path);
    } on FileSystemException catch (error) {
      return 'Could not create $path: '
          '${error.osError?.message ?? error.message}';
    }
    onCreated();
    return null;
  }
}

final createFolderActionProvider = Provider(
  (ref) => CreateFolderAction(
    create: ref.watch(folderCreatorProvider),
    onCreated: () => ref.invalidate(targetProblemsProvider),
  ),
);
