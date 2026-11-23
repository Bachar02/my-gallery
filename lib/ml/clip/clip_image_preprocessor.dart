import 'dart:typed_data';

import '../image/rgb_image.dart';

/// Image -> model input tensor, exactly as `preprocessor_config.json` of the
/// MobileCLIP-S0 export specifies:
///
/// ```
/// do_convert_rgb: true
/// do_resize: true,  size.shortest_edge: 256, resample: 2 (PIL bilinear)
/// do_center_crop: true, crop_size: 256x256
/// do_rescale: true, rescale_factor: 1/255
/// do_normalize: false          (MobileCLIP takes [0, 1] RGB, no mean/std)
/// ```
///
/// Output layout is NCHW float32 `[1, 3, 256, 256]`, flattened.
///
/// Pure Dart and synchronous: callers run it in a background isolate.
abstract final class ClipImagePreprocessor {
  static const int size = 256;
  static const double rescaleFactor = 1 / 255;

  /// Decodes [encoded] (JPEG/PNG/...) and returns the input tensor.
  /// Throws [FormatException] if the bytes cannot be decoded.
  static Float32List tensorFromEncoded(Uint8List encoded) =>
      tensorFromRgb(PackedImage.decodeRgb(encoded));

  static Float32List tensorFromRgb(PackedImage rgb) => toChw(resizeAndCrop(rgb));

  /// Resize so the shortest edge is [size] (the long edge becomes
  /// `floor(size * long / short)`, as in Hugging Face's
  /// `get_resize_output_image_size`), then center-crop to [size] x [size].
  static PackedImage resizeAndCrop(PackedImage rgb) {
    final w = rgb.width;
    final h = rgb.height;
    final int nw;
    final int nh;
    if (w <= h) {
      nw = size;
      nh = (size * h / w).floor();
    } else {
      nh = size;
      nw = (size * w / h).floor();
    }
    final resized = rgb.resizeBilinear(nw, nh);
    return resized.crop((nw - size) ~/ 2, (nh - size) ~/ 2, size, size);
  }

  static Float32List toChw(PackedImage rgb) {
    assert(rgb.channels == 3);
    final plane = rgb.width * rgb.height;
    final out = Float32List(3 * plane);
    final d = rgb.data;
    for (var i = 0, j = 0; i < plane; i++, j += 3) {
      out[i] = d[j] * rescaleFactor;
      out[plane + i] = d[j + 1] * rescaleFactor;
      out[2 * plane + i] = d[j + 2] * rescaleFactor;
    }
    return out;
  }
}
