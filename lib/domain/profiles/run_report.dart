import '../../core/format/format.dart';
import 'profile.dart';
import 'profile_run.dart';

/// What a field says when the record was saved before the history kept it.
const notRecorded = 'Not recorded';

/// One line of a run's report: a label and its value.
class ReportLine {
  const ReportLine(this.label, this.value, {this.mono = false});

  final String label;
  final String value;

  /// A path or a digest, shown in a fixed-width font.
  final bool mono;

  @override
  String toString() => '$label: $value';
}

/// One input of a run, in its report.
class InputReport {
  const InputReport({required this.input, required this.lines});

  final RunInput input;
  final List<ReportLine> lines;
}

/// One target of a run, in its report.
class TargetReport {
  const TargetReport({
    required this.result,
    required this.title,
    required this.lines,
  });

  final TargetResult result;

  /// The target's name, and its input's when the run had several.
  final String title;
  final List<ReportLine> lines;
}

/// A run as its History detail shows it, and as Copy and Export write it.
class RunReport {
  const RunReport({
    required this.title,
    required this.run,
    required this.inputs,
    required this.targets,
  });

  /// `Release, 2026-10-19 09:05`.
  final String title;
  final List<ReportLine> run;
  final List<InputReport> inputs;

  /// One per result of the run, in its order.
  final List<TargetReport> targets;
}

/// [record] as a report: when, how long, the profile as it was, the tools,
/// each input, then how each target was signed. A field the record doesn't
/// have says [notRecorded]; nothing is filled in from today's profile.
RunReport runReport(ProfileRunRecord record) {
  final detailed = record.hasDetails;
  String unknown() => detailed ? 'Unknown' : notRecorded;
  final several = record.inputs.length > 1;

  return RunReport(
    title: '${record.profileName}, ${formatDateTime(record.startedAt)}',
    run: [
      ReportLine('Outcome', record.outcome.label),
      ReportLine('Results', record.summary),
      ReportLine('Started', formatDateTime(record.startedAt)),
      ReportLine(
        'Took',
        formatDuration(record.finishedAt.difference(record.startedAt)),
      ),
      ReportLine('Profile', record.profileName),
      ReportLine('Build-tools', record.buildToolsVersion ?? unknown()),
      ReportLine(
        'File names',
        record.fileNamePattern ?? notRecorded,
        mono: record.fileNamePattern != null,
      ),
      ReportLine('Input checks', switch (record.inputChecks) {
        null => notRecorded,
        final checks => describeInputChecks(checks),
      }),
    ],
    inputs: [
      for (final input in record.inputs)
        InputReport(
          input: input,
          lines: [
            ReportLine('Package', input.packageName ?? 'Unknown'),
            ReportLine('Version', input.version ?? 'Unknown'),
            ReportLine('minSdk', input.minSdk?.toString() ?? unknown()),
            ReportLine('Signature', switch (input.unsigned) {
              true => 'None: it was unsigned',
              false => 'It was already signed',
              null => unknown(),
            }),
            if (input.sha256.isEmpty)
              const ReportLine('SHA-256', 'Unknown')
            else
              ReportLine('SHA-256', input.sha256, mono: true),
          ],
        ),
    ],
    targets: [
      for (final result in record.results)
        TargetReport(
          result: result,
          title: several ? '${result.target} · ${result.input}' : result.target,
          lines: _targetLines(
            result,
            minSdk: record.inputs
                .where((input) => input.name == result.input)
                .firstOrNull
                ?.minSdk,
          ),
        ),
    ],
  );
}

