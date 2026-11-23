import 'package:ai_gallery/features/gallery/data/android_image_actions.dart';
import 'package:ai_gallery/features/gallery/domain/thumbnail_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fitWithin', () {
    test('landscape and portrait keep aspect, longest side = target', () {
      expect(fitWithin(4000, 3000, 256), (width: 256, height: 192));
      expect(fitWithin(1080, 2400, 256), (width: 115, height: 256));
    });

    test('never upscales', () {
      expect(fitWithin(100, 50, 256), (width: 100, height: 50));
    });

    test('extreme aspect keeps at least one pixel', () {
      expect(fitWithin(1, 100000, 256), (width: 1, height: 256));
    });

    test('unknown dimensions request a square', () {
      expect(fitWithin(0, 0, 512), (width: 512, height: 512));
    });
  });

  test('mime type from extension', () {
    expect(AndroidImageActions.mimeFromName('/a/b/IMG.HEIC'), 'image/heic');
    expect(AndroidImageActions.mimeFromName('x.jpeg'), 'image/jpeg');
    expect(AndroidImageActions.mimeFromName('x.unknown'), isNull);
  });
}
