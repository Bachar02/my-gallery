// Search quality on the realistic evaluation corpus (tool/eval/): 572 CC BY
// photos with human-verified labels and 141 synthetic phone screenshots, with
// REAL features: ML Kit OCR lines and face counts extracted on a device
// (tool/eval/device_features.py) and real image embeddings
// (tool/eval/eval_models.py export). The app's actual SqliteIndexStore,
// ScreenAnalyzer, query analysis and search engine run on them, so the
// numbers are the app's, not a re-implementation's.
//
// Prints precision@k / recall per query class for the current engine and
// for version 1 of the engine (test/eval/legacy/) on the same data, and
// asserts regression floors, including the three phone regressions.
//
// Model: --dart-define=EVAL_MODEL=<id> (default: the bundled model). Text
// prompts are embedded offline: when a prompt is missing the test writes
// tool/eval/features/prompts_needed.json and fails; then run
//   tool/.venv/Scripts/python -I tool/eval/eval_models.py export <id> tool/eval/features tool/eval/features/prompts_needed.json
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ai_gallery/data/db/sqlite_index_store.dart';
import 'package:ai_gallery/domain/interfaces.dart';
import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/indexing/screen_analyzer.dart';
import 'package:ai_gallery/features/search/data/hybrid_search_engine.dart';
import 'package:ai_gallery/features/search/data/rule_based_query_parser.dart';
import 'package:ai_gallery/ml/siglip/siglip_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'legacy/legacy_hybrid_search_engine.dart';

const _evalDir = 'tool/eval';
const String _modelDefine = String.fromEnvironment('EVAL_MODEL');

// ------------------------------------------------------------- features

Float32List _f16(String b64) {
  final bytes = base64Decode(b64);
  final h = ByteData.sublistView(bytes);
  final out = Float32List(bytes.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = _halfToFloat(h.getUint16(i * 2, Endian.little));
  }
  return out;
}

double _halfToFloat(int h) {
  final s = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff;
  double v;
  if (e == 0) {
    v = m / 1024 * math.pow(2, -14);
  } else if (e == 31) {
    v = m == 0 ? double.infinity : double.nan;
  } else {
    v = (1 + m / 1024) * math.pow(2, e - 15);
  }
  return s == 1 ? -v : v;
}

class _Item {
  _Item(this.raw, this.record);
  final Map<String, dynamic> raw;
  final IndexRecord record;
  String get id => record.image.id;
  Set<String> get pos => {...(raw['positive'] as List? ?? const []).cast<String>()};
  Set<String> get tags => {...(raw['tags'] as List? ?? const []).cast<String>()};
}

class _PromptModel implements SemanticModel {
  _PromptModel(this.modelId, this.vectors, this.dimension);
  @override
  final String modelId;
  final Map<String, Float32List> vectors;
  @override
  final int dimension;
  final Set<String> missing = {};
  @override
  bool get isLoaded => true;
  @override
  Future<bool> load() async => true;
  @override
  Future<Float32List> embedImage(Uint8List encodedImage) => throw UnimplementedError();
  @override
  Future<Float32List> embedText(String text) async {
    final v = vectors[text];
    if (v != null) return v;
    missing.add(text);
    return Float32List(dimension); // zero vector: similarity 0
  }

  @override
  Future<void> dispose() async {}
}

// --------------------------------------------------------------- judging

bool _clause(_Item it, String clause) {
  for (final part in clause.split('&')) {
    final i = part.indexOf(':');
    final kind = part.substring(0, i), value = part.substring(i + 1);
    final ok = switch (kind) {
      'label' => it.pos.contains(value),
      'tag' => it.tags.contains(value),
      'kind' => it.record.image.kind.name == value,
      'date' => () {
          final r = value.split('..');
          final d = it.record.image.createdAt.toIso8601String().substring(0, 10);
          return d.compareTo(r[0]) >= 0 && d.compareTo(r[1]) < 0;
        }(),
      _ => throw ArgumentError(clause),
    };
    if (!ok) return false;
  }
  return true;
}

/// 1 relevant, 0 not, null unjudged.
int? _judge(_Item it, Map<String, dynamic> q, {String key = 'relevant'}) {
  if ((q[key] as List? ?? const []).cast<String>().any((c) => _clause(it, c))) return 1;
  if ((q['unjudged'] as List? ?? const []).cast<String>().any((c) => _clause(it, c))) return null;
  return 0;
}

