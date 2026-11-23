// Benchmark for the index store at realistic gallery size. Prints timings;
// the assertion thresholds are deliberately loose so slower CI hosts pass.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:ai_gallery/data/db/sqlite_index_store.dart';
import 'package:ai_gallery/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures.dart';

const _words = [
  'invoice', 'total', 'meeting', 'tomorrow', 'password', 'flight', 'boarding', 'gate', 'receipt',
  'coffee', 'order', 'delivery', 'address', 'street', 'message', 'hello', 'thanks', 'ticket',
  'concert', 'payment', 'amount', 'account', 'balance', 'transfer', 'shopping', 'list', 'recipe',
];

double _median(List<double> xs) => (xs..sort())[xs.length ~/ 2];

void main() {
  test('benchmark: 20k x 512 upsert / vector / text search', () async {
    const n = 20000;
    const dim = 512;
    final dir = Directory.systemTemp.createTempSync('idx_bench_');
    final store = SqliteIndexStore(p.join(dir.path, 'bench.db'));
    await store.open();
    addTearDown(() async {
      await store.close();
      dir.deleteSync(recursive: true);
    });

    final rnd = Random(42);
    final records = <IndexRecord>[];
    for (var i = 0; i < n; i++) {
      final hasText = i % 3 != 0;
      final text = hasText ? List.generate(25 + rnd.nextInt(30), (_) => _words[rnd.nextInt(_words.length)]).join(' ') : '';
      records.add(record(
        'img$i',
        ocr: text,
        createdAt: DateTime(2020).add(Duration(hours: i * 3)),
        kind: i % 4 == 0 ? ImageKind.screenshot : ImageKind.photo,
        embedding: unitVector(rnd, dim),
        phash: (rnd.nextInt(1 << 32) << 32) | rnd.nextInt(1 << 32),
      ));
    }

    // Typical indexing batch (what the indexing service should send).
    final sw = Stopwatch()..start();
    await store.upsertAll(records.sublist(0, 100));
    final batch100Ms = sw.elapsedMicroseconds / 1000;

    sw.reset();
    await store.upsertAll(records.sublist(100));
    final bulkMs = sw.elapsedMicroseconds / 1000;

    // First search loads the matrix in a background isolate; measure how
    // long the UI isolate's event loop is blocked meanwhile.
    final q = unitVector(rnd, dim);
    var maxStallUs = 0;
    final tick = Stopwatch()..start();
    final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      maxStallUs = max(maxStallUs, tick.elapsedMicroseconds);
      tick.reset();
    });
    sw.reset();
    await store.searchVector(q, modelId: 'mobileclip_s0', limit: 200);
    final firstVectorMs = sw.elapsedMicroseconds / 1000;
    timer.cancel();

    final vecTimes = <double>[];
    final filteredTimes = <double>[];
    final filters = SearchFilters(
      kinds: const {ImageKind.screenshot},
      dateRange: DateRange(DateTime(2021), DateTime(2025), label: 'x'),
    );
    for (var i = 0; i < 30; i++) {
      final query = unitVector(rnd, dim);
      sw.reset();
      final hits = await store.searchVector(query, modelId: 'mobileclip_s0', limit: 200);
      vecTimes.add(sw.elapsedMicroseconds / 1000);
      expect(hits, hasLength(200));
      sw.reset();
      await store.searchVector(query, modelId: 'mobileclip_s0', filters: filters, limit: 200);
      filteredTimes.add(sw.elapsedMicroseconds / 1000);
    }

    final textTimes = <double>[];
    for (var i = 0; i < 20; i++) {
      sw.reset();
      final hits = await store.searchText(terms: [_words[i % _words.length], 'pay', 'boarding'], phrases: ['gate receipt']);
      textTimes.add(sw.elapsedMicroseconds / 1000);
      expect(hits, isNotEmpty);
    }

    sw.reset();
    await store.nearDuplicates(records[5].perceptualHash!);
    final dupFirstMs = sw.elapsedMicroseconds / 1000;
    sw.reset();
    await store.nearDuplicates(records[6].perceptualHash!);
    final dupMs = sw.elapsedMicroseconds / 1000;

    // Re-index batches of 100 existing images: same text (no WAL truncate)
    // vs changed text (QA-07: one wal_checkpoint(TRUNCATE) per batch).
    final reSame = <double>[];
    final reChanged = <double>[];
    for (var b = 0; b < 5; b++) {
      final batch = records.sublist(1000 + b * 100, 1100 + b * 100);
      sw.reset();
      await store.upsertAll(batch);
      reSame.add(sw.elapsedMicroseconds / 1000);
      final changed = [
        for (final r in batch)
          record(r.image.id, ocr: '${r.ocrText} edited', createdAt: r.image.createdAt, kind: r.image.kind,
              embedding: r.embedding, phash: r.perceptualHash),
      ];
      sw.reset();
      await store.upsertAll(changed);
      reChanged.add(sw.elapsedMicroseconds / 1000);
    }

    final stats = await store.stats();
    sw.reset();
    await store.clearAll();
    final clearMs = sw.elapsedMicroseconds / 1000;

    print('--- IndexStore benchmark ($n images, $dim-d) ---');
    print('upsertAll 100 records:          ${batch100Ms.toStringAsFixed(1)} ms');
    print('upsertAll ${n - 100} records:       ${bulkMs.toStringAsFixed(0)} ms '
        '(${(bulkMs / (n - 100) * 1000).toStringAsFixed(0)} us/record)');
    print('DB size:                        ${(stats.databaseBytes / 1048576).toStringAsFixed(1)} MiB');
    print('searchVector first (lazy load): ${firstVectorMs.toStringAsFixed(1)} ms wall, '
        'max UI-isolate stall ${(maxStallUs / 1000).toStringAsFixed(1)} ms');
    print('searchVector median / max:      ${_median(vecTimes).toStringAsFixed(2)} / '
        '${vecTimes.reduce(max).toStringAsFixed(2)} ms');
    print('searchVector filtered median:   ${_median(filteredTimes).toStringAsFixed(2)} ms');
    print('searchText (4 parts) median:    ${_median(textTimes).toStringAsFixed(2)} ms');
    print('nearDuplicates first / warm:    ${dupFirstMs.toStringAsFixed(1)} / ${dupMs.toStringAsFixed(2)} ms');
    print('re-index 100, same text median: ${_median(reSame).toStringAsFixed(1)} ms');
    print('re-index 100, changed text med: ${_median(reChanged).toStringAsFixed(1)} ms (incl. WAL truncate)');
    print('clearAll (+VACUUM):             ${clearMs.toStringAsFixed(0)} ms');

    expect(_median(vecTimes), lessThan(50));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
