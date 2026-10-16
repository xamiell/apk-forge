import 'package:flutter/material.dart';

import '../core/logging/log_entry.dart';
import '../domain/analysis/findings.dart';

const _seed = Color(0xFF2E7D5B);

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  final dark = brightness == Brightness.dark;
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.compact,
    scaffoldBackgroundColor: scheme.surfaceContainerLowest,
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      isDense: true,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    extensions: [dark ? StatusColors.dark : StatusColors.light],
  );
}

/// The colors that mean something (ok, warning, error), the log's included.
/// Widgets read them by role, never as literals.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({
    required this.ok,
    required this.info,
    required this.warning,
    required this.error,
    required this.muted,
    required this.command,
    required this.step,
    required this.logBackground,
    required this.logText,
  });

  static const light = StatusColors(
    ok: Color(0xFF1B7F3B),
    info: Color(0xFF1F5FAF),
    warning: Color(0xFF9A6200),
    error: Color(0xFFB3261E),
    muted: Color(0xFF6B7280),
    command: Color(0xFF6D28D9),
    step: Color(0xFF0F172A),
    logBackground: Color(0xFFF8FAFC),
    logText: Color(0xFF1F2937),
  );

  static const dark = StatusColors(
    ok: Color(0xFF6DD58C),
    info: Color(0xFF8AB4F8),
    warning: Color(0xFFF2B84B),
    error: Color(0xFFF28B82),
    muted: Color(0xFF9CA3AF),
    command: Color(0xFFC4A7FF),
    step: Color(0xFFF1F5F9),
    logBackground: Color(0xFF0B1220),
    logText: Color(0xFFD1D5DB),
  );

  final Color ok;
  final Color info;
  final Color warning;
  final Color error;
  final Color muted;
  final Color command;
  final Color step;
  final Color logBackground;
  final Color logText;

  Color forFinding(FindingLevel level) => switch (level) {
    FindingLevel.ok => ok,
    FindingLevel.info => info,
    FindingLevel.warning => warning,
    FindingLevel.error => error,
  };

  Color forLog(LogKind kind) => switch (kind) {
    LogKind.step => step,
    LogKind.command => command,
    LogKind.stdout => logText,
    LogKind.stderr => muted,
    LogKind.info => info,
    LogKind.warning => warning,
    LogKind.success => ok,
    LogKind.error => error,
  };

  @override
  StatusColors copyWith() => this;

  @override
  StatusColors lerp(StatusColors? other, double t) =>
      t < 0.5 || other == null ? this : other;
}

extension StatusColorsContext on BuildContext {
  StatusColors get status => Theme.of(this).extension<StatusColors>()!;
}

const monospace = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['SF Mono', 'Consolas', 'DejaVu Sans Mono', 'monospace'],
  fontSize: 12,
  height: 1.35,
);
