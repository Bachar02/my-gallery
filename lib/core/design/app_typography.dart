/// Typography scale. Uses the platform font (Roboto on Android) so nothing
/// is bundled or downloaded; weights and spacing are tuned for a calm,
/// assistant-like tone.
library;

import 'package:flutter/material.dart';

abstract final class AppTypography {
  static TextTheme tune(TextTheme base) => base.copyWith(
        displaySmall: base.displaySmall?.copyWith(fontWeight: FontWeight.w500, letterSpacing: -0.5),
        headlineMedium: base.headlineMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.25),
        headlineSmall: base.headlineSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
        titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.1),
        titleSmall: base.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        bodyLarge: base.bodyLarge?.copyWith(height: 1.5),
        bodyMedium: base.bodyMedium?.copyWith(height: 1.45),
        labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      );
}
