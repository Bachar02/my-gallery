// QA robustness checks for DefaultIndexingService: lifecycle races
// (pause/resume/stop/start, delete-while-indexing, app resume), empty
// gallery, temp-file cleanup and what the error state exposes.

import 'dart:async';
import 'dart:io';

import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/indexing/default_indexing_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../features/search/data/fakes.dart';

void main() {
  final now = DateTime(2026, 11, 23, 10);
  late FakeIndexStore store;
  late FakeGallery gallery;
  late FakeOcr ocr;
  late FakeSemanticModel model;
  late Directory temp;
  late List<IndexingProgress> events;
  late DefaultIndexingService service;

  DefaultIndexingService build({int batchSize = 50}) {
    final s = DefaultIndexingService(
      gallery: gallery,
      store: store,
      ocr: ocr,
      semantic: model,
      hasher: (bytes) async => bytes.length,
      tempDirectory: () async => temp,
      clock: () => now,
      batchSize: batchSize,
      resyncDebounce: const Duration(milliseconds: 20),
    );
    s.progress.listen(events.add);
    return s;
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('qa_indexing');
    store = FakeIndexStore();
    gallery = FakeGallery([
      for (var i = 9; i >= 0; i--) galleryImage('i$i', created: DateTime(2026, 11, 1 + i)),
    ]);
    ocr = FakeOcr({for (var i = 0; i < 10; i++) 'i$i': 'text $i'});
    model = FakeSemanticModel();
    events = [];
    service = build();
  });

  tearDown(() async {
    await service.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Makes OCR wait on a gate before recognising [id].
  Completer<void> blockAt(String id) {
    final gate = Completer<void>();
    final reached = Completer<void>();
    ocr.beforeRecognize = (seen) async {
      if (seen == id) {
        if (!reached.isCompleted) reached.complete();
        await gate.future;
      }
    };
    return gate;
  }

  Future<void> untilProcessing(String id) async {
    for (var i = 0; i < 200 && !ocr.calls.contains(id); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(ocr.calls, contains(id));
  }

  test('empty gallery completes with nothing to do', () async {
    gallery.images = [];
    await service.start();
    expect(service.current.phase, IndexingPhase.completed);
    expect(service.current.total, 0);
    expect(store.records, isEmpty);
    expect(store.upsertAllSizes, isEmpty);
  });

  test('delete index while indexing runs: stop then clearAll leaves the index empty', () async {
    // Mirrors DeleteIndexController: stop() then clearAll(). Work that was
    // in flight must be flushed BEFORE the wipe, never after it.
    final gate = blockAt('i5');
    final run = service.start();
    await untilProcessing('i5');
    final stopped = service.stop();
    gate.complete();
    await stopped;
    await run;
    await store.clearAll();
    // Let any stray timers / continuations run.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(store.records, isEmpty);
    expect(service.current.phase, IndexingPhase.idle);
  });

  test('a gallery change during a stopped run does not resurrect the index', () async {
    final gate = blockAt('i5');
    final run = service.start();
    await untilProcessing('i5');
    gallery.changesController.add(null); // MediaStore notification mid-run
    // Let the debounce fire while the run is busy (marks a re-sync pending).
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final stopped = service.stop();
    gate.complete();
    await stopped;
    await run;
    await store.clearAll();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(store.records, isEmpty, reason: 'a pending re-sync ran after stop + clearAll');
  });

  test('start after stop runs a fresh, complete sync', () async {
    final gate = blockAt('i5');
    final run = service.start();
    await untilProcessing('i5');
    final stopped = service.stop();
    gate.complete();
    await stopped;
    await run;
    ocr.beforeRecognize = null;
    await service.start();
    expect(service.current.phase, IndexingPhase.completed);
    expect(store.records.length, 10);
  });

  test('pause + resume before the next item boundary does not hang', () async {
    final gate = blockAt('i8');
    final run = service.start();
    await untilProcessing('i8');
    service.pause();
    service.resume();
    gate.complete();
    await run.timeout(const Duration(seconds: 5));
    expect(service.current.phase, IndexingPhase.completed);
    expect(store.records.length, 10);
  });

  test('rapid pause/resume toggling processes every image exactly once', () async {
    var toggles = 0;
    ocr.beforeRecognize = (id) async {
      if (toggles++ < 30) {
        service.pause();
        if (toggles.isEven) service.resume();
      }
    };
    final run = service.start();
    for (var i = 0; i < 50 && service.current.phase != IndexingPhase.completed; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      service.resume();
    }
    await run.timeout(const Duration(seconds: 5));
    expect(service.current.phase, IndexingPhase.completed);
    expect(store.records.length, 10);
    expect(ocr.calls.toSet().length, ocr.calls.length, reason: 'an image was processed twice');
  });

  test('pause requested during scanning takes effect at the first item', () async {
    final run = service.start();
    service.pause(); // still scanning
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(service.current.phase, IndexingPhase.paused);
    expect(ocr.calls, isEmpty);
    service.resume();
    await run;
    expect(service.current.phase, IndexingPhase.completed);
  });

  test('resume/stop/pause while idle are harmless', () async {
    service.resume();
    service.pause();
    await service.stop();
    await service.start();
    expect(service.current.phase, IndexingPhase.completed);
    expect(store.records.length, 10);
  });

  test('app resume during indexing (start while running) joins the running sync', () async {
    final gate = blockAt('i7');
    final first = service.start();
    await untilProcessing('i7');
    final second = service.start();
    final third = service.start();
    gate.complete();
    await Future.wait([first, second, third]);
    expect(gallery.listCalls, 1);
    expect(store.records.length, 10);
  });

  test('app resume while paused keeps the run paused (start joins, does not unpause)', () async {
    final gate = blockAt('i8');
    final run = service.start();
    await untilProcessing('i8');
    service.pause();
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(service.current.phase, IndexingPhase.paused);
    unawaited(service.start());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(service.current.phase, IndexingPhase.paused);
    service.resume();
    await run;
    expect(service.current.phase, IndexingPhase.completed);
  });

  test('dispose while paused completes without hanging', () async {
    final gate = blockAt('i8');
    final run = service.start();
    await untilProcessing('i8');
    service.pause();
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await service.dispose().timeout(const Duration(seconds: 5));
    await run.timeout(const Duration(seconds: 5));
  });

  test('permission revoked before the first item: permissionDenied, nothing failed', () async {
    ocr.beforeRecognize = null;
    var first = true;
    gallery.onAccess = (id) {
      if (first) {
        first = false;
        gallery.permission = GalleryPermission.denied;
      }
    };
    await service.start();
    expect(service.current.phase, IndexingPhase.permissionDenied);
    expect(service.current.failed, 0);
    expect(store.records, isEmpty);
    // Access restored (app resume): the next sync indexes everything.
    gallery.onAccess = null;
    gallery.permission = GalleryPermission.granted;
    await service.start();
    expect(service.current.phase, IndexingPhase.completed);
    expect(store.records.length, 10);
  });

  test('every image deleted between listing and processing: no failures, index emptied', () async {
    gallery.onAccess = (id) => gallery.images.removeWhere((i) => i.id == id);
    await service.start();
    expect(service.current.phase, IndexingPhase.completed);
    expect(service.current.failed, 0);
    expect(store.records, isEmpty);
  });

  test('OCR fallback temp files are deleted, on success and on failure', () async {
    gallery.noOriginal.addAll(['i1', 'i2', 'i3']);
    ocr.failIds.add('i2');
    await service.start();
    expect(store.records.containsKey('i1'), isTrue);
    expect(service.current.failed, 1);
    expect(temp.listSync(), isEmpty, reason: 'temp OCR renditions left behind');
  });

  test('error state never exposes SQL parameters (OCR text) or file paths', () async {
    final failing = _ThrowingStore(SqliteException(
      extendedResultCode: 13,
      message: 'database or disk is full',
      causingStatement: 'INSERT INTO images (id, ocr_text) VALUES (?, ?)',
      parametersToStatement: ['i9', 'IBAN DE89 3704 0044 secret'],
    ));
    final s = DefaultIndexingService(
      gallery: gallery,
      store: failing,
      ocr: ocr,
      semantic: model,
      hasher: (b) async => 1,
      tempDirectory: () async => temp,
      clock: () => now,
    );
    addTearDown(s.dispose);
    await s.start();
    expect(s.current.phase, IndexingPhase.error);
    expect(s.current.errorMessage, contains('disk is full'));
    expect(s.current.errorMessage, isNot(contains('IBAN')));
    expect(s.current.errorMessage, isNot(contains('INSERT')));

    expect(
      DefaultIndexingService.userFacingError(
          const FileSystemException('No space left', '/data/user/0/app/files/index/Screenshot_Jamie.png')),
      allOf(contains('No space left'), isNot(contains('Jamie'))),
    );
  });
}

class _ThrowingStore extends FakeIndexStore {
  _ThrowingStore(this.error);
  final Object error;

  @override
  Future<void> upsertAll(List<IndexRecord> list) async => throw error;
}
