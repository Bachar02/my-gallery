import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_gallery/ml/clip/clip_image_preprocessor.dart';
import 'package:ai_gallery/ml/image/rgb_image.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reference tensors come from Pillow via tool/clip_reference.py
/// (shortest edge -> 256 bilinear, center crop 256, /255, CHW).
void main() {
  final ref = (jsonDecode(File('test/ml/fixtures/clip_preprocess.json').readAsStringSync()) as Map)
      .cast<String, dynamic>();

  for (final name in ref.keys) {
    test('tensor for $name matches the Pillow reference exactly', () {
      final bytes = File('test/ml/fixtures/clip_images/$name.png').readAsBytesSync();
      final rgb = ClipImagePreprocessor.resizeAndCrop(PackedImage.decodeRgb(bytes));
      expect(rgb.width, 256);
      expect(rgb.height, 256);

      // CHW uint8 bytes, same layout the reference hashed.
      final plane = 256 * 256;
      final chw = Uint8List(3 * plane);
      for (var i = 0; i < plane; i++) {
        chw[i] = rgb.data[i * 3];
        chw[plane + i] = rgb.data[i * 3 + 1];
        chw[2 * plane + i] = rgb.data[i * 3 + 2];
      }
      final r = ref[name] as Map<String, dynamic>;
      for (final s in (r['samples'] as List).cast<List>()) {
        expect(chw[s[0] as int], s[1], reason: 'element ${s[0]}');
      }
      expect(sha256.convert(chw).toString(), r['sha256_chw_u8']);

      final tensor = ClipImagePreprocessor.tensorFromEncoded(bytes);
      expect(tensor.length, 3 * plane);
      final means = (r['mean_rgb'] as List).cast<double>();
      for (var c = 0; c < 3; c++) {
        var sum = 0.0;
        for (var i = 0; i < plane; i++) {
          sum += tensor[c * plane + i];
        }
        expect(sum / plane, closeTo(means[c], 1e-5));
      }
    });
  }

  test('values are in [0, 1] and layout is CHW', () {
    // 2x1 image: red, blue -> upscaled to 512x256 then center-cropped.
    final img = PackedImage(2, 1, 3, Uint8List.fromList([255, 0, 0, 0, 0, 255]));
    final t = ClipImagePreprocessor.tensorFromRgb(img);
    const plane = 256 * 256;
    expect(t.every((v) => v >= 0 && v <= 1), isTrue);
    // Left edge of the crop is still mostly red, right edge mostly blue.
    expect(t[0], greaterThan(t[2 * plane]));
    expect(t[255], lessThan(t[2 * plane + 255]));
  });

  test('undecodable bytes throw FormatException', () {
    expect(() => ClipImagePreprocessor.tensorFromEncoded(Uint8List.fromList([1, 2, 3])), throwsFormatException);
  });
}
