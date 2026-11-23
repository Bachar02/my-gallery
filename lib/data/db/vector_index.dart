/// In-memory brute-force vector index (one per embedding model).
///
/// Vectors live in one contiguous [Float32List] (row-major, `dim` floats per
/// slot) with parallel arrays for the filter columns, so a query is a single
/// linear scan with SIMD dot products (vectors are L2-normalised, so the dot
/// product is the cosine similarity) and a bounded min-heap for top-K.
/// Deletion swaps the last slot into the hole, keeping the arrays dense.
library;

import 'dart:typed_data';

import '../../domain/models.dart';

/// Bit flags for [ImageKind] used in the parallel `kind` array.
int kindBit(ImageKind kind) => 1 << kind.index;

/// Bit mask for a set of kinds; 0 means "any kind".
int kindMask(Set<ImageKind> kinds) => kinds.fold(0, (m, k) => m | kindBit(k));

final bool _hostIsLittleEndian = Endian.host == Endian.little;

class VectorIndex {
  VectorIndex(this.dim, {int initialCapacity = 256})
      : _capacity = initialCapacity,
        _data = Float32List(initialCapacity * dim),
        _created = Int64List(initialCapacity),
        _kinds = Uint8List(initialCapacity);

  final int dim;
  int _capacity;
  int _count = 0;
  Float32List _data;
  Int64List _created;
  Uint8List _kinds;
  final List<String> _ids = [];
  final Map<String, int> _slots = {};

  int get length => _count;
  bool contains(String id) => _slots.containsKey(id);

  void _ensureCapacity(int needed) {
    if (needed <= _capacity) return;
    var cap = _capacity * 2;
    while (cap < needed) {
      cap *= 2;
    }
    _data = Float32List(cap * dim)..setRange(0, _count * dim, _data);
    _created = Int64List(cap)..setRange(0, _count, _created);
    _kinds = Uint8List(cap)..setRange(0, _count, _kinds);
    _capacity = cap;
  }

  int _slotFor(String id) {
    final existing = _slots[id];
    if (existing != null) return existing;
    _ensureCapacity(_count + 1);
    final slot = _count++;
    _ids.add(id);
    _slots[id] = slot;
    return slot;
  }

  /// Inserts or replaces the vector for [id].
  void put(String id, Float32List vector, {required int createdAtMs, required ImageKind kind}) {
    if (vector.length != dim) throw ArgumentError('vector has ${vector.length} dims, index has $dim');
    final slot = _slotFor(id);
    _data.setRange(slot * dim, slot * dim + dim, vector);
    _created[slot] = createdAtMs;
    _kinds[slot] = kindBit(kind);
  }

  /// Inserts or replaces from a stored little-endian float32 blob.
  void putBlob(String id, Uint8List blob, {required int createdAtMs, required ImageKind kind}) {
    if (blob.length != dim * 4) throw ArgumentError('blob has ${blob.length} bytes, expected ${dim * 4}');
    final slot = _slotFor(id);
    if (_hostIsLittleEndian) {
      // Byte copy: no alignment requirement on the source blob.
      _data.buffer.asUint8List(slot * dim * 4, dim * 4).setRange(0, dim * 4, blob);
    } else {
      final bd = ByteData.sublistView(blob);
      for (var i = 0; i < dim; i++) {
        _data[slot * dim + i] = bd.getFloat32(i * 4, Endian.little);
      }
    }
    _created[slot] = createdAtMs;
    _kinds[slot] = kindBit(kind);
  }

  /// Updates the filter columns of an existing entry (no-op if absent).
  void updateMeta(String id, {required int createdAtMs, required ImageKind kind}) {
    final slot = _slots[id];
    if (slot == null) return;
    _created[slot] = createdAtMs;
    _kinds[slot] = kindBit(kind);
  }

  bool remove(String id) {
    final slot = _slots.remove(id);
    if (slot == null) return false;
    final last = _count - 1;
    if (slot != last) {
      _data.setRange(slot * dim, slot * dim + dim, _data, last * dim);
      _created[slot] = _created[last];
      _kinds[slot] = _kinds[last];
      final movedId = _ids[last];
      _ids[slot] = movedId;
      _slots[movedId] = slot;
    }
    _ids.removeLast();
    _count = last;
    return true;
  }

