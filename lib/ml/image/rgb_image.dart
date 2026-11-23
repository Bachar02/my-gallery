import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A tightly packed 8-bit image (HWC, [channels] = 1 or 3).
class PackedImage {
  PackedImage(this.width, this.height, this.channels, this.data)
      : assert(data.length == width * height * channels);

  final int width;
  final int height;
  final int channels;
  final Uint8List data;

  /// Decodes JPEG/PNG/WebP/GIF/BMP bytes to packed RGB, applying the EXIF
  /// orientation. Alpha is dropped (not composited), like PIL's
  /// `convert('RGB')`. Throws [FormatException] for undecodable input.
  static PackedImage decodeRgb(Uint8List encoded) {
    final decoded = img.decodeImage(encoded);
    if (decoded == null || decoded.width == 0 || decoded.height == 0) {
      throw const FormatException('Unsupported or corrupt image data');
    }
    return fromImage(img.bakeOrientation(decoded));
  }

  static PackedImage fromImage(img.Image image) {
    final w = image.width;
    final h = image.height;
    final out = Uint8List(w * h * 3);
    final fast = image.format == img.Format.uint8 &&
        !image.hasPalette &&
        (image.numChannels == 3 || image.numChannels == 4);
    if (fast) {
      final src = image.toUint8List();
      final nc = image.numChannels;
      final rowStride = image.rowStride;
      var o = 0;
      for (var y = 0; y < h; y++) {
        var i = y * rowStride;
        for (var x = 0; x < w; x++) {
          out[o] = src[i];
          out[o + 1] = src[i + 1];
          out[o + 2] = src[i + 2];
          o += 3;
          i += nc;
        }
      }
    } else {
      final gray = image.numChannels <= 2 && !image.hasPalette;
      var o = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final p = image.getPixel(x, y);
          final r = _to8(p.rNormalized);
          out[o] = r;
          out[o + 1] = gray ? r : _to8(p.gNormalized);
          out[o + 2] = gray ? r : _to8(p.bNormalized);
          o += 3;
        }
      }
    }
    return PackedImage(w, h, 3, out);
  }

  static int _to8(num v) => (v * 255).round().clamp(0, 255);

  /// ITU-R 601-2 luma, as PIL's `convert('L')`: (R*299 + G*587 + B*114) / 1000.
  PackedImage toGray() {
    if (channels == 1) return this;
    final out = Uint8List(width * height);
    for (var i = 0, j = 0; i < out.length; i++, j += 3) {
      out[i] = (data[j] * 19595 + data[j + 1] * 38470 + data[j + 2] * 7471 + 0x8000) >> 16;
    }
    return PackedImage(width, height, 1, out);
  }

  PackedImage crop(int left, int top, int w, int h) {
    final out = Uint8List(w * h * channels);
    final rowBytes = w * channels;
    for (var y = 0; y < h; y++) {
      final src = ((top + y) * width + left) * channels;
      out.setRange(y * rowBytes, (y + 1) * rowBytes, data, src);
    }
    return PackedImage(w, h, channels, out);
  }

  /// Bilinear (triangle filter) resampling with antialiasing when shrinking,
  /// a port of Pillow's `Image.resize(..., resample=BILINEAR)` 8-bit path,
  /// including its fixed-point arithmetic and the horizontal-then-vertical
  /// pass order, so results match Pillow (and thus the Python reference
  /// preprocessing) exactly.
  PackedImage resizeBilinear(int newWidth, int newHeight) {
    var cur = this;
    if (newWidth != width) cur = cur._pass(newWidth, horizontal: true);
    if (newHeight != height) cur = cur._pass(newHeight, horizontal: false);
    return cur;
  }

  static const int _precisionBits = 32 - 8 - 2;

  PackedImage _pass(int outSize, {required bool horizontal}) {
    final inSize = horizontal ? width : height;
    final coeffs = _Coeffs.bilinear(inSize, outSize);
    final outW = horizontal ? outSize : width;
    final outH = horizontal ? height : outSize;
    final out = Uint8List(outW * outH * channels);
    const half = 1 << (_precisionBits - 1);
    final k = coeffs.k;
    final ksize = coeffs.ksize;
    if (horizontal) {
      for (var y = 0; y < height; y++) {
        final rowIn = y * width * channels;
        final rowOut = y * outW * channels;
        for (var xx = 0; xx < outSize; xx++) {
          final xmin = coeffs.min[xx];
          final xn = coeffs.count[xx];
          final kOff = xx * ksize;
          for (var c = 0; c < channels; c++) {
            var ss = half;
            for (var x = 0; x < xn; x++) {
              ss += data[rowIn + (x + xmin) * channels + c] * k[kOff + x];
            }
            out[rowOut + xx * channels + c] = _clip8(ss);
          }
        }
      }
    } else {
      final rowLen = width * channels;
      for (var yy = 0; yy < outSize; yy++) {
        final ymin = coeffs.min[yy];
        final yn = coeffs.count[yy];
        final kOff = yy * ksize;
        final rowOut = yy * rowLen;
        for (var i = 0; i < rowLen; i++) {
          var ss = half;
          for (var y = 0; y < yn; y++) {
            ss += data[(y + ymin) * rowLen + i] * k[kOff + y];
          }
          out[rowOut + i] = _clip8(ss);
        }
      }
    }
    return PackedImage(outW, outH, channels, out);
  }

  static int _clip8(int ss) {
    final v = ss >> _precisionBits;
    return v < 0 ? 0 : (v > 255 ? 255 : v);
  }
}

class _Coeffs {
  _Coeffs(this.ksize, this.min, this.count, this.k);

  final int ksize;
  final Int32List min;
  final Int32List count;
  final Int32List k;

  /// Pillow `precompute_coeffs` + `normalize_coeffs_8bpc` for the bilinear
  /// filter (support 1.0).
  factory _Coeffs.bilinear(int inSize, int outSize) {
    final scale = inSize / outSize;
    final filterScale = math.max(scale, 1.0);
    final support = 1.0 * filterScale;
    final ksize = support.ceil() * 2 + 1;
    final mins = Int32List(outSize);
    final counts = Int32List(outSize);
    final kk = Int32List(outSize * ksize);
    final pre = Float64List(ksize);
    final ss = 1.0 / filterScale;
    for (var xx = 0; xx < outSize; xx++) {
      final center = (xx + 0.5) * scale;
      var xmin = (center - support + 0.5).toInt();
      if (xmin < 0) xmin = 0;
      var xmax = (center + support + 0.5).toInt();
      if (xmax > inSize) xmax = inSize;
      xmax -= xmin;
      var ww = 0.0;
      for (var x = 0; x < xmax; x++) {
        var t = ((x + xmin - center + 0.5) * ss).abs();
        final w = t < 1.0 ? 1.0 - t : 0.0;
        pre[x] = w;
        ww += w;
      }
      for (var x = 0; x < xmax; x++) {
        final w = ww != 0.0 ? pre[x] / ww : pre[x];
        final f = w * (1 << PackedImage._precisionBits);
        kk[xx * ksize + x] = w < 0 ? (-0.5 + f).toInt() : (0.5 + f).toInt();
      }
      mins[xx] = xmin;
      counts[xx] = xmax;
    }
    return _Coeffs(ksize, mins, counts, kk);
  }
}
