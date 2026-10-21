import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/actions/create_folder_action.dart';

/// Creates a folder that doesn't exist yet, and says so if it can't.
class CreateFolderButton extends ConsumerWidget {
  const CreateFolderButton({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton.icon(
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      visualDensity: VisualDensity.compact,
    ),
    onPressed: () async {
      final failure = await ref.read(createFolderActionProvider).run(path);
      if (failure != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(failure), behavior: SnackBarBehavior.floating),
        );
      }
    },
    icon: const Icon(Icons.create_new_folder_outlined, size: 16),
    label: const Text('Create folder'),
  );
}
