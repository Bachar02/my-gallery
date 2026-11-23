import 'dart:io';
import 'dart:typed_data';

import 'package:ai_gallery/ml/image/dhash.dart';
import 'package:ai_gallery/ml/image/rgb_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  Uint8List fixture(String name) => File('test/ml/fixtures/clip_images/$name.png').readAsBytesSync();

  test('identical images hash identically; re-encoding and scaling barely change it', () {
    final png = fixture('red_car');
    final h = DHash.ofEncoded(png);
    expect(DHash.ofEncoded(png), h);

    final decoded = img.decodePng(png)!;
    final jpeg = img.encodeJpg(img.copyResize(decoded, width: 120), quality: 70);
    expect(DHash.distance(h, DHash.ofEncoded(jpeg)), lessThanOrEqualTo(6));
  });

  test('different images are far apart', () {
    final names = ['red_car', 'cat', 'menu', 'beach', 'chat_screenshot'];
    final hashes = [for (final n in names) DHash.ofEncoded(fixture(n))];
    for (var i = 0; i < hashes.length; i++) {
      for (var j = i + 1; j < hashes.length; j++) {
        expect(DHash.distance(hashes[i], hashes[j]), greaterThan(12), reason: '${names[i]} vs ${names[j]}');
      }
    }
  });

  test('bit layout: brighter-than-right-neighbour sets the bit', () {
    // Horizontal gradient getting darker to the right: every bit set.
    final w = 90, h = 80;
    final data = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        data[y * w + x] = 255 - x * 2;
      }
    }
    expect(DHash.ofImage(PackedImage(w, h, 1, data)), -1); // all 64 bits
  });

  test('distance counts differing bits including the sign bit', () {
    expect(DHash.distance(0, 0), 0);
    expect(DHash.distance(0, -1), 64);
    expect(DHash.distance(1, 3), 1);
  });
}
