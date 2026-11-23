// End-to-end on-device flow with the real implementations: gallery
// (MediaStore) -> DefaultIndexingService (ML Kit OCR + MobileCLIP + dHash) ->
// SqliteIndexStore (temp file) -> HybridSearchEngine, checked against the
// fixture gallery's expected answers, then delete-index and re-index.
//
// Preconditions:
//   tool/.venv/Scripts/python -I tool/fixtures/make_fixtures.py --push
//   adb shell pm grant com.bachar02.ai_gallery android.permission.READ_MEDIA_IMAGES
// Run: flutter test integration_test/app/search_flow_test.dart -d <device>
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:ai_gallery/data/db/sqlite_index_store.dart';
import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/gallery/data/photo_manager_gallery_repository.dart';
import 'package:ai_gallery/features/indexing/default_indexing_service.dart';
import 'package:ai_gallery/features/search/data/hybrid_search_engine.dart';
import 'package:ai_gallery/features/search/data/rule_based_query_parser.dart';
import 'package:ai_gallery/ml/clip/mobile_clip_model.dart';
import 'package:ai_gallery/ml/ocr/mlkit_ocr_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

/// Mirrors tool/fixtures/out/expected.json (written by make_fixtures.py).
const _expected = <String, List<String>>{
  'Find the screenshot of my conversation with Jamie': ['Screenshot_20261102-194112.png'],
  'Find the conversation where we discussed our trip to Germany': ['Screenshot_20261015-101530.png'],
  'Find the screenshot where someone sent me their bank details': ['Screenshot_20261020-090210.png'],
  'Show me the picture of the restaurant menu I took last summer': ['IMG_20260718_menu_0.jpg', 'IMG_20260718_menu_1.jpg'],
  'Show me the picture of the red car': ['IMG_20260903_red_car_0.jpg', 'IMG_20260903_red_car_1.jpg'],
  'zebra crossing in tokyo': [],
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('index the device gallery, search the product examples, delete and re-index', (tester) async {
    final dir = Directory.systemTemp.createTempSync('e2e_index_');
    final store = SqliteIndexStore(p.join(dir.path, 'e2e.db'));
    await store.open();
    final gallery = PhotoManagerGalleryRepository();
    final ocr = MlKitOcrEngine();
    final model = MobileClipModel();
    final service = DefaultIndexingService(gallery: gallery, store: store, ocr: ocr, semantic: model, batchSize: 50);
    addTearDown(() async {
      await service.dispose();
      await ocr.dispose();
      await model.dispose();
      await store.close();
      dir.deleteSync(recursive: true);
    });

    expect(await gallery.permissionStatus(), anyOf(GalleryPermission.granted, GalleryPermission.limited),
        reason: 'grant READ_MEDIA_IMAGES first');

    var sw = Stopwatch()..start();
    await service.start();
    final first = service.current;
    print('[e2e] first index: ${first.processed} images, ${first.failed} failed, ${sw.elapsedMilliseconds} ms '
        '(${(sw.elapsedMilliseconds / (first.processed == 0 ? 1 : first.processed)).toStringAsFixed(0)} ms/image)');
    expect(first.phase, IndexingPhase.completed);
    expect((await store.stats()).indexedImages, greaterThan(0));

    final engine = HybridSearchEngine(store: store, parser: RuleBasedQueryParser(), model: model);
    for (final MapEntry(key: query, value: wanted) in _expected.entries) {
      final res = await engine.search(query);
      final names = [for (final r in res.results) r.image.filename];
      print('[e2e] "$query" -> $names (${res.elapsed.inMilliseconds} ms)');
      if (wanted.isEmpty) {
        expect(names, isEmpty, reason: query);
      } else {
        expect(names.take(wanted.length + 2), containsAll(wanted.take(1)), reason: query);
        for (final r in res.results.where((r) => wanted.contains(r.image.filename))) {
          expect(r.reasons, isNotEmpty);
        }
      }
    }

    // Delete the index, then a re-index restores it.
    await service.stop();
    await store.clearAll();
    expect((await store.stats()).indexedImages, 0);
    expect(await engine.search('Jamie'), isA<Object>());
    sw = Stopwatch()..start();
    await service.start();
    print('[e2e] re-index: ${service.current.processed} images in ${sw.elapsedMilliseconds} ms');
    expect(service.current.phase, IndexingPhase.completed);
    expect((await store.stats()).indexedImages, first.processed);
  }, timeout: const Timeout(Duration(minutes: 20)));
}
