import 'dart:typed_data';

import 'rgb_image.dart';

/// 64-bit difference hash (dHash) for near-duplicate detection.
///
/// The image is converted to 8-bit luma, shrunk to 9x8 with an antialiased
/// bilinear filter, and bit `row * 8 + col` is set when a pixel is brighter
/// than its right-hand neighbour. Robust to re-encoding, scaling and small
/// brightness changes; burst shots of the same scene usually differ by only a
/// few bits. Pure Dart and synchronous: run it in a background isolate.
abstract final class DHash {
  /// Hash of encoded image bytes. Throws [FormatException] if undecodable.
  static int ofEncoded(Uint8List encoded) => ofImage(PackedImage.decodeRgb(encoded));

  static int ofImage(PackedImage image) {
    final small = image.toGray().resizeBilinear(9, 8);
    final p = small.data;
    var hash = 0;
    for (var row = 0; row < 8; row++) {
      for (var col = 0; col < 8; col++) {
        if (p[row * 9 + col] > p[row * 9 + col + 1]) {
          hash |= 1 << (row * 8 + col);
        }
      }
    }
    return hash;
  }

  /// Number of differing bits between two hashes.
  static int distance(int a, int b) {
    var x = a ^ b;
    var count = 0;
    while (x != 0) {
      x &= x - 1;
      count++;
    }
    return count;
  }
}