List<ReportLine> _targetLines(TargetResult result, {int? minSdk}) {
  final setup = result.setup;
  final signed = result.status == TargetStatus.signed;
  return [
    ReportLine('ABI', setup == null ? notRecorded : _abi(setup, signed)),
    ReportLine('Key alias', switch (setup) {
      null => notRecorded,
      TargetSetup(keyAlias: final alias?) => alias,
      _ => 'Not opened',
    }),
    ReportLine(
      'key.properties',
      setup?.keyProperties ?? notRecorded,
      mono: setup != null,
    ),
    ReportLine(
      'Schemes asked',
      setup == null ? notRecorded : describeRequestedSchemes(setup),
    ),
    if (setup?.copiedFrom case final source?)
      ReportLine(
        'Signing',
        'Shared with $source: signed once, copied to each folder',
      ),
    if (signed) ...[
      ReportLine('Schemes verified', switch (result.verifiedSchemes) {
        null => notRecorded,
        final verified => describeVerifiedSchemes(
          verified,
          hasJarSignature: result.hasJarSignature,
          minSdk: minSdk,
        ),
      }),
      ReportLine('Signer', result.signerDistinguishedName ?? notRecorded),
      switch (result.signerSha256) {
        null => const ReportLine('Signer SHA-256', 'Unknown'),
        final digest => ReportLine(
          'Signer SHA-256',
          colonDigest(digest),
          mono: true,
        ),
      },
      ReportLine('Output', result.outputPath ?? 'Unknown', mono: true),
      if (result.sizeBytes case final size?)
        ReportLine('Size', formatBytes(size)),
      switch (result.outputSha256) {
        null => const ReportLine('Output SHA-256', notRecorded),
        final digest => ReportLine('Output SHA-256', digest, mono: true),
      },
    ] else
      ReportLine('Reason', result.reason ?? 'Unknown'),
  ];
}

/// `arm64-v8a: cut from the input`, or how it was signed whole.
String _abi(TargetSetup setup, bool signed) {
  if (!signed) return setup.abi;
  if (setup.abi == ProfileTarget.universalAbiName) {
    return '${setup.abi}: the input as it was';
  }
  return setup.cut
      ? '${setup.abi}: cut from the input'
      : '${setup.abi}: the input as it was, with nothing else to leave out';
}

/// `Package com.example.app; must be unsigned`, or `None`.
String describeInputChecks(InputChecks checks) {
  final parts = [
    if (checks.packageName case final package?) 'Package $package',
    if (checks.mustBeUnsigned) 'must be unsigned',
  ];
  if (parts.isEmpty) return 'None';
  final text = parts.join('; ');
  return text[0].toUpperCase() + text.substring(1);
}

/// The schemes asked of apksigner, and where they came from: `v2, v3 (its
/// own)`, `Auto (from Defaults)`.
String describeRequestedSchemes(TargetSetup setup) {
  final schemes = setup.schemes.isAutomatic
      ? 'Auto, apksigner\'s choice by minSdk'
      : setup.schemes.label;
  return '$schemes (${setup.schemesFromDefaults ? 'from Defaults' : 'its own'})';
}

/// What apksigner verified: `v2, v3, v4`.
///
/// apksigner only checks the schemes the APK's minSdk range needs, so from
/// minSdk 24 it reports v1 as not verified even when the APK carries one.
/// A JAR signature found in the files ([hasJarSignature]) is said to be
/// there but not checked, never missing.
String describeVerifiedSchemes(
  Map<String, bool> verified, {
  bool? hasJarSignature,
  int? minSdk,
}) {
  final schemes = [
    for (final MapEntry(:key, :value) in verified.entries)
      if (value) key,
  ];
  final v1NotChecked = verified['v1'] != true && hasJarSignature == true;
  return [
    if (schemes.isNotEmpty) schemes.join(', ') else if (!v1NotChecked) 'None',
    if (v1NotChecked)
      minSdk != null && minSdk >= 24
          ? 'v1 there, not checked: apksigner skips it from minSdk 24'
          : 'v1 there, not checked by apksigner',
  ].join('; ');
}

/// [report] as plain text, for a release note or a ticket.
String runReportText(RunReport report) {
  final text = StringBuffer();
  void write(List<ReportLine> lines, String indent) {
    final width = lines.fold(
      0,
      (width, line) => line.label.length > width ? line.label.length : width,
    );
    for (final line in lines) {
      text.writeln('$indent${line.label.padRight(width)}  ${line.value}');
    }
  }

  text
    ..writeln('APK Forge run: ${report.title}')
    ..writeln();
  write(report.run, '');
  for (final input in report.inputs) {
    text
      ..writeln()
      ..writeln('Input ${input.input.name}');
    write(input.lines, '  ');
  }
  for (final target in report.targets) {
    text
      ..writeln()
      ..writeln('Target ${target.title}: ${target.result.status.label}');
    write(target.lines, '  ');
  }
  text
    ..writeln()
    ..writeln('Paths, versions and digests; never a password.');
  return text.toString();
}

/// `Release run 2026-10-19 0905.txt`: where Export suggests saving
/// [record]'s report.
String runReportFileName(ProfileRunRecord record) {
  final moment = formatDateTime(record.startedAt).replaceAll(':', '');
  return safeFileName('${record.profileName} run $moment.txt');
}
