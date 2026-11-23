/// Color tokens for light and dark themes.
///
/// The palette is generated from a calm "lagoon" teal seed with a warm
/// tertiary accent, plus a few semantic roles Material does not provide
/// (success, warning, search-term highlight) exposed as a [ThemeExtension].
library;

import 'package:flutter/material.dart';

abstract final class AppColors {
  /// Brand seed: deep lagoon teal.
  static const Color seed = Color(0xFF1B6B73);

  /// Warm accent used for the tertiary role.
  static const Color accent = Color(0xFFB4652A);

  static ColorScheme scheme(Brightness brightness) {
    final base = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
    );
    final accentScheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness);
    return base.copyWith(
      tertiary: accentScheme.primary,
      onTertiary: accentScheme.onPrimary,
      tertiaryContainer: accentScheme.primaryContainer,
      onTertiaryContainer: accentScheme.onPrimaryContainer,
    );
  }
}

/// Semantic colors not covered by [ColorScheme].
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  const AppSemanticColors({
    required this.success,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.highlight,
    required this.onHighlight,
  });

  static const light = AppSemanticColors(
    success: Color(0xFF2E7D4F),
    successContainer: Color(0xFFCDEFD8),
    onSuccessContainer: Color(0xFF0B3D20),
    warning: Color(0xFF8A5A00),
    warningContainer: Color(0xFFFFE4B5),
    onWarningContainer: Color(0xFF3D2800),
    highlight: Color(0xFFFFE28A),
    onHighlight: Color(0xFF231B00),
  );

  static const dark = AppSemanticColors(
    success: Color(0xFF8BD6A6),
    successContainer: Color(0xFF1C4D30),
    onSuccessContainer: Color(0xFFCDEFD8),
    warning: Color(0xFFF5C26B),
    warningContainer: Color(0xFF5A3D00),
    onWarningContainer: Color(0xFFFFE4B5),
    highlight: Color(0xFF5C4A00),
    onHighlight: Color(0xFFFFF1C2),
  );

  final Color success;
  final Color successContainer;
  final Color onSuccessContainer;
  final Color warning;
  final Color warningContainer;
  final Color onWarningContainer;

  /// Background of matched search terms inside text snippets.
  final Color highlight;
  final Color onHighlight;

  static AppSemanticColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppSemanticColors>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  AppSemanticColors copyWith({
    Color? success,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warning,
    Color? warningContainer,
    Color? onWarningContainer,
    Color? highlight,
    Color? onHighlight,
  }) =>
      AppSemanticColors(
        success: success ?? this.success,
        successContainer: successContainer ?? this.successContainer,
        onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
        warning: warning ?? this.warning,
        warningContainer: warningContainer ?? this.warningContainer,
        onWarningContainer: onWarningContainer ?? this.onWarningContainer,
        highlight: highlight ?? this.highlight,
        onHighlight: onHighlight ?? this.onHighlight,
      );

  @override
  AppSemanticColors lerp(AppSemanticColors? other, double t) {
    if (other == null) return this;
    return AppSemanticColors(
      success: Color.lerp(success, other.success, t)!,
      successContainer: Color.lerp(successContainer, other.successContainer, t)!,
      onSuccessContainer: Color.lerp(onSuccessContainer, other.onSuccessContainer, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningContainer: Color.lerp(warningContainer, other.warningContainer, t)!,
      onWarningContainer: Color.lerp(onWarningContainer, other.onWarningContainer, t)!,
      highlight: Color.lerp(highlight, other.highlight, t)!,
      onHighlight: Color.lerp(onHighlight, other.onHighlight, t)!,
    );
  }
}
