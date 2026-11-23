import 'dart:async';
import 'dart:io';

import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/indexing/default_indexing_service.dart';
import 'package:ai_gallery/features/indexing/pipeline_version.dart';
import 'package:flutter_test/flutter_test.dart';

import '../search/data/fakes.dart';

void main() {
  final now = DateTime(2026, 11, 23, 10);
  late FakeIndexStore store;
  late FakeGallery gallery;
  late FakeOcr ocr;
  late FakeSemanticModel model;
  late Directory temp;
  late List<IndexingProgress> events;
  late DefaultIndexingService service;

  DefaultIndexingService build({int batchSize = 2, Duration debounce = const Duration(milliseconds: 20)}) {
    final s = DefaultIndexingService(
      gallery: gallery,
      store: store,
      ocr: ocr,
      semantic: model,
      hasher: (bytes) async => bytes.length * 31,
      tempDirectory: () async => temp,
      clock: () => now,
      batchSize: batchSize,
      resyncDebounce: debounce,
    );
    s.progress.listen(events.add);
    return s;
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('indexing_test');
    store = FakeIndexStore();
    gallery = FakeGallery([
      galleryImage('c', created: DateTime(2026, 11, 3)),
      galleryImage('b', created: DateTime(2026, 11, 2)),
      galleryImage('a', created: DateTime(2026, 11, 1)),
    ]);
    ocr = FakeOcr({'a': 'Alpha text', 'b': 'Bravo text', 'c': 'Charlie text', 'd': 'Delta'});
    model = FakeSemanticModel(images: {'a': unit(0.5), 'b': unit(0.6), 'c': unit(0.7)});
    events = [];
    service = build();
  });

  tearDown(() async {
    await service.dispose();
    temp.deleteSync(recursive: true);
  });

  List<IndexingPhase> phases() => [for (final e in events) e.phase];

  test('first run indexes everything with OCR, embedding and hash, in batches', () async {
    await service.start();
    await pumpEventQueue();

    expect(phases().first, IndexingPhase.scanning);
    expect(phases().last, IndexingPhase.completed);
    final last = service.current;
    expect(last.total, 3);
    expect(last.processed, 3);
    expect(last.failed, 0);
    expect(last.lastCompletedAt, now);
    expect(store.settings[DefaultIndexingService.lastCompletedSettingKey], now.toIso8601String());

    expect(store.records.keys, unorderedEquals(['a', 'b', 'c']));
    final a = store.records['a']!;
    expect(a.ocrText, 'Alpha text');
    expect(a.embedding, isNotNull);
    expect(a.embeddingModel, 'fake_clip');
    expect(a.perceptualHash, 'a'.length * 31);
    expect(a.pipelineVersion, pipelineStamp(withEmbedding: true));
    expect(store.upsertAllSizes, [2, 1]);
    // Newest first.
    expect(ocr.calls, ['c', 'b', 'a']);
    // Progress is monotonic.
    final processed = [for (final e in events) e.processed];
    for (var i = 1; i < processed.length; i++) {
      expect(processed[i], greaterThanOrEqualTo(processed[i - 1]));
    }
  });

  test('incremental: only new and modified images are processed, deleted ones removed', () async {
    await service.start();
    ocr.calls.clear();
    events.clear();

    gallery.images = [
      galleryImage('d', created: DateTime(2026, 11, 4)),
      galleryImage('c', created: DateTime(2026, 11, 3), modified: DateTime(2026, 11, 20)),
      galleryImage('a', created: DateTime(2026, 11, 1)),
    ];
    await service.start();

    expect(ocr.calls, ['d', 'c']);
    expect(service.current.total, 2);
    expect(service.current.phase, IndexingPhase.completed);
    expect(store.records.keys, unorderedEquals(['a', 'c', 'd']));
    expect(store.deletes.last, ['b']);
    expect(store.records['c']!.image.modifiedAt, DateTime(2026, 11, 20));
  });

  test('pipeline bump re-processes old records', () async {
    store.put(record(galleryImage('a', created: DateTime(2026, 11, 1)), text: 'old', pipelineVersion: 0));
    await service.start();
    expect(ocr.calls, containsAll(['a']));
    expect(store.records['a']!.ocrText, 'Alpha text');
  });

  test('text-only records get embeddings once the model is available, without new OCR', () async {
    for (final img in gallery.images) {
      store.put(record(img, text: 'kept ${img.id}', hash: 7, pipelineVersion: pipelineStamp(withEmbedding: false)));
    }
    await service.start();
    expect(ocr.calls, isEmpty);
    expect(service.current.processed, 3);
    final a = store.records['a']!;
    expect(a.ocrText, 'kept a');
    expect(a.perceptualHash, 7);
    expect(a.embedding, isNotNull);
    expect(a.pipelineVersion, pipelineStamp(withEmbedding: true));
  });

  test('without a semantic model: text-only records, and no rework next time', () async {
    model = FakeSemanticModel(loadResult: false);
    service = build();
    await service.start();
    expect(store.records.values.every((r) => r.embedding == null), isTrue);
    expect(store.records.values.every((r) => r.pipelineVersion == pipelineStamp(withEmbedding: false)), isTrue);
    expect(model.imageCalls, 0);

    ocr.calls.clear();
    await service.start();
    expect(ocr.calls, isEmpty);
    expect(service.current.total, 0);
  });

  test('per-item failures are counted and skipped; embedding failures keep the record', () async {
    ocr.failIds.add('b');
    model = FakeSemanticModel(images: {'a': unit(0.5)}, failImageIds: {'c'});
    service = build();
    await service.start();

    expect(service.current.phase, IndexingPhase.completed);
    expect(service.current.processed, 3);
    expect(service.current.failed, 1);
    expect(store.records.keys, unorderedEquals(['a', 'c']));
    expect(store.records['c']!.embedding, isNull);
    expect(store.records['c']!.pipelineVersion, pipelineStamp(withEmbedding: false));
  });

  test('OCR falls back to a rendition when the original file is unavailable', () async {
    gallery.noOriginal.add('a');
    await service.start();
    expect(store.records['a']!.ocrText, 'Alpha text');
    expect(temp.listSync(), isEmpty, reason: 'temp file cleaned up');
  });

  test('unreadable image is a failure, but a vanished one is not', () async {
    gallery.unreadable.add('b');
    gallery.onAccess = (id) {
      if (id == 'a') gallery.images.removeWhere((i) => i.id == 'a');
    };
    await service.start();
    expect(service.current.failed, 1);
    expect(store.records.keys, ['c']);
    expect(store.deletes.expand((d) => d), contains('a'));
  });

  test('permission revoked mid-run ends in permissionDenied, keeping finished work', () async {
    gallery.onAccess = (id) {
      if (id == 'b') gallery.permission = GalleryPermission.denied;
    };
    await service.start();
    expect(service.current.phase, IndexingPhase.permissionDenied);
    expect(store.records.keys, ['c']);
    expect(ocr.calls, ['c']);
  });

  test('no permission at start', () async {
    gallery.permission = GalleryPermission.permanentlyDenied;
    await service.start();
    await pumpEventQueue();
    expect(phases(), [IndexingPhase.permissionDenied]);
    expect(gallery.listCalls, 0);
  });

  test('limited access is allowed', () async {
    gallery.permission = GalleryPermission.limited;
    await service.start();
    expect(service.current.phase, IndexingPhase.completed);
  });

  test('pause and resume at item boundaries; work is flushed before pausing', () async {
    // Pause while the second image is being recognised: it finishes, then the
    // service pauses before the third.
    ocr.beforeRecognize = (id) async {
      if (id == 'b') service.pause();
    };
    final run = service.start();
    await pumpEventQueue();

    expect(service.current.phase, IndexingPhase.paused);
    expect(service.current.processed, 2);
    expect(ocr.calls, ['c', 'b']);
    expect(store.records.keys, unorderedEquals(['c', 'b']), reason: 'flushed before pausing');

    service.resume();
    await run;
    await pumpEventQueue();
    expect(service.current.phase, IndexingPhase.completed);
    expect(service.current.processed, 3);
    expect(ocr.calls, ['c', 'b', 'a']);
    expect(phases(), containsAllInOrder([IndexingPhase.paused, IndexingPhase.indexing, IndexingPhase.completed]));
  });

  test('stop cancels a paused run', () async {
    ocr.beforeRecognize = (id) async {
      if (id == 'c') service.pause();
    };
    final run = service.start();
    await pumpEventQueue();
    expect(service.current.phase, IndexingPhase.paused);
    await service.stop();
    await run;
    expect(service.current.phase, IndexingPhase.idle);
    expect(ocr.calls, ['c']);
    expect(store.records.keys, ['c']);
  });

  test('start while running does not start a second run', () async {
    final gate = Completer<void>();
    ocr.beforeRecognize = (_) => gate.future;
    final r1 = service.start();
    final r2 = service.start();
    gate.complete();
    await Future.wait([r1, r2]);
    expect(gallery.listCalls, 1);
    expect(ocr.calls, ['c', 'b', 'a']);
  });

  test('gallery changes trigger a debounced re-sync while idle', () async {
    await service.start();
    gallery.images = [galleryImage('d', created: DateTime(2026, 11, 5)), ...gallery.images];
    gallery.changesController
      ..add(null)
      ..add(null)
      ..add(null);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(gallery.listCalls, 2, reason: 'three events, one debounced re-sync');
    expect(store.records.keys, contains('d'));
  });

  test('a change during a run schedules one re-sync after it', () async {
    final gate = Completer<void>();
    ocr.beforeRecognize = (_) => gate.future;
    final run = service.start();
    await pumpEventQueue();
    gallery.changesController.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    gate.complete();
    await run;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(gallery.listCalls, 2);
  });

  test('QA-20: no auto re-sync while indexing is disabled; explicit start still runs', () async {
    await service.start();
    store.settings[DefaultIndexingService.disabledSettingKey] = '1';
    gallery.changesController.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(gallery.listCalls, 1);

    await service.start();
    expect(gallery.listCalls, 2);

    store.settings[DefaultIndexingService.disabledSettingKey] = null;
    gallery.changesController.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(gallery.listCalls, 3);
  });

  test('QA-09: leftover OCR temp files from a killed run are swept at start', () async {
    final folder = Directory('${temp.path}/${DefaultIndexingService.ocrTempFolder}')..createSync();
    File('${folder.path}/123_0.jpg').writeAsStringSync('x');
    final legacy = File('${temp.path}/ocr_1700000000000_3.jpg')..writeAsStringSync('x');
    final unrelated = File('${temp.path}/keep_me.jpg')..writeAsStringSync('x');
    gallery.noOriginal.add('a');
    await service.start();
    expect(folder.existsSync(), isFalse);
    expect(legacy.existsSync(), isFalse);
    expect(unrelated.existsSync(), isTrue);
    expect(store.records['a']!.ocrText, 'Alpha text');
  });

  test('store failure surfaces as error phase with the message', () async {
    final failing = _FailingStore();
    service = DefaultIndexingService(
      gallery: gallery,
      store: failing,
      ocr: ocr,
      semantic: model,
      hasher: (b) async => 1,
      tempDirectory: () async => temp,
      clock: () => now,
    );
    await service.start();
    expect(service.current.phase, IndexingPhase.error);
    expect(service.current.errorMessage, contains('disk full'));
  });
}

class _FailingStore extends FakeIndexStore {
  @override
  Future<void> upsertAll(List<IndexRecord> list) async => throw const FileSystemException('disk full');
}
