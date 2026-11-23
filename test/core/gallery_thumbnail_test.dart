import 'package:ai_gallery/core/widgets/gallery_thumbnail.dart';
import 'package:ai_gallery/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  group('thumbnailSizeFor', () {
    test('tall screenshot: short side must cover the tile', () {
      // 330 px tile, 1080x2400 → needs 734 px longest side → 768 bucket.
      expect(thumbnailSizeFor(tilePx: 330, width: 1080, height: 2400), 768);
    });

    test('square-ish photo uses a small bucket', () {
      expect(thumbnailSizeFor(tilePx: 330, width: 4000, height: 3000), 512);
      expect(thumbnailSizeFor(tilePx: 200, width: 1000, height: 1000), 256);
    });

    test('caps at 1024 and tolerates missing dimensions', () {
      expect(thumbnailSizeFor(tilePx: 600, width: 1080, height: 9000), 1024);
      expect(thumbnailSizeFor(tilePx: 300, width: 0, height: 0), 384);
    });
  });

  Future<void> pumpTile(WidgetTester tester, TestEnv env, GalleryImage image) async {
    await tester.pumpWidget(env.wrap(Center(
      child: SizedBox.square(dimension: 110, child: GalleryThumbnail(image: image)),
    )));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('requests a size from physical pixels and crops screenshots from the top', (tester) async {
    tester.view.devicePixelRatio = 3; // 110 dp tile → 330 px
    addTearDown(tester.view.reset);
    final env = TestEnv()..gallery.thumbnailBytes = tinyPng;
    await pumpTile(tester, env, fakeImage('s', kind: ImageKind.screenshot));
    expect(env.gallery.thumbnailRequests['s'], [768]);
    expect(tester.widget<Image>(find.byType(Image)).alignment, Alignment.topCenter);
  });

  testWidgets('photos are centre-cropped', (tester) async {
    final env = TestEnv()..gallery.thumbnailBytes = tinyPng;
    await pumpTile(tester, env, fakeImage('p'));
    expect(tester.widget<Image>(find.byType(Image)).alignment, Alignment.center);
  });
}
