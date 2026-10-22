import '../../core/system/host.dart';
import 'key_properties.dart';
import 'profile.dart';

/// The fields of a target that can stop it from running.
enum TargetField { key, schemes, outputFolder }

/// One thing that stops a target from running, and the field it's about.
class TargetProblem {
  const TargetProblem(this.field, this.message, {this.missingPath});

  final TargetField field;

  /// A sentence about the target, without its name: "Choose its output
  /// folder.". [describeTargetProblem] adds the name.
  final String message;

  /// The path that doesn't exist on this machine, when that's the problem.
  final String? missingPath;

  @override
  bool operator ==(Object other) =>
      other is TargetProblem &&
      other.field == field &&
      other.message == message &&
      other.missingPath == missingPath;

  @override
  int get hashCode => Object.hash(field, message, missingPath);

  @override
  String toString() => '${field.name}: $message';
}

/// What stops [target] from running, field by field, in the order of the
/// target editor: the key, the schemes, the output folder.
///
/// Every screen and the run check use this, so they can't disagree.
/// [keySummary] is what its `key.properties` says once it's read; without it
/// only that the file exists is checked.
List<TargetProblem> targetProblems(
  ProfileTarget target, {
  required FileProbe probe,
  KeyFileSummary? keySummary,
}) {
  final key = target.keyProperties.trim();
  final folder = target.outputDir.trim();
  return [
    if (key.isEmpty)
      const TargetProblem(TargetField.key, 'Choose its key.properties file.')
    else if (!probe.fileExists(key))
      TargetProblem(
        TargetField.key,
        'Its key.properties does not exist on this machine.',
        missingPath: key,
      )
    else if (keySummary != null) ...[
      if (keySummary.error case final error?)
        TargetProblem(
          TargetField.key,
          'Its key.properties can\'t be read: $error',
        )
      else ...[
        if (keySummary.missing.isNotEmpty)
          TargetProblem(
            TargetField.key,
            'Its key.properties has no ${keySummary.missing.join(', ')}.',
          ),
        if (keySummary.keystorePath case final keystore?
            when !keySummary.keystoreExists)
          TargetProblem(
            TargetField.key,
            'Its keystore does not exist: $keystore',
          ),
      ],
    ],
    if (target.schemes?.problem case final problem?)
      TargetProblem(TargetField.schemes, problem),
    if (folder.isEmpty)
      const TargetProblem(TargetField.outputFolder, 'Choose its output folder.')
    else if (!probe.directoryExists(folder))
      TargetProblem(
        TargetField.outputFolder,
        'Its output folder does not exist on this machine.',
        missingPath: folder,
      ),
  ];
}

/// [problem] as the run check and the Profiles list say it, with the
/// target's name: "Phone: Choose its output folder.".
String describeTargetProblem(ProfileTarget target, TargetProblem problem) =>
    '${target.name}: ${problem.message}';
