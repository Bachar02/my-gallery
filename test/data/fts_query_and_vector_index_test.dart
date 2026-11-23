import 'dart:math';
import 'dart:typed_data';

import 'package:ai_gallery/data/db/fts_query.dart';
import 'package:ai_gallery/data/db/vector_index.dart';
import 'package:ai_gallery/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

int naivePopCount(int x) {
  var c = 0;
  for (var i = 0; i < 64; i++) {
    if ((x >>> i) & 1 == 1) c++;
  }
  return c;
}

void main() {
  group('buildFtsQuery', () {
    test('quotes every part; prefix terms, verbatim phrases, OR-joined', () {
      final q = buildFtsQuery(['invoice', 'e-mail'], ['total due']);
      expect(q.expression, '"invoice"* OR "e mail"* OR "total due"');
      expect([for (final p in q.parts) p.label], ['invoice', 'e-mail', 'total due']);
    });

    test('strips syntax, drops bare operators and empty parts, merges duplicates', () {
      final q = buildFtsQuery(['"', '*', 'NEAR(', 'OR', '-x', 'a:b', 'Cat', 'cat', '  '], ['', 'NOT this']);
      expect(q.expression, '"x"* OR "a b"* OR "Cat"* OR "NOT this"');
      expect(buildFtsQuery(['"""', '()'], ['^']).isEmpty, isTrue);
    });

    test('keeps non-Latin letters and digits', () {
      expect(buildFtsQuery(['café', 'ŻÓŁW', '2024'], []).expression, '"café"* OR "ŻÓŁW"* OR "2024"*');
    });
  });

  group('popCount64', () {
    test('matches a naive count for signed values', () {
      final rnd = Random(1);
      final samples = [0, -1, 1, 1 << 63, (1 << 63) - 1, -0x0123456789abcdef];
      for (var i = 0; i < 1000; i++) {
        samples.add((rnd.nextInt(1 << 32) << 32) | rnd.nextInt(1 << 32));
      }
      for (final x in samples) {
        expect(popCount64(x), naivePopCount(x), reason: '$x');
      }
      expect(hammingDistance64(-1, 0), 64);
      expect(hammingDistance64(1 << 63, 0), 1);
    });
  });

  group('VectorIndex', () {
    test('top-K equals sorted brute force (SIMD and scalar paths), swap-remove keeps ids', () {
      for (final dim in [16, 7]) {
        final rnd = Random(dim);
        final index = VectorIndex(dim, initialCapacity: 2);
        final vecs = <String, Float32List>{};
        for (var i = 0; i < 500; i++) {
          final v = unitVector(rnd, dim);
          vecs['$i'] = v;
          index.put('$i', v, createdAtMs: i, kind: ImageKind.photo);
        }
        for (var i = 0; i < 500; i += 3) {
          expect(index.remove('$i'), isTrue);
          vecs.remove('$i');
        }
        expect(index.remove('0'), isFalse);
        expect(index.length, vecs.length);
        final q = unitVector(rnd, dim);
        for (final k in [1, 10, 1000]) {
          final hits = index.search(q, limit: k);
          final expected = vecs.keys.toList()..sort((a, b) => dot(vecs[b]!, q).compareTo(dot(vecs[a]!, q)));
          expect([for (final h in hits) h.imageId], expected.take(k).toList(), reason: 'dim $dim k $k');
          for (final h in hits) {
            expect(h.similarity, closeTo(dot(vecs[h.imageId]!, q), 1e-5));
          }
        }
      }
    });

    test('putBlob decodes little-endian float32', () {
      final v = Float32List.fromList([0.5, -0.25, 1, 2]);
      final bd = ByteData(16);
      for (var i = 0; i < 4; i++) {
        bd.setFloat32(i * 4, v[i], Endian.little);
      }
      final index = VectorIndex(4)..putBlob('a', bd.buffer.asUint8List(), createdAtMs: 0, kind: ImageKind.photo);
      expect(index.search(Float32List.fromList([1, 0, 0, 0])).single.similarity, 0.5);
    });
  });
}
