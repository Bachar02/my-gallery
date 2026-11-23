/// Target sizes for platform-decoded thumbnails.
library;

import 'dart:math' as math;

/// Size to request from the platform decoder so the *longest* side of the
/// result is [longestSide] while keeping the aspect ratio of a
/// [width] x [height] image (display orientation). Never upscales beyond
/// the source. Unknown dimensions (0) yield a square request.
///
/// photo_manager decodes with Glide's default CENTER_OUTSIDE strategy, which
/// makes both sides at least the requested size. Requesting the exact
/// aspect-correct box therefore yields an image whose longest side is
/// [longestSide].
({int width, int height}) fitWithin(int width, int height, int longestSide) {
  assert(longestSide > 0, 'longestSide must be positive');
  if (width <= 0 || height <= 0) {
    return (width: longestSide, height: longestSide);
  }
  final longest = math.max(width, height);
  final target = math.min(longestSide, longest);
  final scale = target / longest;
  return (
    width: math.max(1, (width * scale).round()),
    height: math.max(1, (height * scale).round()),
  );
}
