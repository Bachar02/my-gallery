import 'dart:typed_data';

import '../image/rgb_image.dart';

/// Image -> SigLIP input tensor, exactly as the export's
/// `preprocessor_config.json` specifies:
///
/// ```
/// do_resize: true, size: 224x224 (no aspect ratio kept), resample: 3 (PIL bicubic)
/// do_rescale: true, rescale_factor: 1/255
/// do_normalize: true, mean 0.5, std 0.5        (-> [-1, 1])
/// ```
///
/// Output layout is NCHW float32 `[1, 3, 224, 224]`, flattened. Pure Dart and
/// synchronous: callers run it in a background isolate.
abstract final class SiglipImagePreprocessor {
  static const int size = 224;

  static Float32List tensorFromEncoded(Uint8List encoded) => tensorFromRgb(PackedImage.decodeRgb(encoded));

  static Float32List tensorFromRgb(PackedImage rgb) => toChw(rgb.resizeBicubic(size, size));

  static Float32List toChw(PackedImage rgb) {
    assert(rgb.channels == 3);
    final plane = rgb.width * rgb.height;
    final out = Float32List(3 * plane);
    final d = rgb.data;
    for (var i = 0, j = 0; i < plane; i++, j += 3) {
      out[i] = (d[j] / 255 - 0.5) / 0.5;
      out[plane + i] = (d[j + 1] / 255 - 0.5) / 0.5;
      out[2 * plane + i] = (d[j + 2] / 255 - 0.5) / 0.5;
    }
    return out;
  }
}
