// End-to-end search latency through HybridSearchEngine (real SQLite store on
// a temp file, real parser, fake 512-d model) at 10k and 20k images, plus
// adversarial queries (very long, emoji, RTL). Prints timings; assertions are
// loose so slower hosts pass. Numbers are recorded in docs/QA_REPORT.md.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ai_gallery/data/db/sqlite_index_store.dart';
import 'package:ai_gallery/domain/interfaces.dart';
import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/search/data/hybrid_search_engine.dart';
import 'package:ai_gallery/features/search/data/rule_based_query_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../data/fixtures.dart';

class _RandomTextModel implements SemanticModel {
  _RandomTextModel(this._rnd);
  final Random _rnd;
  @override
  String get modelId => 'mobileclip_s0';
  @override
  int get dimension => 512;
  @override
  bool get isLoaded => true;
  @override
  Future<bool> load() async => true;
  @override
  Future<Float32List> embedImage(Uint8List encodedImage) => throw UnimplementedError();
  @override
  Future<Float32List> embedText(String text) async => unitVector(_rnd, 512);
  @override
  Future<void> dispose() async {}
}

const _common = [
  'the', 'total', 'order', 'invoice', 'payment', 'meeting', 'tomorrow', 'password', 'flight', 'gate', 'seat',
  'receipt', 'delivery', 'address', 'street', 'message', 'thanks', 'ticket', 'account', 'number', 'bank',
  'iban', 'hello', 'dinner', 'friday', 'jamie', 'sam', 'alex', 'berlin', 'munich', 'germany', 'trip',
];

double _median(List<double> xs) => (List.of(xs)..sort())[xs.length ~/ 2];
double _p95(List<double> xs) => (List.of(xs)..sort())[(xs.length * 0.95).floor().clamp(0, xs.length - 1)];

void main() {
  test('HybridSearchEngine latency at 10k and 20k images', () async {
    final dir = Directory.systemTemp.createTempSync('qa_perf_');
    final store = SqliteIndexStore(p.join(dir.path, 'perf.db'));
    await store.open();
    addTearDown(() async {
      await store.close();
      dir.deleteSync(recursive: true);
    });
    final rnd = Random(7);
    // Sparse, realistic-ish vocabulary: 4000 rare pseudo-words + common words.
    final rare = [
      for (var i = 0; i < 4000; i++)
        String.fromCharCodes([for (var j = 0; j < 4 + rnd.nextInt(6); j++) 97 + rnd.nextInt(26)]),
    ];
    String text() {
      final n = 5 + rnd.nextInt(60);
      return [
        for (var i = 0; i < n; i++) rnd.nextDouble() < 0.25 ? _common[rnd.nextInt(_common.length)] : rare[rnd.nextInt(rare.length)],
      ].join(' ');
    }

    List<IndexRecord> batch(int from, int to) => [
          for (var i = from; i < to; i++)
            record('img$i',
                ocr: i % 3 == 0 ? '' : text(),
                createdAt: DateTime(2020).add(Duration(hours: i * 2)),
                kind: i % 4 == 0 ? ImageKind.screenshot : ImageKind.photo,
                embedding: unitVector(rnd, 512),
                phash: rnd.nextInt(1 << 32) << 32 | rnd.nextInt(1 << 32),
                pipelineVersion: 11),
        ];

    final engine = HybridSearchEngine(
      store: store,
      parser: RuleBasedQueryParser(),
      model: _RandomTextModel(rnd),
      clock: () => DateTime(2026, 11, 23),
    );
    const queries = [
      'Find the screenshot of my conversation with Jamie',
      'Find the screenshot where someone sent me their bank details',
      'receipt total',
      'flight gate seat',
      'screenshots from last week',
      'Show me the picture of the red car',
      'wifi password',
      'address street berlin',
    ];

    final report = StringBuffer();
    Future<void> measure(int size) async {
      for (final q in queries) {
        await engine.search(q); // warm-up (vector index load, JIT)
      }
      final times = <double>[];
      for (var round = 0; round < 5; round++) {
        for (final q in queries) {
          final sw = Stopwatch()..start();
          await engine.search(q);
          times.add(sw.elapsedMicroseconds / 1000);
        }
      }
      report.writeln('$size images: median ${_median(times).toStringAsFixed(1)} ms, '
          'p95 ${_p95(times).toStringAsFixed(1)} ms, max ${times.reduce(max).toStringAsFixed(1)} ms');
      expect(_median(times), lessThan(1000));
    }

    for (var i = 0; i < 10000; i += 500) {
      await store.upsertAll(batch(i, i + 500));
    }
    await measure(10000);
    for (var i = 10000; i < 20000; i += 500) {
      await store.upsertAll(batch(i, i + 500));
    }
    await measure(20000);

    // Adversarial queries at 20k.
    Future<double> timeOf(String q) async {
      final sw = Stopwatch()..start();
      await engine.search(q);
      return sw.elapsedMicroseconds / 1000;
    }

    final long200 = List.generate(200, (i) => rare[i]).join(' ');
    final long1000 = List.generate(1000, (i) => rare[i % rare.length]).join(' ');
    final common60 = List.generate(60, (i) => _common[i % _common.length]).join(' ');
    report
      ..writeln('200 distinct rare words: ${(await timeOf(long200)).toStringAsFixed(0)} ms')
      ..writeln('1000-word query: ${(await timeOf(long1000)).toStringAsFixed(0)} ms')
      ..writeln('60 common words: ${(await timeOf(common60)).toStringAsFixed(0)} ms')
      ..writeln('emoji only: ${(await timeOf('🙂🎉🔥')).toStringAsFixed(1)} ms')
      ..writeln('RTL: ${(await timeOf('العنوان شارع')).toStringAsFixed(1)} ms')
      ..writeln('10k chars of punctuation: ${(await timeOf('!?.,;' * 2000)).toStringAsFixed(1)} ms');
    print(report);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