class _ClassStats {
  int n = 0;
  double p5 = 0, p10 = 0, pAll = 0, recall = 0;
  int returned = 0;
  int negatives = 0, negativesEmpty = 0;
}

class _QueryOutcome {
  _QueryOutcome(this.q, this.ids, this.mentionIds, this.p5, this.pAll, this.recall, this.mentionsPrecision);
  final Map<String, dynamic> q;
  final List<String> ids;
  final List<String> mentionIds;
  final double p5, pAll, recall;
  final double? mentionsPrecision;
}

Future<List<_QueryOutcome>> _evaluate(SearchEngine engine, List<Map<String, dynamic>> queries, Map<String, _Item> items) async {
  final out = <_QueryOutcome>[];
  for (final q in queries) {
    final res = await engine.search(q['query'] as String);
    final primary = [for (final r in res.results) if (r.group == ResultGroup.primary) r.image.id];
    final mentions = [for (final r in res.results) if (r.group == ResultGroup.mentions) r.image.id];
    if (q['empty'] == true) {
      out.add(_QueryOutcome(q, primary, mentions, primary.isEmpty ? 1 : 0, primary.isEmpty ? 1 : 0, 1, null));
      continue;
    }
    final judged = [
      for (final id in primary)
        ?_judge(items[id]!, q),
    ];
    double precisionAt(int k) {
      final top = judged.take(k).toList();
      if (top.isEmpty) return 0;
      return top.where((j) => j == 1).length / top.length;
    }

    final relevant = items.values.where((it) => _judge(it, q) == 1).length;
    final found = primary.where((id) => _judge(items[id]!, q) == 1).length;
    double? mp;
    if (q.containsKey('mentions') && mentions.isNotEmpty) {
      final ok = mentions
          .where((id) => _judge(items[id]!, q, key: 'mentions') == 1 || _judge(items[id]!, q) == 1)
          .length;
      mp = ok / mentions.length;
    }
    out.add(_QueryOutcome(q, primary, mentions, precisionAt(5), precisionAt(1 << 20),
        relevant == 0 ? 1 : found / relevant, mp));
  }
  return out;
}

Map<String, _ClassStats> _aggregate(List<_QueryOutcome> outcomes) {
  final by = <String, _ClassStats>{};
  for (final o in outcomes) {
    final c = by.putIfAbsent(o.q['class'] as String, _ClassStats.new);
    if (o.q['empty'] == true) {
      c.negatives++;
      if (o.ids.isEmpty) c.negativesEmpty++;
      continue;
    }
    c.n++;
    c.p5 += o.p5;
    c.pAll += o.pAll;
    c.recall += o.recall;
    c.returned += o.ids.length;
  }
  return by;
}

String _table(Map<String, _ClassStats> before, Map<String, _ClassStats> after) {
  final b = StringBuffer()
    ..writeln('| class | queries | P@5 before → after | precision (all returned) before → after | recall before → after |')
    ..writeln('|---|---|---|---|---|');
  String f(double v) => v.toStringAsFixed(2);
  for (final k in after.keys) {
    final a = after[k]!, o = before[k]!;
    if (k == 'negative') {
      b.writeln('| negative (must be empty) | ${a.negatives} | ${o.negativesEmpty}/${o.negatives} → '
          '${a.negativesEmpty}/${a.negatives} | | |');
      continue;
    }
    b.writeln('| $k | ${a.n} | ${f(o.p5 / o.n)} → ${f(a.p5 / a.n)} | ${f(o.pAll / o.n)} → ${f(a.pAll / a.n)} | '
        '${f(o.recall / o.n)} → ${f(a.recall / a.n)} |');
  }
  return b.toString();
}

// ------------------------------------------------------------------ main

/// One embedding space: its in-memory index and a text model answering with
/// the offline prompt embeddings.
class _Space {
  _Space(this.modelId, this.store, this.model);
  final String modelId;
  final SqliteIndexStore store;
  final _PromptModel model;
}

bool _haveFeatures(String modelId) =>
    File('$_evalDir/features/device_features.json').existsSync() &&
    File('$_evalDir/features/${modelId}_images.json').existsSync();

