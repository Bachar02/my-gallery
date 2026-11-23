import 'dart:async';
import 'dart:typed_data';

import 'package:ai_gallery/features/gallery/data/byte_lru_cache.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(int n) => Uint8List(n);

void main() {
  test('evicts least recently used entries beyond the byte budget', () {
    final c = ByteLruCache<String>(maxBytes: 100, maxEntryBytes: 100);
    c.put('a', bytes(40));
    c.put('b', bytes(40));
    expect(c.get('a'), isNotNull); // a is now most recent
    c.put('c', bytes(40)); // 120 > 100 -> evict b
    expect(c.containsKey('b'), isFalse);
    expect(c.containsKey('a'), isTrue);
    expect(c.containsKey('c'), isTrue);
    expect(c.bytes, 80);
  });

  test('replacing a key updates the byte count', () {
    final c = ByteLruCache<String>(maxBytes: 100, maxEntryBytes: 100);
    c.put('a', bytes(30));
    c.put('a', bytes(50));
    expect(c.bytes, 50);
    expect(c.length, 1);
  });

  test('oversized entries are not cached', () {
    final c = ByteLruCache<String>(maxBytes: 100);
    c.put('big', bytes(26)); // default limit = 25
    expect(c.containsKey('big'), isFalse);
    expect(c.bytes, 0);
  });

  test('getOrLoad shares one in-flight load and caches the result', () async {
    final c = ByteLruCache<String>(maxBytes: 1000);
    var calls = 0;
    final gate = Completer<Uint8List?>();
    Future<Uint8List?> loader() {
      calls++;
      return gate.future;
    }

    final f1 = c.getOrLoad('k', loader);
    final f2 = c.getOrLoad('k', loader);
    gate.complete(bytes(10));
    expect(await f1, hasLength(10));
    expect(await f2, hasLength(10));
    expect(calls, 1);
    await c.getOrLoad('k', loader);
    expect(calls, 1);
  });

  test('null and failed loads are not cached', () async {
    final c = ByteLruCache<String>(maxBytes: 1000);
    expect(await c.getOrLoad('n', () async => null), isNull);
    expect(c.containsKey('n'), isFalse);
    await expectLater(c.getOrLoad('e', () async => throw StateError('x')), throwsStateError);
    expect(c.containsKey('e'), isFalse);
    // A later load for the same key runs again.
    expect(await c.getOrLoad('e', () async => bytes(3)), hasLength(3));
  });

  test('removeWhere and clear', () {
    final c = ByteLruCache<String>(maxBytes: 1000);
    c.put('1:a', bytes(10));
    c.put('1:b', bytes(10));
    c.put('2:a', bytes(10));
    c.removeWhere((k) => k.startsWith('1:'));
    expect(c.length, 1);
    expect(c.bytes, 10);
    c.clear();
    expect(c.length, 0);
    expect(c.bytes, 0);
  });
}
