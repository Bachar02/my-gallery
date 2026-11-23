/// Design tokens: spacing, radii, elevation, motion and layout breakpoints.
///
/// Values follow a 4/8-pt grid. Use these instead of literals in widgets.
library;

import 'package:flutter/animation.dart';

/// Spacing scale (4-pt base).
abstract final class AppSpace {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  /// Horizontal page gutter on phones.
  static const double gutter = 16;
}

/// Corner radii.
abstract final class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 28;
  static const double pill = 999;
}

/// Elevation levels (Material 3 tonal elevation is preferred over shadows).
abstract final class AppElevation {
  static const double level0 = 0;
  static const double level1 = 1;
  static const double level2 = 3;
  static const double level3 = 6;
}

/// Motion: short and purposeful only.
abstract final class AppMotion {
  static const Duration short = Duration(milliseconds: 150);
  static const Duration medium = Duration(milliseconds: 250);
  static const Curve standard = Curves.easeOutCubic;
}

/// Layout breakpoints and sizes.
abstract final class AppLayout {
  static const double compact = 600;
  static const double medium = 840;

  /// Max width of single-column content (home, settings) on large screens.
  static const double maxContentWidth = 720;

  /// Minimum touch target.
  static const double minTouchTarget = 48;

  /// Number of columns in the result grid for a given available width.
  static int gridColumns(double width) {
    if (width < 360) return 2;
    if (width < compact) return 3;
    if (width < medium) return 4;
    if (width < 1200) return 5;
    return 6;
  }
}