void main() {
  final modelId = _modelDefine.isNotEmpty ? _modelDefine : SiglipModel.kModelId;
  // "Before" = version 1 of the engine with the model version 1 shipped.
  const legacyModelId = 'mobileclip_s0';
  final available = _haveFeatures(modelId) && _haveFeatures(legacyModelId);

  late _Space space, legacySpace;
  late Map<String, _Item> items;
  late List<Map<String, dynamic>> queries;
  late DateTime now;

  Future<_Space> buildSpace(String id, Map<String, dynamic> device) async {
    final imgVec = jsonDecode(File('$_evalDir/features/${id}_images.json').readAsStringSync()) as Map<String, dynamic>;
    final promptsFile = File('$_evalDir/features/${id}_prompts.json');
    final promptVec = promptsFile.existsSync()
        ? (jsonDecode(promptsFile.readAsStringSync()) as Map<String, dynamic>)['vectors'] as Map<String, dynamic>
        : <String, dynamic>{};
    final model = _PromptModel(id, {for (final e in promptVec.entries) e.key: _f16(e.value as String)}, imgVec['dim'] as int);
    final vectors = imgVec['vectors'] as Map<String, dynamic>;
    final store = SqliteIndexStore.inMemory();
    await store.open();
    await store.upsertAll([
      for (final it in items.values)
        if (vectors[it.id] case final String v)
          IndexRecord(
            image: it.record.image,
            ocrText: it.record.ocrText,
            ocrLines: it.record.ocrLines,
            screen: it.record.screen,
            faceCount: it.record.faceCount,
            embedding: _f16(v),
            embeddingModel: id,
            perceptualHash: it.record.perceptualHash,
            indexedAt: now,
            pipelineVersion: 21,
          ),
    ]);
    return _Space(id, store, model);
  }

  setUpAll(() async {
    if (!available) return;
    final device = jsonDecode(File('$_evalDir/features/device_features.json').readAsStringSync()) as Map<String, dynamic>;
    final qdoc = jsonDecode(File('$_evalDir/queries.json').readAsStringSync()) as Map<String, dynamic>;
    queries = (qdoc['queries'] as List).cast<Map<String, dynamic>>();
    now = DateTime.parse(qdoc['now'] as String);

    const analyzer = ScreenAnalyzer();
    items = {};
    var n = 0;
    for (final manifest in ['photos_manifest.json', 'screens_manifest.json']) {
      for (final raw in (jsonDecode(File('$_evalDir/$manifest').readAsStringSync()) as List).cast<Map<String, dynamic>>()) {
        final id = raw['id'] as String;
        final f = device[id] as Map<String, dynamic>?;
        if (f == null) continue;
        final kind = raw['kind'] == 'screenshot' ? ImageKind.screenshot : ImageKind.photo;
        final date = DateTime.parse(raw['date'] as String);
        final lines = [
          for (final l in (f['lines'] as List).cast<List<dynamic>>())
            OcrLine(l[0] as String, (l[1] as num).toDouble(), (l[2] as num).toDouble(), (l[3] as num).toDouble(),
                (l[4] as num).toDouble(),
                block: l[5] as int),
        ];
        final image = GalleryImage(
          id: id,
          filename: raw['filename'] as String? ?? 'IMG_${date.year}${date.month.toString().padLeft(2, '0')}_$n.jpg',
          relativePath: kind == ImageKind.screenshot ? 'Pictures/Screenshots/' : 'DCIM/Camera/',
          width: (raw['width'] as int?) ?? 1080,
          height: (raw['height'] as int?) ?? 2400,
          createdAt: date,
          modifiedAt: date,
          kind: kind,
        );
        items[id] = _Item(
          raw,
          IndexRecord(
            image: image,
            ocrText: lines.map((l) => l.text).join('\n'),
            ocrLines: lines,
            screen: analyzer.analyze(image, lines),
            faceCount: kind == ImageKind.photo ? f['faces'] as int? : null,
            // Distinct hashes: corpus images are all different pictures.
            perceptualHash: (n + 1) * 0x9E3779B97F4A7C15 & 0x7fffffffffffffff,
            indexedAt: now,
            pipelineVersion: 21,
          ),
        );
        n++;
      }
    }
    space = await buildSpace(modelId, device);
    legacySpace = await buildSpace(legacyModelId, device);
  });

  tearDownAll(() async {
    if (!available) return;
    await space.store.close();
    await legacySpace.store.close();
  });

  test('screen analyzer on real ML Kit layouts', () {
    if (!available) return markTestSkipped('evaluation features not generated');
    final screens = [for (final it in items.values) if (it.raw['kind'] == 'screenshot') it];
    var typeOk = 0, chats = 0, titleOk = 0;
    final wrong = <String>[];
    for (final it in screens) {
      final expected = it.raw['screen_type'] as String;
      final got = it.record.screen.type.name;
      final equivalent = got == expected || (expected == 'notes' || expected == 'other') && got == 'other';
      if (equivalent) {
        typeOk++;
      } else {
        wrong.add('${it.id}: expected $expected, got $got');
      }
      if (expected == 'chat') {
        chats++;
        String norm(String t) => t.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}+ ]', unicode: true), '').trim();
        final want = norm(it.raw['chat_title'] as String);
        final title = norm(it.record.screen.chatTitle ?? '');
        if (title.isNotEmpty && (title.contains(want) || want.contains(title) && title.length > 2)) {
          titleOk++;
        } else {
          wrong.add('${it.id}: title "$want" -> "$title"');
        }
      }
    }
    print('Screen type accuracy: $typeOk/${screens.length}; chat titles: $titleOk/$chats');
    print('  ${wrong.join('\n  ')}');
    // Measured 138/141 types, 54/54 titles (docs/QA_REPORT.md).
    expect(typeOk / screens.length, greaterThanOrEqualTo(0.95));
    expect(titleOk / chats, greaterThanOrEqualTo(0.98));
  });

  test('search quality per query class, before and after', () async {
    if (!available) return markTestSkipped('evaluation features not generated');
    final engine =
        HybridSearchEngine(store: space.store, parser: RuleBasedQueryParser(), model: space.model, clock: () => now);
    final legacy = LegacyHybridSearchEngine(
        store: legacySpace.store, parser: RuleBasedQueryParser(), model: legacySpace.model, clock: () => now);
    final after = await _evaluate(engine, queries, items);
    final before = await _evaluate(legacy, queries, items);
    final missing = <String>[];
    for (final sp in [space, legacySpace]) {
      if (sp.model.missing.isEmpty) continue;
      final f = File('$_evalDir/features/${sp.modelId}_prompts_needed.json');
      f.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(({...sp.model.vectors.keys, ...sp.model.missing}.toList())..sort()));
      missing.add('tool/.venv/Scripts/python -I tool/eval/eval_models.py export '
          '${sp.modelId == SiglipModel.kModelId ? '${sp.modelId}_int8' : sp.modelId} tool/eval/features ${f.path}');
    }
    if (missing.isNotEmpty) fail('prompts have no embedding; run:\n${missing.join('\n')}');
    print('Before: version 1 engine + $legacyModelId. After: this engine + $modelId. '
        '${items.length} images, ${queries.length} queries\n');
    print(_table(_aggregate(before), _aggregate(after)));
    final b = StringBuffer('| query | class | P@5 | precision | recall | returned | mentions P | top results |\n|---|---|---|---|---|---|---|---|\n');
    for (final (i, o) in after.indexed) {
      final old = before[i];
      String f(double v) => v.toStringAsFixed(2);
      b.writeln('| ${o.q['query']} | ${o.q['class']} | ${f(old.p5)} → ${f(o.p5)} | ${f(old.pAll)} → ${f(o.pAll)} | '
          '${f(old.recall)} → ${f(o.recall)} | ${old.ids.length} → ${o.ids.length} | '
          '${o.mentionsPrecision?.toStringAsFixed(2) ?? '-'} (${o.mentionIds.length}) | ${o.ids.take(4).join(', ')} |');
    }
    print(b);

    // The three regressions from the phone: no wrong result in the top 5.
    for (final o in after.where((o) => o.q['regression'] == true)) {
      expect(o.p5, greaterThanOrEqualTo(0.8), reason: '${o.q['query']}: ${o.ids.take(5)}');
      expect(o.ids, isNotEmpty, reason: o.q['query'] as String);
    }
    final agg = _aggregate(after);
    expect(agg['negative']!.negativesEmpty, agg['negative']!.negatives);
    for (final e in _floors.entries) {
      final c = agg[e.key]!;
      expect(c.p5 / c.n, greaterThanOrEqualTo(e.value.$1), reason: '${e.key} P@5');
      expect(c.recall / c.n, greaterThanOrEqualTo(e.value.$2), reason: '${e.key} recall');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// class -> (min mean P@5, min mean recall); set slightly below the run
/// recorded in docs/QA_REPORT.md (P@5 / recall: visual 0.89 / 0.60,
/// conversation 1.00 / 1.00, text 0.72 / 1.00, hybrid 0.92 / 0.65).
const Map<String, (double, double)> _floors = {
  'visual': (0.85, 0.55),
  'conversation': (0.95, 0.95),
  'text': (0.70, 0.95),
  'hybrid': (0.85, 0.60),
};
