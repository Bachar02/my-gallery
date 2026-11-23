import 'dart:collection';
import 'dart:typed_data';

/// In-memory LRU cache of encoded images, bounded by total bytes.
///
/// Concurrent requests for the same key share one in-flight load, so a grid
/// that asks for the same thumbnail several times hits the platform once.
class ByteLruCache<K> {
  ByteLruCache({required this.maxBytes, this.maxEntryBytes})
      : assert(maxBytes > 0, 'maxBytes must be positive');

  /// Upper bound on the sum of cached value lengths.
  final int maxBytes;

  /// Values larger than this are returned but not cached
  /// (defaults to a quarter of [maxBytes]).
  final int? maxEntryBytes;

  // LinkedHashMap keeps insertion order: first key = least recently used.
  final LinkedHashMap<K, Uint8List> _entries = LinkedHashMap<K, Uint8List>();
  final Map<K, Future<Uint8List?>> _inFlight = {};
  int _bytes = 0;

  int get bytes => _bytes;
  int get length => _entries.length;
  bool containsKey(K key) => _entries.containsKey(key);

  /// Returns the cached value (marking it most recently used) or null.
  Uint8List? get(K key) {
    final value = _entries.remove(key);
    if (value == null) return null;
    _entries[key] = value;
    return value;
  }

  void put(K key, Uint8List value) {
    final old = _entries.remove(key);
    if (old != null) _bytes -= old.lengthInBytes;
    final limit = maxEntryBytes ?? (maxBytes ~/ 4);
    if (value.lengthInBytes > limit) return;
    _entries[key] = value;
    _bytes += value.lengthInBytes;
    _evict();
  }

  /// Cached value, or the result of [loader] (cached when non-null).
  /// Errors from [loader] propagate and are not cached.
  Future<Uint8List?> getOrLoad(K key, Future<Uint8List?> Function() loader) {
    final hit = get(key);
    if (hit != null) return Future.value(hit);
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final future = () async {
      try {
        final value = await loader();
        if (value != null && value.isNotEmpty) put(key, value);
        return value;
      } finally {
        _inFlight.remove(key);
      }
    }();
    _inFlight[key] = future;
    return future;
  }

  void remove(K key) {
    final old = _entries.remove(key);
    if (old != null) _bytes -= old.lengthInBytes;
  }

  /// Removes every entry whose key matches [test].
  void removeWhere(bool Function(K key) test) {
    final keys = _entries.keys.where(test).toList();
    keys.forEach(remove);
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  void _evict() {
    while (_bytes > maxBytes && _entries.isNotEmpty) {
      final key = _entries.keys.first;
      remove(key);
    }
  }
}
