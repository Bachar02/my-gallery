import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ai_gallery/data/db/schema.dart';
import 'package:ai_gallery/data/db/sqlite_index_store.dart';
import 'package:ai_gallery/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'fixtures.dart';

void main() {
  late SqliteIndexStore store;

  setUp(() async {
    store = SqliteIndexStore.inMemory();
    await store.open();
  });

  tearDown(() => store.close());

  Future<List<String>> textIds(List<String> terms,
      {List<String> phrases = const [], SearchFilters filters = SearchFilters.none}) async {
    final hits = await store.searchText(terms: terms, phrases: phrases, filters: filters);
    return [for (final h in hits) h.imageId];
  }

  group('schema', () {
    test('migrates an empty file to the latest version with WAL', () async {
      final dir = Directory.systemTemp.createTempSync('idx_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'a.db');
      final s = SqliteIndexStore(path);
      await s.open();
      await s.upsert(record('1', ocr: 'hello'));
      await s.close();

      final db = sqlite3.open(path);
      addTearDown(db.close);
      expect(db.userVersion, latestSchemaVersion);
      expect(db.select('PRAGMA journal_mode').first.columnAt(0), 'wal');
      final tables = {for (final r in db.select("SELECT name FROM sqlite_schema WHERE type = 'table'")) r.columnAt(0)};
      expect(tables, containsAll(['images', 'embeddings', 'recent_searches', 'settings', 'images_fts']));

      // Reopening an up-to-date file keeps the data.
      final again = SqliteIndexStore(path);
      await again.open();
      expect((await again.get('1'))!.ocrText, 'hello');
      await again.close();
    });

    test('methods after close throw StateError', () async {
      await store.close();
      expect(() => store.stats(), throwsStateError);
      expect(() => store.searchText(terms: ['x']), throwsStateError);
      expect(() => store.open(), throwsStateError);
    });
  });

  group('upsert / get', () {
    test('roundtrip with embedding and negative phash', () async {
      final emb = unitVector(Random(1), 16);
      final created = DateTime(2024, 3, 4, 5, 6, 7, 8);
      await store.upsert(IndexRecord(
        image: GalleryImage(
          id: '42',
          filename: 'Screenshot_x.png',
          relativePath: 'Pictures/Screenshots/',
          mimeType: 'image/png',
          width: 720,
          height: 1600,
          createdAt: created,
          modifiedAt: created.add(const Duration(minutes: 1)),
          kind: ImageKind.screenshot,
        ),
        ocrText: 'Boarding pass',
        embedding: emb,
        embeddingModel: 'mobileclip_s0',
        perceptualHash: -0x7123456789abcdef,
        indexedAt: DateTime(2025),
        pipelineVersion: 3,
      ));
      final r = (await store.get('42'))!;
      expect(r.image.filename, 'Screenshot_x.png');
      expect(r.image.relativePath, 'Pictures/Screenshots/');
      expect(r.image.mimeType, 'image/png');
      expect(r.image.width, 720);
      expect(r.image.height, 1600);
      expect(r.image.createdAt, created);
      expect(r.image.modifiedAt, created.add(const Duration(minutes: 1)));
      expect(r.image.kind, ImageKind.screenshot);
      expect(r.ocrText, 'Boarding pass');
      expect(r.embedding, orderedEquals(emb));
      expect(r.embeddingModel, 'mobileclip_s0');
      expect(r.perceptualHash, -0x7123456789abcdef);
      expect(r.indexedAt, DateTime(2025));
      expect(r.pipelineVersion, 3);
    });

    test('null embedding, and upsert replaces / removes the embedding', () async {
      await store.upsert(record('a'));
      var r = (await store.get('a'))!;
      expect(r.embedding, isNull);
      expect(r.embeddingModel, isNull);
      expect(r.perceptualHash, isNull);

      final e1 = unitVector(Random(2), 8);
      await store.upsert(record('a', embedding: e1, ocr: 'one'));
      expect((await store.get('a'))!.embedding, orderedEquals(e1));

      final e2 = unitVector(Random(3), 8);
      await store.upsert(record('a', embedding: e2, model: 'other', ocr: 'two'));
      r = (await store.get('a'))!;
      expect(r.embedding, orderedEquals(e2));
      expect(r.embeddingModel, 'other');
      expect((await store.stats()).imagesWithEmbedding, 1);

      await store.upsert(record('a', ocr: 'three'));
      expect((await store.get('a'))!.embedding, isNull);
      expect((await store.stats()).imagesWithEmbedding, 0);
      expect(await textIds(['one']), isEmpty);
      expect(await textIds(['two']), isEmpty);
      expect(await textIds(['three']), ['a']);
    });

    test('embedding view with offset is stored correctly', () async {
      final backing = Float32List.fromList(List.generate(10, (i) => i.toDouble()));
      final view = Float32List.sublistView(backing, 3, 7);
      await store.upsert(record('v', embedding: view));
      expect((await store.get('v'))!.embedding, orderedEquals([3, 4, 5, 6]));
    });

    test('get of unknown id is null; getImages keeps order and skips unknown', () async {
      expect(await store.get('nope'), isNull);
      await store.upsertAll([record('1'), record('2'), record('3')]);
      final imgs = await store.getImages(['3', 'x', '1', '2']);
      expect([for (final i in imgs) i.id], ['3', '1', '2']);
      expect(await store.getImages([]), isEmpty);
    });

    test('indexedVersions', () async {
      await store.upsertAll([
        IndexRecord(
          image: image('a', modifiedAt: DateTime.fromMillisecondsSinceEpoch(1000)),
          ocrText: '',
          indexedAt: baseTime,
          pipelineVersion: 2,
        ),
        record('b', pipelineVersion: 5),
      ]);
      final v = await store.indexedVersions();
      expect(v.keys, unorderedEquals(['a', 'b']));
      expect(v['a']!.modifiedAtMs, 1000);
      expect(v['a']!.pipelineVersion, 2);
      expect(v['b']!.pipelineVersion, 5);
    });

    test('zero-length embedding is stored as no embedding', () async {
      await store.upsert(IndexRecord(
        image: image('z'),
        ocrText: 'x',
        embedding: Float32List(0),
        embeddingModel: 'm',
        indexedAt: baseTime,
        pipelineVersion: 1,
      ));
      expect((await store.get('z'))!.embedding, isNull);
    });

    test('upsertAll is atomic: a failing record rolls back the whole batch', () async {
      final dir = Directory.systemTemp.createTempSync('idx_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'tx.db');
      final s = SqliteIndexStore(path);
      await s.open();
      addTearDown(s.close);
      await s.upsert(record('keep', ocr: 'original'));
      // Make one record fail inside the transaction.
      final raw = sqlite3.open(path);
      raw.execute("CREATE TRIGGER fail_bad BEFORE INSERT ON images WHEN new.id = 'bad' "
          "BEGIN SELECT RAISE(ABORT, 'boom'); END");
      raw.close();
      await expectLater(
        s.upsertAll([record('keep', ocr: 'changed'), record('good'), record('bad')]),
        throwsA(isA<SqliteException>()),
      );
      expect((await s.get('keep'))!.ocrText, 'original');
      expect(await s.get('good'), isNull);
      expect([for (final h in await s.searchText(terms: ['original'])) h.imageId], ['keep']);
    });
  });

  group('delete', () {
    test('cascades to embeddings and FTS', () async {
      final rnd = Random(4);
      await store.upsertAll([
        record('a', ocr: 'alpha text', embedding: unitVector(rnd, 8), phash: 7),
        record('b', ocr: 'alpha beta', embedding: unitVector(rnd, 8), phash: 7),
      ]);
      // Load the in-memory indices before deleting.
      expect(await store.searchVector(unitVector(rnd, 8), modelId: 'mobileclip_s0'), hasLength(2));
      expect(await store.nearDuplicates(7), hasLength(2));

      await store.delete(['a', 'missing']);
      expect(await store.get('a'), isNull);
      expect(await textIds(['alpha']), ['b']);
      final s = await store.stats();
      expect(s.indexedImages, 1);
      expect(s.imagesWithEmbedding, 1);
      expect([for (final h in await store.searchVector(unitVector(rnd, 8), modelId: 'mobileclip_s0')) h.imageId],
          ['b']);
      expect(await store.nearDuplicates(7), ['b']);
    });
  });

  group('searchText', () {
    setUp(() async {
      await store.upsertAll([
        record('cafe', ocr: 'Le Café de Flore — reçu n°123', createdAt: DateTime(2025, 1, 10)),
        record('invoice', ocr: 'INVOICE #2024-77 Total due: 120 EUR', kind: ImageKind.screenshot,
            createdAt: DateTime(2025, 2, 1)),
        record('meeting', ocr: 'Meeting with Jamie tomorrow at 10am', kind: ImageKind.screenshot,
            createdAt: DateTime(2025, 3, 1)),
        record('jamie_file', filename: 'jamie_birthday.jpg', createdAt: DateTime(2025, 4, 1)),
        record('wifi', ocr: 'WiFi password: hunter2 network HomeNet', kind: ImageKind.screenshot,
            createdAt: DateTime(2025, 5, 1)),
        record('empty', createdAt: DateTime(2025, 6, 1)),
      ]);
    });

    test('prefix matching', () async {
      expect(await textIds(['invo']), ['invoice']);
      expect(await textIds(['passw']), ['wifi']);
      expect(await textIds(['xyz']), isEmpty);
    });

    test('case-insensitive and diacritic-insensitive', () async {
      expect(await textIds(['cafe']), ['cafe']);
      expect(await textIds(['CAFÉ']), ['cafe']);
      expect(await textIds(['recu']), ['cafe']);
      expect(await textIds(['Invoice']), ['invoice']);
    });

    test('phrases match verbatim consecutive words only', () async {
      expect(await textIds([], phrases: ['with Jamie']), ['meeting']);
      expect(await textIds([], phrases: ['Jamie with']), isEmpty);
      expect(await textIds([], phrases: ['total due']), ['invoice']);
      // Phrases are not prefix matches.
      expect(await textIds([], phrases: ['tot due']), isEmpty);
    });

    test('filename is searchable', () async {
      expect(await textIds(['birthday']), ['jamie_file']);
    });

    test('OR across terms with precise matchedTerms', () async {
      final hits = await store.searchText(terms: ['jamie', 'password', 'nothing'], phrases: ['total due']);
      final byId = {for (final h in hits) h.imageId: h};
      expect(byId.keys, unorderedEquals(['meeting', 'jamie_file', 'wifi', 'invoice']));
      expect(byId['meeting']!.matchedTerms, ['jamie']);
      expect(byId['jamie_file']!.matchedTerms, ['jamie']);
      expect(byId['wifi']!.matchedTerms, ['password']);
      expect(byId['invoice']!.matchedTerms, ['total due']);

      final both = await store.searchText(terms: ['wifi', 'hunter', 'meeting']);
      final w = both.firstWhere((h) => h.imageId == 'wifi');
      expect(w.matchedTerms, ['wifi', 'hunter']);
    });

    test('filters are applied in SQL', () async {
      expect(
        await textIds(['jamie'], filters: const SearchFilters(kinds: {ImageKind.screenshot})),
        ['meeting'],
      );
      expect(
        await textIds(['jamie'],
            filters: SearchFilters(
                dateRange: DateRange(DateTime(2025, 3, 15), DateTime(2025, 4, 2), label: 'x'))),
        ['jamie_file'],
      );
      // End is exclusive.
      expect(
        await textIds(['jamie'],
            filters: SearchFilters(dateRange: DateRange(DateTime(2025, 1, 1), DateTime(2025, 3, 1), label: 'x'))),
        isEmpty,
      );
    });

    test('limit is honoured', () async {
      final hits = await store.searchText(terms: ['jamie'], limit: 1);
      expect(hits, hasLength(1));
    });

    test('snippet is an excerpt of the OCR text', () async {
      final long = '${'lorem ipsum ' * 30}the secret keyword appears here ${'dolor sit amet ' * 30}';
      await store.upsert(record('long', ocr: long));
      final hit = (await store.searchText(terms: ['secret'])).single;
      expect(hit.snippet, contains('secret'));
      expect(hit.snippet!.length, lessThan(200));
      final short = (await store.searchText(terms: ['hunter'])).single;
      expect(short.snippet, 'WiFi password: hunter2 network HomeNet');
    });

    test('ranking: OCR beats filename, more matched terms beat fewer, higher score first', () async {
      await store.upsertAll([
        record('r_ocr', ocr: 'receipt from the bakery', filename: 'a.jpg'),
        record('r_name', ocr: 'unrelated words here', filename: 'receipt.jpg'),
        record('r_both', ocr: 'receipt bakery croissant', filename: 'b.jpg'),
      ]);
      final hits = await store.searchText(terms: ['receipt', 'croissant']);
      final ids = [for (final h in hits) h.imageId];
      expect(ids.first, 'r_both');
      expect(ids.indexOf('r_ocr'), lessThan(ids.indexOf('r_name')));
      for (var i = 1; i < hits.length; i++) {
        expect(hits[i - 1].score, greaterThanOrEqualTo(hits[i].score));
      }
      expect(hits.every((h) => h.score > 0), isTrue);
    });

    test('malicious input never throws and never alters results', () async {
      final baseline = await textIds(['invoice']);
      expect(baseline, ['invoice']);
      const nasty = ['"', '*', 'NEAR(', 'OR', 'AND', 'NOT', '-', ':', '^', '(', ')', '""', "'", '{', '}', '+'];
      for (final n in nasty) {
        expect(await textIds(['invoice', n]), baseline, reason: 'term $n');
        expect(await textIds([n]), isEmpty, reason: 'term $n alone');
        expect(await textIds(['invoice'], phrases: [n]), baseline, reason: 'phrase $n');
      }
      expect(await textIds(['inv"oice']), isEmpty); // becomes the phrase "inv oice"*
      expect(await textIds(['ocr_text:invoice']), isEmpty);
      expect(await textIds(['filename:jamie']), isEmpty);
      expect(await textIds(['invoice*']), baseline);
      expect(await textIds(['-invoice']), baseline);
      expect(await textIds(['NEAR(total due)']), ['invoice']);

      // SQL injection attempt is just text.
      expect(await textIds(["'; DROP TABLE images; --"]), isEmpty);
      expect((await store.stats()).indexedImages, 6);
      await store.upsert(record('sql', ocr: "'; DROP TABLE images; --"));
      expect(await textIds(["'; DROP TABLE images; --"]), ['sql']);
      expect(await textIds([], phrases: ['drop table images']), ['sql']);
      expect((await store.stats()).indexedImages, 7);
    });

    test('empty / blank inputs return nothing', () async {
      expect(await textIds([]), isEmpty);
      expect(await textIds(['', '   '], phrases: ['  ']), isEmpty);
    });

    test('updating OCR text re-indexes FTS', () async {
      await store.upsert(record('wifi', ocr: 'completely new text', kind: ImageKind.screenshot));
      expect(await textIds(['password']), isEmpty);
      expect(await textIds(['completely']), ['wifi']);
    });
  });

  group('searchVector', () {
    test('top-K matches brute force, with filters and model isolation', () async {
      final rnd = Random(7);
      const dim = 32;
      final vectors = <String, Float32List>{};
      final records = <IndexRecord>[];
      for (var i = 0; i < 300; i++) {
        final v = unitVector(rnd, dim);
        final id = 'img$i';
        vectors[id] = v;
        records.add(record(
          id,
          embedding: v,
          createdAt: DateTime(2025, 1, 1).add(Duration(days: i)),
          kind: i.isEven ? ImageKind.photo : ImageKind.screenshot,
        ));
      }
      // Same-dimension vectors from another model must never be returned.
      for (var i = 0; i < 50; i++) {
        records.add(record('other$i', embedding: unitVector(rnd, dim), model: 'other_model'));
      }
      await store.upsertAll(records);

      final q = unitVector(rnd, dim);
      List<String> brute(bool Function(int i) keep, int k) {
        final ids = [
          for (var i = 0; i < 300; i++)
            if (keep(i)) 'img$i'
        ]..sort((a, b) => dot(vectors[b]!, q).compareTo(dot(vectors[a]!, q)));
        return ids.take(k).toList();
      }

      final hits = await store.searchVector(q, modelId: 'mobileclip_s0', limit: 20);
      expect([for (final h in hits) h.imageId], brute((_) => true, 20));
      for (final h in hits) {
        expect(h.similarity, closeTo(dot(vectors[h.imageId]!, q), 1e-5));
      }

      final screenshots = await store.searchVector(q,
          modelId: 'mobileclip_s0', limit: 10, filters: const SearchFilters(kinds: {ImageKind.screenshot}));
      expect([for (final h in screenshots) h.imageId], brute((i) => i.isOdd, 10));

      final range = DateRange(DateTime(2025, 2, 1), DateTime(2025, 3, 1), label: 'Feb');
      final feb = await store.searchVector(q, modelId: 'mobileclip_s0', limit: 100, filters: SearchFilters(dateRange: range));
      expect([for (final h in feb) h.imageId], brute((i) => i >= 31 && i < 59, 100));

      final other = await store.searchVector(q, modelId: 'other_model', limit: 500);
      expect(other, hasLength(50));
      expect(other.every((h) => h.imageId.startsWith('other')), isTrue);

      expect(await store.searchVector(q, modelId: 'unknown'), isEmpty);
    });

    test('in-memory index stays in sync with upsert / delete / model change', () async {
      final rnd = Random(9);
      final q = unitVector(rnd, 8);
      await store.upsert(record('a', embedding: unitVector(rnd, 8)));
      expect(await store.searchVector(q, modelId: 'mobileclip_s0'), hasLength(1)); // loads index

      await store.upsert(record('b', embedding: q)); // exact match
      var hits = await store.searchVector(q, modelId: 'mobileclip_s0');
      expect(hits.first.imageId, 'b');
      expect(hits.first.similarity, closeTo(1.0, 1e-6));

      // Metadata change is reflected in filters.
      await store.upsert(record('b', embedding: q, kind: ImageKind.screenshot));
      hits = await store.searchVector(q,
          modelId: 'mobileclip_s0', filters: const SearchFilters(kinds: {ImageKind.photo}));
      expect([for (final h in hits) h.imageId], ['a']);

      // Moving b to another model removes it from this one.
      await store.upsert(record('b', embedding: q, model: 'v2'));
      expect([for (final h in await store.searchVector(q, modelId: 'mobileclip_s0')) h.imageId], ['a']);
      expect([for (final h in await store.searchVector(q, modelId: 'v2')) h.imageId], ['b']);

      // Removing the embedding removes it from the index.
      await store.upsert(record('a'));
      expect(await store.searchVector(q, modelId: 'mobileclip_s0'), isEmpty);

      // Empty-index cache picks up later inserts.
      await store.upsert(record('c', embedding: q));
      expect([for (final h in await store.searchVector(q, modelId: 'mobileclip_s0')) h.imageId], ['c']);

      // Wrong query dimension returns nothing rather than garbage.
      expect(await store.searchVector(unitVector(rnd, 4), modelId: 'mobileclip_s0'), isEmpty);
    });

    test('background (isolate) load replays writes made while it runs', () async {
      final dir = Directory.systemTemp.createTempSync('idx_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final s = SqliteIndexStore(p.join(dir.path, 'iso.db'));
      await s.open();
      final rnd = Random(12);
      final q = unitVector(rnd, 8);
      // Above the isolate threshold; every stored vector is far from q.
      final far = Float32List.fromList([for (final x in q) -x]);
      await s.upsertAll([for (var i = 0; i < 2500; i++) record('$i', embedding: far)]);

      final pending = s.searchVector(q, modelId: 'mobileclip_s0', limit: 3);
      final concurrent = s.searchVector(q, modelId: 'mobileclip_s0', limit: 3);
      await s.upsert(record('best', embedding: q));
      await s.delete(['0', '1']);
      await s.upsert(record('2', embedding: q, model: 'other'));
      final hits = await pending;
      expect(hits.first.imageId, 'best');
      expect(hits.first.similarity, closeTo(1, 1e-6));
      expect((await concurrent).first.imageId, 'best');
      final all = await s.searchVector(q, modelId: 'mobileclip_s0', limit: 5000);
      expect(all, hasLength(2500 - 3 + 1));
      expect(all.map((h) => h.imageId), isNot(contains('0')));
      expect(all.map((h) => h.imageId), isNot(contains('2')));

      // clearAll while a load is in flight: the stale snapshot is discarded.
      await s.close();
      final s2 = SqliteIndexStore(p.join(dir.path, 'iso.db'));
      await s2.open();
      final during = s2.searchVector(q, modelId: 'mobileclip_s0');
      await s2.clearAll();
      expect(await during, isEmpty);
      await s2.close();
    });

    test('index lazily loaded from disk after reopen', () async {
      final dir = Directory.systemTemp.createTempSync('idx_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'v.db');
      final rnd = Random(11);
      final q = unitVector(rnd, 12);
      var s = SqliteIndexStore(path);
      await s.open();
      await s.upsertAll([record('x', embedding: q), record('y', embedding: unitVector(rnd, 12))]);
      await s.close();
      s = SqliteIndexStore(path);
      await s.open();
      final hits = await s.searchVector(q, modelId: 'mobileclip_s0');
      expect(hits.first.imageId, 'x');
      expect(hits.first.similarity, closeTo(1, 1e-6));
      await s.close();
    });
  });

  group('nearDuplicates', () {
    test('Hamming distance over signed 64-bit hashes', () async {
      const h = -0x0123456789abcdef; // negative: top bit set
      const top = 1 << 63;
      await store.upsertAll([
        record('same', phash: h),
        record('d1', phash: h ^ 1),
        record('d4', phash: h ^ (top | 0x7)), // bits 63, 0, 1, 2
        record('d5', phash: h ^ 0x1F),
        record('far', phash: ~h),
        record('none'),
      ]);
      expect(await store.nearDuplicates(h, maxDistance: 0), ['same']);
      expect(await store.nearDuplicates(h, maxDistance: 1), ['same', 'd1']);
      expect(await store.nearDuplicates(h, maxDistance: 4), ['same', 'd1', 'd4']);
      expect(await store.nearDuplicates(h, maxDistance: 5), ['same', 'd1', 'd4', 'd5']);
      expect(await store.nearDuplicates(h, maxDistance: 64), hasLength(5));
      expect(await store.nearDuplicates(~h, maxDistance: 0), ['far']);
      // Cache stays in sync with later upserts.
      await store.upsert(record('late', phash: h ^ 2));
      expect(await store.nearDuplicates(h, maxDistance: 1), ['same', 'd1', 'late']);
    });
  });

  group('browse / stats', () {
    test('browse filters, newest first', () async {
      await store.upsertAll([
        record('old', createdAt: DateTime(2024, 1, 1)),
        record('mid', createdAt: DateTime(2024, 6, 1), kind: ImageKind.screenshot),
        record('new', createdAt: DateTime(2025, 1, 1)),
      ]);
      expect([for (final i in await store.browse()) i.id], ['new', 'mid', 'old']);
      expect([for (final i in await store.browse(limit: 2)) i.id], ['new', 'mid']);
      expect(
        [for (final i in await store.browse(filters: const SearchFilters(kinds: {ImageKind.photo}))) i.id],
        ['new', 'old'],
      );
      expect(
        [
          for (final i in await store.browse(
              filters: SearchFilters(dateRange: DateRange(DateTime(2024), DateTime(2025), label: '2024'))))
            i.id
        ],
        ['mid', 'old'],
      );
    });

    test('stats', () async {
      expect((await store.stats()).indexedImages, 0);
      expect((await store.stats()).lastIndexedAt, isNull);
      final rnd = Random(5);
      await store.upsertAll([
        record('a', ocr: 'text', kind: ImageKind.screenshot, indexedAt: DateTime(2025, 1, 1)),
        record('b', ocr: '   ', embedding: unitVector(rnd, 8), indexedAt: DateTime(2025, 2, 1)),
        record('c', embedding: unitVector(rnd, 8), kind: ImageKind.screenshot, indexedAt: DateTime(2024)),
      ]);
      final s = await store.stats();
      expect(s.indexedImages, 3);
      expect(s.screenshots, 2);
      expect(s.imagesWithText, 1);
      expect(s.imagesWithEmbedding, 2);
      expect(s.databaseBytes, greaterThan(0));
      expect(s.lastIndexedAt, DateTime(2025, 2, 1));
    });
  });

  group('clearAll', () {
    test('wipes data, FTS, recent searches and memory indices; keeps settings; shrinks file', () async {
      final dir = Directory.systemTemp.createTempSync('idx_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final s = SqliteIndexStore(p.join(dir.path, 'c.db'));
      await s.open();
      addTearDown(s.close);
      final rnd = Random(6);
      final q = unitVector(rnd, 64);
      await s.upsertAll([
        for (var i = 0; i < 500; i++)
          record('$i', ocr: 'secret account number ${i * 7919} ' * 10, embedding: unitVector(rnd, 64), phash: i),
      ]);
      await s.setSetting('theme', 'dark');
      await s.addRecentSearch('secret');
      expect(await s.searchVector(q, modelId: 'mobileclip_s0'), isNotEmpty);
      expect(await s.nearDuplicates(0), isNotEmpty);
      final before = (await s.stats()).databaseBytes;

      await s.clearAll();
      final st = await s.stats();
      expect(st.indexedImages, 0);
      expect(st.imagesWithEmbedding, 0);
      final fresh = SqliteIndexStore(p.join(dir.path, 'fresh.db'));
      await fresh.open();
      final emptySize = (await fresh.stats()).databaseBytes;
      await fresh.close();
      expect(st.databaseBytes, lessThanOrEqualTo(emptySize));
      expect(st.databaseBytes, lessThan(before));
      expect(await s.searchText(terms: ['secret']), isEmpty);
      expect(await s.searchVector(q, modelId: 'mobileclip_s0'), isEmpty);
      expect(await s.nearDuplicates(0), isEmpty);
      expect(await s.recentSearches(), isEmpty);
      expect(await s.getSetting('theme'), 'dark');
      expect(await s.indexedVersions(), isEmpty);

      // Old text is not left anywhere in the main file (secure_delete + VACUUM).
      final bytes = File(p.join(dir.path, 'c.db')).readAsBytesSync();
      expect(String.fromCharCodes(bytes).contains('secret account'), isFalse);

      // Still usable afterwards and memory indices rebuild.
      await s.upsert(record('n', ocr: 'fresh', embedding: q, phash: 0));
      expect([for (final h in await s.searchVector(q, modelId: 'mobileclip_s0')) h.imageId], ['n']);
      expect(await s.nearDuplicates(0), ['n']);
      expect([for (final h in await s.searchText(terms: ['fresh'])) h.imageId], ['n']);
    });
  });

  group('recent searches', () {
    test('most recent first, case-insensitive dedupe, blank ignored, trimmed to 50', () async {
      await store.addRecentSearch('cats');
      await store.addRecentSearch('  ');
      await store.addRecentSearch('');
      await store.addRecentSearch('dogs');
      await store.addRecentSearch('  CATS  ');
      expect(await store.recentSearches(), ['CATS', 'dogs']);
      expect(await store.recentSearches(limit: 1), ['CATS']);

      for (var i = 0; i < 60; i++) {
        await store.addRecentSearch('q$i');
      }
      final all = await store.recentSearches(limit: 1000);
      expect(all, hasLength(50));
      expect(all.first, 'q59');
      expect(all.last, 'q10');

      await store.clearRecentSearches();
      expect(await store.recentSearches(), isEmpty);
    });
  });

  group('settings', () {
    test('get / set / overwrite / remove', () async {
      expect(await store.getSetting('k'), isNull);
      await store.setSetting('k', 'v1');
      await store.setSetting('k', 'v2');
      expect(await store.getSetting('k'), 'v2');
      await store.setSetting('k', null);
      expect(await store.getSetting('k'), isNull);
      await store.setSetting("'; DROP TABLE settings; --", 'x');
      expect(await store.getSetting("'; DROP TABLE settings; --"), 'x');
    });
  });

  group('robustness', () {
    test('corrupted file is discarded and recreated', () async {
      final dir = Directory.systemTemp.createTempSync('idx_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'bad.db');
      File(path).writeAsBytesSync(List.generate(64 * 1024, (i) => (i * 31 + 7) & 0xff));
      final s = SqliteIndexStore(path);
      await s.open();
      expect((await s.stats()).indexedImages, 0);
      await s.upsert(record('1', ocr: 'works'));
      expect([for (final h in await s.searchText(terms: ['works'])) h.imageId], ['1']);
      await s.close();
    });

    test('file from a newer schema version is recreated', () async {
      final dir = Directory.systemTemp.createTempSync('idx_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'new.db');
      final raw = sqlite3.open(path)..userVersion = 999;
      raw.execute('CREATE TABLE foo (x)');
      raw.close();
      final s = SqliteIndexStore(path);
      await s.open();
      expect((await s.stats()).indexedImages, 0);
      await s.close();
      final check = sqlite3.open(path);
      expect(check.userVersion, latestSchemaVersion);
      check.close();
    });

    test('foreign keys are enforced', () async {
      final dir = Directory.systemTemp.createTempSync('idx_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'fk.db');
      final s = SqliteIndexStore(path);
      await s.open();
      await s.close();
      final db = sqlite3.open(path)..execute('PRAGMA foreign_keys = ON');
      addTearDown(db.close);
      expect(
        () => db.execute("INSERT INTO embeddings (image_id, model_id, dim, vector) VALUES ('ghost', 'm', 1, x'00000000')"),
        throwsA(isA<SqliteException>()),
      );
    });
  });
}
