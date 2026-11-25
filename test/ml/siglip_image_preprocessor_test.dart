import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_gallery/ml/image/rgb_image.dart';
import 'package:ai_gallery/ml/siglip/siglip_image_preprocessor.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reference tensors come from Pillow via tool/siglip_reference.py
/// (resize to 224x224 bicubic, /255, (x - 0.5) / 0.5, CHW).
void main() {
  final ref = (jsonDecode(File('test/ml/fixtures/siglip_preprocess.json').readAsStringSync()) as Map)
      .cast<String, dynamic>();

  for (final name in ref.keys) {
    test('tensor for $name matches the Pillow reference exactly', () {
      final bytes = File('test/ml/fixtures/reference_images/$name.png').readAsBytesSync();
      final rgb = PackedImage.decodeRgb(bytes).resizeBicubic(224, 224);
      expect(rgb.width, 224);
      expect(rgb.height, 224);

      // CHW uint8 bytes, same layout the reference hashed.
      const plane = 224 * 224;
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

      final tensor = SiglipImagePreprocessor.tensorFromEncoded(bytes);
      expect(tensor.length, 3 * plane);
      final means = (r['mean_rgb'] as List).cast<double>();
      for (var c = 0; c < 3; c++) {
        var sum = 0.0;
        for (var i = 0; i < plane; i++) {
          sum += tensor[c * plane + i];
        }
        // Tensor values are (x/255 - 0.5) / 0.5 = 2 * mean - 1.
        expect(sum / plane, closeTo(2 * means[c] - 1, 1e-5));
      }
    });
  }

  test('values are in [-1, 1] and layout is CHW', () {
    // 2x1 image: red, blue -> stretched to 224x224 (aspect ratio not kept).
    final img = PackedImage(2, 1, 3, Uint8List.fromList([255, 0, 0, 0, 0, 255]));
    final t = SiglipImagePreprocessor.tensorFromRgb(img);
    const plane = 224 * 224;
    expect(t.every((v) => v >= -1 && v <= 1), isTrue);
    // Left edge mostly red, right edge mostly blue.
    expect(t[0], greaterThan(t[2 * plane]));
    expect(t[223], lessThan(t[2 * plane + 223]));
  });

  test('undecodable bytes throw FormatException', () {
    expect(() => SiglipImagePreprocessor.tensorFromEncoded(Uint8List.fromList([1, 2, 3])), throwsFormatException);
  });
}
