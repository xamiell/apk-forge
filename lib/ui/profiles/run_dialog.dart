import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/actions/profile_run_action.dart';
import '../../state/profiles.dart';
import 'run_check.dart';
import 'run_progress.dart';

/// Runs the profile [profileId]: pick the APKs, see the checks and the plan,
/// then the progress and the results.
Future<void> showRunProfileDialog(BuildContext context, String profileId) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RunProfileDialog(profileId: profileId),
    );

class _RunProfileDialog extends ConsumerStatefulWidget {
  const _RunProfileDialog({required this.profileId});

  final String profileId;

  @override
  ConsumerState<_RunProfileDialog> createState() => _RunProfileDialogState();
}

class _RunProfileDialogState extends ConsumerState<_RunProfileDialog> {
  final _inputs = <String>[];
  var _started = false;

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(
      profilesProvider.select((state) => state.byId(widget.profileId)),
    );
    if (profile == null) return const SizedBox.shrink();
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: _started
            ? RunProgressView(profile: profile)
            : RunCheckView(
                profile: profile,
                inputs: _inputs,
                onInputs: (inputs) => setState(() {
                  _inputs
                    ..clear()
                    ..addAll(inputs);
                }),
                onRun: (check) {
                  setState(() => _started = true);
                  ref.read(profileRunActionProvider).run(profile, check);
                },
              ),
      ),
    );
  }
}
