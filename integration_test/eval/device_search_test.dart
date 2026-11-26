// On-device verification with the real pipeline: the evaluation corpus is
// pushed into the device gallery (tool/eval/push_gallery.py), then
// MediaStore -> DefaultIndexingService (ML Kit OCR + layout, ScreenAnalyzer,
// face count, SigLIP on ONNX Runtime) -> SqliteIndexStore -> HybridSearchEngine.
//
// Checks the three phone regressions and a few other intents against the
// corpus ids (file names are `<id>.png|jpg`), and prints timings.
//
// Run: tool/.venv/Scripts/python -I tool/eval/push_gallery.py [-d <device>]
// (pushes the corpus, runs this test and grants the gallery permission once
// the app is installed).
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:ai_gallery/data/db/sqlite_index_store.dart';
import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/gallery/data/photo_manager_gallery_repository.dart';
import 'package:ai_gallery/features/indexing/default_indexing_service.dart';
import 'package:ai_gallery/features/search/data/hybrid_search_engine.dart';
import 'package:ai_gallery/features/search/data/rule_based_query_parser.dart';
import 'package:ai_gallery/ml/face/mlkit_face_counter.dart';
import 'package:ai_gallery/ml/ocr/mlkit_ocr_engine.dart';
import 'package:ai_gallery/ml/siglip/siglip_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

String _id(SearchResult r) => p.basenameWithoutExtension(r.image.filename ?? '');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('index the corpus on the device and answer each intent with the right evidence', (tester) async {
    final dir = Directory.systemTemp.createTempSync('device_eval_');
    final store = SqliteIndexStore(p.join(dir.path, 'eval.db'));
    await store.open();
    final gallery = PhotoManagerGalleryRepository();
    final ocr = MlKitOcrEngine();
    final faces = MlKitFaceCounter();
    final model = SiglipModel();
    final service = DefaultIndexingService(
        gallery: gallery, store: store, ocr: ocr, semantic: model, faces: faces, batchSize: 50);
    addTearDown(() async {
      await service.dispose();
      await ocr.dispose();
      await faces.dispose();
      await model.dispose();
      await store.close();
      dir.deleteSync(recursive: true);
    });
    // tool/eval/push_gallery.py grants the permission once the app is installed.
    for (var i = 0; i < 90 && await gallery.permissionStatus() != GalleryPermission.granted; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    expect(await gallery.permissionStatus(), GalleryPermission.granted, reason: 'grant READ_MEDIA_IMAGES');

    // Wait for the gallery to be visible (the media scanner may still run).
    for (var i = 0; i < 60 && await gallery.countImages() < 700; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    final sw = Stopwatch()..start();
    await service.start();
    final run = service.current;
    final stats = await store.stats();
    print('[device-eval] indexed ${run.processed} images (${run.failed} failed) in ${sw.elapsed.inSeconds} s, '
        '${(sw.elapsedMilliseconds / (run.processed == 0 ? 1 : run.processed)).toStringAsFixed(0)} ms/image; '
        '${stats.imagesWithEmbedding} embeddings, ${stats.screenshots} screenshots');
    expect(run.phase, IndexingPhase.completed);
    expect(stats.imagesWithEmbedding, greaterThan(600));

    final engine = HybridSearchEngine(store: store, parser: RuleBasedQueryParser(), model: model);
    Future<SearchResponse> search(String q) async {
      final res = await engine.search(q);
      print('[device-eval] "$q" (${res.intent.name}, ${res.elapsed.inMilliseconds} ms): '
          '${res.primary.length} results ${[for (final r in res.primary.take(8)) _id(r)]}'
          '${res.mentions.isEmpty ? '' : ' + ${res.mentions.length} mentions ${[for (final r in res.mentions.take(5)) _id(r)]}'}');
      return res;
    }

    // 1. "restaurant menu": menus, never map/web/chat screenshots that say "restaurants".
    final menu = await search('restaurant menu');
    expect(menu.intent, SearchIntent.visual);
    expect(menu.primary, isNotEmpty);
    for (final r in menu.primary.take(5)) {
      expect(_id(r), isNot(matches(RegExp(r'^(map|web|chat|social|email)_'))), reason: 'top 5 of restaurant menu');
    }

    // 2. "picture of a man": photos only, no screenshot that prints MEN/MAN.
    final man = await search('picture of a man');
    expect(man.primary, isNotEmpty);
    for (final r in man.primary) {
      expect(r.image.kind, ImageKind.photo, reason: _id(r));
    }

    // 3. Conversations with Jamie: chat titles only; mentions separate.
    for (final q in ['conversation with Jamie', 'screenshot with Jamie']) {
      final res = await search(q);
      expect(res.intent, SearchIntent.conversation);
      expect(res.primary.length, greaterThanOrEqualTo(8));
      for (final r in res.primary) {
        expect(_id(r), matches(RegExp(r'^chat_.*jamie')), reason: '$q: ${_id(r)}');
        expect(_id(r), isNot(contains('jamieson')));
        expect(_id(r), isNot(contains('mentions')));
      }
      expect(res.mentions, isNotEmpty);
    }

    // Other intents.
    final iban = await search('IBAN');
    expect([for (final r in iban.primary) _id(r)], contains('bank_account_iban'));
    final hotel = await search('screenshot of the map to the hotel');
    expect(_id(hotel.primary.first), startsWith('map_dir_hotel'));
    final elephant = await search('purple elephant');
    expect(elephant.results, isEmpty);
    final zoe = await search('conversation with Zoe');
    expect(zoe.results, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 60)));
}