  /// Top-[limit] entries by dot product with [query], best first.
  /// [startMs] inclusive / [endMs] exclusive filter on created time;
  /// [kindMask] 0 = any kind.
  List<VectorHit> search(Float32List query, {int? startMs, int? endMs, int kindMask = 0, int limit = 200}) {
    if (query.length != dim) throw ArgumentError('query has ${query.length} dims, index has $dim');
    if (limit <= 0 || _count == 0) return const [];
    final filtered = startMs != null || endMs != null || kindMask != 0;
    final lo = startMs ?? -0x7fffffffffffffff;
    final hi = endMs ?? 0x7fffffffffffffff;

    final heap = _TopK(limit);
    final n = _count;
    final created = _created;
    final kinds = _kinds;

    if (dim % 4 == 0) {
      // Fresh copy so the Float32x4 view is 16-byte aligned.
      final q4 = Float32x4List.view(Float32List.fromList(query).buffer);
      final d4 = Float32x4List.view(_data.buffer, 0, _capacity * dim ~/ 4);
      final n4 = dim ~/ 4;
      for (var i = 0; i < n; i++) {
        if (filtered) {
          final c = created[i];
          if (c < lo || c >= hi || (kindMask != 0 && (kinds[i] & kindMask) == 0)) continue;
        }
        var a0 = Float32x4.zero();
        var a1 = Float32x4.zero();
        final base = i * n4;
        var j = 0;
        for (; j + 1 < n4; j += 2) {
          a0 += d4[base + j] * q4[j];
          a1 += d4[base + j + 1] * q4[j + 1];
        }
        if (j < n4) a0 += d4[base + j] * q4[j];
        final s = a0 + a1;
        heap.offer(s.x + s.y + s.z + s.w, i);
      }
    } else {
      final data = _data;
      for (var i = 0; i < n; i++) {
        if (filtered) {
          final c = created[i];
          if (c < lo || c >= hi || (kindMask != 0 && (kinds[i] & kindMask) == 0)) continue;
        }
        var s = 0.0;
        final base = i * dim;
        for (var j = 0; j < dim; j++) {
          s += data[base + j] * query[j];
        }
        heap.offer(s, i);
      }
    }
    return [
      for (final (score, slot) in heap.drainSortedDescending()) VectorHit(imageId: _ids[slot], similarity: score),
    ];
  }
}

/// Fixed-size min-heap keeping the K largest scores: O(n log K), no full sort.
class _TopK {
  _TopK(this.k)
      : _scores = Float64List(k),
        _slots = Int32List(k);

  final int k;
  final Float64List _scores;
  final Int32List _slots;
  int _size = 0;

  void offer(double score, int slot) {
    if (_size < k) {
      var i = _size++;
      while (i > 0) {
        final parent = (i - 1) >> 1;
        if (_scores[parent] <= score) break;
        _scores[i] = _scores[parent];
        _slots[i] = _slots[parent];
        i = parent;
      }
      _scores[i] = score;
      _slots[i] = slot;
    } else if (score > _scores[0]) {
      _siftDown(score, slot);
    }
  }

  void _siftDown(double score, int slot) {
    var i = 0;
    while (true) {
      final l = 2 * i + 1;
      if (l >= _size) break;
      final r = l + 1;
      final c = (r < _size && _scores[r] < _scores[l]) ? r : l;
      if (_scores[c] >= score) break;
      _scores[i] = _scores[c];
      _slots[i] = _slots[c];
      i = c;
    }
    _scores[i] = score;
    _slots[i] = slot;
  }

  List<(double, int)> drainSortedDescending() {
    final out = [for (var i = 0; i < _size; i++) (_scores[i], _slots[i])];
    out.sort((a, b) => b.$1.compareTo(a.$1));
    return out;
  }
}

/// Number of set bits in a 64-bit Dart int (two's complement, so negative
/// values are handled: `>>>` is a logical shift and multiplication wraps).
int popCount64(int x) {
  x = x - ((x >>> 1) & 0x5555555555555555);
  x = (x & 0x3333333333333333) + ((x >>> 2) & 0x3333333333333333);
  x = (x + (x >>> 4)) & 0x0F0F0F0F0F0F0F0F;
  return (x * 0x0101010101010101) >>> 56;
}

/// Hamming distance between two 64-bit hashes.
int hammingDistance64(int a, int b) => popCount64(a ^ b);
