/// SQLite implementation of [IndexStore]: the app's local, rebuildable index
/// of OCR text, metadata, embeddings and perceptual hashes.
///
/// See docs/DATABASE.md for the schema, FTS and vector-search design and the
/// measured performance figures.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../domain/interfaces.dart';
import '../../domain/models.dart';
import 'fts_query.dart';
import 'schema.dart';
import 'vector_loader.dart';
import 'vector_index.dart';

class SqliteIndexStore implements IndexStore {
  /// Store backed by the file at [databasePath] (created if missing).
  SqliteIndexStore(String databasePath) : _path = databasePath;

  /// Private in-memory database; used by tests.
  SqliteIndexStore.inMemory() : _path = null;

  /// Sub-directory of the app-support dir holding the database, its WAL/SHM
  /// side files. Exclude this directory from Android backup.
  static const String directoryName = 'index';
  static const String fileName = 'ai_gallery_index.db';

  /// bm25 column weights: (ocr_text, filename).
  static const double _ocrWeight = 4.0;
  static const double _filenameWeight = 1.0;

  static const int _maxRecentSearches = 50;

  /// SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE.
  static const int _sqliteDbConfigNoCkptOnClose = 1006;

  /// Page size for newly created database files.
  static const int pageSize = 16384;

  /// Below this many vectors the in-memory index is loaded synchronously;
  /// above it the load runs in a background isolate.
  static const int _isolateLoadThreshold = 2000;

  /// Opens (creating if needed) the store in app-private storage:
  /// `<getApplicationSupportDirectory()>/index/ai_gallery_index.db`.
  static Future<SqliteIndexStore> openDefault() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, directoryName));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final store = SqliteIndexStore(p.join(dir.path, fileName));
    await store.open();
    return store;
  }

  final String? _path;
  Database? _db;
  bool _closed = false;

  /// Loaded per-model vector indices (absent = not loaded yet).
  final Map<String, VectorIndex> _vectors = {};

  /// In-flight background loads and the writes made while they run.
  final Map<String, Future<VectorIndex>> _loading = {};
  final Map<String, List<bool Function(VectorIndex)>> _journals = {};

  /// Bumped whenever cached indices become invalid (clear, recovery, close).
  int _generation = 0;

  /// Lazily loaded id -> dHash map for near-duplicate queries.
  Map<String, int>? _hashes;

  /// One-line description of [e] that is safe to log: `SqliteException`'s
  /// `toString()` appends the failing SQL statement *and its bound
  /// parameters* (OCR text, file names, search queries), so only the first
  /// line (result code and SQLite message) is kept.
  @visibleForTesting
  static String describeError(Object e) {
    final first = e.toString().split('\n').first.trim();
    return first.length > 200 ? '${first.substring(0, 200)}…' : first;
  }

  /// Path of the database file, or null for in-memory stores.
  String? get path => _path;

  // ------------------------------------------------------------ lifecycle

  @override
  Future<void> open() async {
    if (_closed) throw StateError('IndexStore has been closed');
    if (_db != null) return;
    _db = _openOrRecreate();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final db = _db;
    _db = null;
    _resetCaches();
    db?.close();
  }

  Database _openOrRecreate() {
    try {
      return _openAndMigrate();
    } on Object catch (e) {
      // The index is a cache derived from the gallery: an unreadable file is
      // discarded and rebuilt by the indexing service on its next run. The
      // old file is deleted rather than kept as a backup because it holds
      // the recognised text of private screenshots.
      debugPrint('IndexStore: cannot open database (${describeError(e)}); recreating an empty index');
      _deleteDatabaseFiles();
      return _openAndMigrate();
    }
  }

  Database _openAndMigrate() {
    final path = _path;
    final db = path == null ? sqlite3.openInMemory() : sqlite3.open(path);
    try {
      // Touch the file first: a non-database file fails here (SQLITE_NOTADB).
      db.select('SELECT count(*) FROM sqlite_schema');
      // Only takes effect on a new, empty file. 16 KiB pages hold seven
      // 2 KiB embedding rows instead of one per 4 KiB page (measured: file
      // 89 -> 56 MiB for 20k images, faster bulk loads).
      db.execute('PRAGMA page_size = $pageSize');
      db.execute('PRAGMA foreign_keys = ON');
      db.execute('PRAGMA secure_delete = ON');
      if (path != null) {
        db.execute('PRAGMA journal_mode = WAL');
        db.execute('PRAGMA synchronous = NORMAL');
      }
      db.execute('PRAGMA busy_timeout = 2000');
      migrate(db);
      // Cheap structural check: every table we rely on is readable.
      for (final t in const ['images', 'embeddings', 'recent_searches', 'settings', 'images_fts']) {
        db.select('SELECT 1 FROM $t LIMIT 1');
      }
      return db;
    } catch (_) {
      try {
        db.close();
      } catch (_) {}
      rethrow;
    }
  }

  void _deleteDatabaseFiles() {
    final path = _path;
    if (path == null) return;
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      try {
        final f = File('$path$suffix');
        if (f.existsSync()) f.deleteSync();
      } on FileSystemException catch (e) {
        debugPrint('IndexStore: could not delete $path$suffix ($e)');
      }
    }
  }

  void _resetCaches() {
    _generation++;
    _vectors.clear();
    _loading.clear();
    _journals.clear();
    _hashes = null;
  }

  Database _requireDb() {
    if (_closed) throw StateError('IndexStore has been closed');
    final db = _db;
    if (db == null) throw StateError('IndexStore.open() has not been called');
    return db;
  }

  /// Runs [body] against the open database. If SQLite reports corruption the
  /// database is recreated empty (so the next indexing run rebuilds it) and
  /// the error is rethrown for this one call.
  T _run<T>(T Function(Database db) body) {
    final db = _requireDb();
    try {
      return body(db);
    } on SqliteException catch (e) {
      if (e.resultCode == SqlError.SQLITE_CORRUPT || e.resultCode == SqlError.SQLITE_NOTADB) {
        debugPrint('IndexStore: database corruption detected (${describeError(e)}); recreating an empty index');
        _resetCaches();
        try {
          db.close();
        } catch (_) {}
        _db = null;
        _deleteDatabaseFiles();
        _db = _openOrRecreate();
      }
      rethrow;
    }
  }

  static void _transaction(Database db, void Function() body) {
    db.execute('BEGIN IMMEDIATE');
    try {
      body();
      db.execute('COMMIT');
    } catch (_) {
      try {
        db.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
  }

  // ---------------------------------------------------------------- writes

  static const String _upsertImageSql = '''
    INSERT INTO images (id, filename, relative_path, mime_type, width, height,
                        created_at_ms, modified_at_ms, kind, ocr_text, phash,
                        indexed_at_ms, pipeline_version)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT (id) DO UPDATE SET
      filename = excluded.filename,
      relative_path = excluded.relative_path,
      mime_type = excluded.mime_type,
      width = excluded.width,
      height = excluded.height,
      created_at_ms = excluded.created_at_ms,
      modified_at_ms = excluded.modified_at_ms,
      kind = excluded.kind,
      ocr_text = excluded.ocr_text,
      phash = excluded.phash,
      indexed_at_ms = excluded.indexed_at_ms,
      pipeline_version = excluded.pipeline_version''';

  static const String _upsertEmbeddingSql = '''
    INSERT INTO embeddings (image_id, model_id, dim, vector) VALUES (?, ?, ?, ?)
    ON CONFLICT (image_id) DO UPDATE SET
      model_id = excluded.model_id, dim = excluded.dim, vector = excluded.vector''';

  @override
  Future<void> upsert(IndexRecord record) => upsertAll([record]);

  @override
  Future<void> upsertAll(List<IndexRecord> records) async {
    if (records.isEmpty) {
      _requireDb();
      return;
    }
    _run((db) {
      final upImage = db.prepare(_upsertImageSql);
      final upEmb = db.prepare(_upsertEmbeddingSql);
      final delEmb = db.prepare('DELETE FROM embeddings WHERE image_id = ?');
      try {
        _transaction(db, () {
          for (final r in records) {
            final img = r.image;
            upImage.execute([
              img.id,
              img.filename,
              img.relativePath,
              img.mimeType,
              img.width,
              img.height,
              img.createdAt.millisecondsSinceEpoch,
              img.modifiedAt.millisecondsSinceEpoch,
              img.kind.name,
              r.ocrText,
              r.perceptualHash,
              r.indexedAt.millisecondsSinceEpoch,
              r.pipelineVersion,
            ]);
            final emb = _storableEmbedding(r);
            if (emb == null) {
              delEmb.execute([img.id]);
            } else {
              upEmb.execute([img.id, r.embeddingModel, emb.length, _encodeVector(emb)]);
            }
          }
        });
      } finally {
        upImage.close();
        upEmb.close();
        delEmb.close();
      }
    });
    // Only after a successful commit: mirror the change into memory.
    for (final r in records) {
      _syncCachesAfterUpsert(r);
    }
  }

  static Float32List? _storableEmbedding(IndexRecord r) {
    final emb = r.embedding;
    if (emb == null || emb.isEmpty) return null;
    final model = r.embeddingModel;
    if (model == null || model.isEmpty) {
      debugPrint('IndexStore: an embedding has no model id; not stored');
      return null;
    }
    return emb;
  }

  void _syncCachesAfterUpsert(IndexRecord r) {
    final id = r.image.id;
    final hashes = _hashes;
    if (hashes != null) {
      final h = r.perceptualHash;
      if (h == null) {
        hashes.remove(id);
      } else {
        hashes[id] = h;
      }
    }
    for (final entry in _vectors.entries.toList()) {
      if (!_applyUpsert(entry.key, entry.value, r)) {
        debugPrint('IndexStore: ${entry.key} vector dimension changed; reloading its index');
        _vectors.remove(entry.key);
      }
    }
    for (final MapEntry(key: model, value: journal) in _journals.entries) {
      journal.add((index) => _applyUpsert(model, index, r));
    }
  }

  /// Mirrors one upserted record into the index of [model]. Returns false
  /// when the vector cannot be applied (dimension mismatch).
  static bool _applyUpsert(String model, VectorIndex index, IndexRecord r) {
    final emb = _storableEmbedding(r);
    if (emb == null || r.embeddingModel != model) {
      index.remove(r.image.id);
      return true;
    }
    if (emb.length != index.dim) return false;
    index.put(r.image.id, emb, createdAtMs: r.image.createdAt.millisecondsSinceEpoch, kind: r.image.kind);
    return true;
  }

  static Uint8List _encodeVector(Float32List v) {
    if (Endian.host == Endian.little) {
      return Uint8List.fromList(v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes));
    }
    final bd = ByteData(v.length * 4);
    for (var i = 0; i < v.length; i++) {
      bd.setFloat32(i * 4, v[i], Endian.little);
    }
    return bd.buffer.asUint8List();
  }

  static Float32List _decodeVector(Uint8List blob, int dim) {
    final out = Float32List(dim);
    if (Endian.host == Endian.little) {
      out.buffer.asUint8List().setRange(0, dim * 4, blob);
    } else {
      final bd = ByteData.sublistView(blob);
      for (var i = 0; i < dim; i++) {
        out[i] = bd.getFloat32(i * 4, Endian.little);
      }
    }
    return out;
  }

  @override
  Future<void> delete(Iterable<String> imageIds) async {
    final ids = imageIds.toSet().toList();
    if (ids.isEmpty) {
      _requireDb();
      return;
    }
    _run((db) {
      _transaction(db, () {
        // Embeddings go via ON DELETE CASCADE, FTS rows via trigger.
        db.execute('DELETE FROM images WHERE id IN (SELECT value FROM json_each(?))', [jsonEncode(ids)]);
      });
      _truncateWal(db);
    });
    for (final id in ids) {
      _hashes?.remove(id);
      for (final index in _vectors.values) {
        index.remove(id);
      }
    }
    for (final journal in _journals.values) {
      journal.add((index) {
        ids.forEach(index.remove);
        return true;
      });
    }
  }

  @override
  Future<void> clearAll() async {
    final db = _requireDb();
    final path = _path;
    _resetCaches();
    if (path != null) {
      // Fastest and most thorough wipe for a file: delete it and start a new
      // one, carrying the settings over. Nothing of the old pages survives in
      // the new file or WAL (an in-place DELETE + VACUUM measured ~20 s for
      // 20k images because secure_delete zeroes every freed page).
      final settings = _run((db) => [
            for (final r in db.select('SELECT key, value FROM settings')) [r.columnAt(0), r.columnAt(1)],
          ]);
      // Skip the WAL checkpoint on close: the file is deleted right after.
      try {
        db.config.setIntConfig(_sqliteDbConfigNoCkptOnClose, 1);
      } catch (_) {}
      db.close();
      _db = null;
      _deleteDatabaseFiles();
      final deleted = !File(path).existsSync();
      _db = _openOrRecreate();
      if (deleted) {
        _run((db) => _transaction(db, () {
              final stmt = db.prepare('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)');
              try {
                settings.forEach(stmt.execute);
              } finally {
                stmt.close();
              }
            }));
        return;
      }
      debugPrint('IndexStore: could not delete the database file; clearing in place');
    }
    _run((db) {
      _transaction(db, () {
        db.execute('DELETE FROM embeddings');
        db.execute('DELETE FROM images'); // FTS rows removed by trigger
        db.execute("INSERT INTO images_fts (images_fts) VALUES ('delete-all')");
        db.execute('DELETE FROM recent_searches');
      });
      // Shrink the file (freed pages were zeroed by secure_delete), then
      // truncate the WAL so no copy of old pages survives in the side file.
      db.execute('VACUUM');
      if (path != null) db.select('PRAGMA wal_checkpoint(TRUNCATE)');
    });
  }

  // ----------------------------------------------------------------- reads

  static const String _imageColumns =
      'i.id, i.filename, i.relative_path, i.mime_type, i.width, i.height, '
      'i.created_at_ms, i.modified_at_ms, i.kind';

  static GalleryImage _imageFromRow(Row r) => GalleryImage(
        id: r.columnAt(0) as String,
        filename: r.columnAt(1) as String?,
        relativePath: r.columnAt(2) as String?,
        mimeType: r.columnAt(3) as String?,
        width: r.columnAt(4) as int,
        height: r.columnAt(5) as int,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r.columnAt(6) as int),
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(r.columnAt(7) as int),
        kind: ImageKind.values.byName(r.columnAt(8) as String),
      );

  @override
  Future<Map<String, ({int modifiedAtMs, int pipelineVersion})>> indexedVersions() async {
    return _run((db) {
      final out = <String, ({int modifiedAtMs, int pipelineVersion})>{};
      for (final r in db.select('SELECT id, modified_at_ms, pipeline_version FROM images')) {
        out[r.columnAt(0) as String] = (modifiedAtMs: r.columnAt(1) as int, pipelineVersion: r.columnAt(2) as int);
      }
      return out;
    });
  }

  @override
  Future<IndexRecord?> get(String imageId) async {
    return _run((db) {
      final rows = db.select('''
        SELECT $_imageColumns, i.ocr_text, i.phash, i.indexed_at_ms, i.pipeline_version,
               e.model_id, e.dim, e.vector
        FROM images i LEFT JOIN embeddings e ON e.image_id = i.id
        WHERE i.id = ?''', [imageId]);
      if (rows.isEmpty) return null;
      final r = rows.first;
      final dim = r.columnAt(14) as int?;
      final blob = r.columnAt(15) as Uint8List?;
      return IndexRecord(
        image: _imageFromRow(r),
        ocrText: r.columnAt(9) as String,
        perceptualHash: r.columnAt(10) as int?,
        indexedAt: DateTime.fromMillisecondsSinceEpoch(r.columnAt(11) as int),
        pipelineVersion: r.columnAt(12) as int,
        embeddingModel: r.columnAt(13) as String?,
        embedding: (blob == null || dim == null) ? null : _decodeVector(blob, dim),
      );
    });
  }

  @override
  Future<List<GalleryImage>> getImages(List<String> imageIds) async {
    if (imageIds.isEmpty) {
      _requireDb();
      return const [];
    }
    return _run((db) {
      final byId = <String, GalleryImage>{};
      final rows = db.select(
        'SELECT $_imageColumns FROM images i WHERE i.id IN (SELECT value FROM json_each(?))',
        [jsonEncode(imageIds.toSet().toList())],
      );
      for (final r in rows) {
        final img = _imageFromRow(r);
        byId[img.id] = img;
      }
      // Requested order; unknown ids are skipped.
      return [
        for (final id in imageIds) ?byId[id],
      ];
    });
  }

  /// SQL fragment (prefixed with ' AND ' per clause) + parameters for
  /// [filters], applied to table alias `i`.
  static (String, List<Object?>) _filterSql(SearchFilters filters) {
    final sql = StringBuffer();
    final params = <Object?>[];
    final range = filters.dateRange;
    if (range != null) {
      sql.write(' AND i.created_at_ms >= ? AND i.created_at_ms < ?');
      params
        ..add(range.start.millisecondsSinceEpoch)
        ..add(range.end.millisecondsSinceEpoch);
    }
    if (filters.kinds.isNotEmpty) {
      final kinds = filters.kinds.toList();
      sql.write(' AND i.kind IN (${List.filled(kinds.length, '?').join(', ')})');
      params.addAll(kinds.map((k) => k.name));
    }
    return (sql.toString(), params);
  }

  @override
  Future<List<TextHit>> searchText({
    required List<String> terms,
    List<String> phrases = const [],
    SearchFilters filters = SearchFilters.none,
    int limit = 200,
  }) async {
    final query = buildFtsQuery(terms, phrases);
    if (query.isEmpty || limit <= 0) {
      _requireDb();
      return const [];
    }
    return _run((db) {
      final (filterSql, filterParams) = _filterSql(filters);
      const bm25 = 'bm25(images_fts, $_ocrWeight, $_filenameWeight)';
      final rows = db.select('''
        SELECT i.id, images_fts.rowid, -$bm25 AS score,
               snippet(images_fts, -1, '', '', '…', 20) AS snip,
               i.ocr_text
        FROM images_fts JOIN images i ON i.doc_id = images_fts.rowid
        WHERE images_fts MATCH ?$filterSql
        ORDER BY $bm25
        LIMIT ?''', [query.expression, ...filterParams, limit]);
      if (rows.isEmpty) return const <TextHit>[];

      // Which requested parts occur in each hit: evaluate each part with the
      // same FTS5 tokenizer (case/diacritic folding identical to the main
      // query), restricted to the hit rows.
      final partsByRow = <int, List<String>>{};
      if (query.parts.length == 1) {
        final label = query.parts.single.label;
        for (final r in rows) {
          partsByRow[r.columnAt(1) as int] = [label];
        }
      } else {
        // One doclist read per part (a few ms even for very common
        // prefixes), intersected with the hit rows in Dart. Measured much
        // faster than constraining FTS5 with `rowid IN (...)`.
        final hitRows = {for (final r in rows) r.columnAt(1) as int};
        final stmt = db.prepare('SELECT rowid FROM images_fts WHERE images_fts MATCH ?');
        try {
          for (final part in query.parts) {
            final cursor = stmt.selectCursor([part.expression]);
            while (cursor.moveNext()) {
              final rowId = cursor.current.columnAt(0) as int;
              if (hitRows.contains(rowId)) (partsByRow[rowId] ??= []).add(part.label);
            }
          }
        } finally {
          stmt.close();
        }
      }

      return [
        for (final r in rows)
          TextHit(
            imageId: r.columnAt(0) as String,
            score: (r.columnAt(2) as num).toDouble(),
            matchedTerms: List.unmodifiable(partsByRow[r.columnAt(1) as int] ?? const <String>[]),
            snippet: _cleanSnippet(r.columnAt(3) as String?, r.columnAt(4) as String),
          ),
      ];
    });
  }

  static final RegExp _ws = RegExp(r'\s+');

  static String? _cleanSnippet(String? snippet, String ocrText) {
    // Short texts are shown whole; otherwise FTS5's best ~20-token window.
    final source = ocrText.length <= 120 && ocrText.trim().isNotEmpty ? ocrText : snippet;
    if (source == null) return null;
    final s = source.replaceAll(_ws, ' ').trim();
    return s.isEmpty || s == '…' ? null : s;
  }

  /// Static so the isolate closure captures only the two strings (the store
  /// itself holds an unsendable FFI handle).
  static Future<VectorIndex?> _loadInBackground(String path, String modelId) =>
      Isolate.run(() => loadVectorIndexFromFile(path, modelId), debugName: 'vector-index-load');

  /// The in-memory index for [modelId], loading it on first use. Large
  /// indices are read by a background isolate; writes that happen meanwhile
  /// are journalled and replayed onto the loaded index.
  Future<VectorIndex> _vectorIndexFor(String modelId, int queryDim) async {
    final cached = _vectors[modelId];
    if (cached != null) return cached;
    final inFlight = _loading[modelId];
    if (inFlight != null) return inFlight;

    final path = _path;
    final count = _run((db) =>
        db.select('SELECT count(*) FROM embeddings WHERE model_id = ?', [modelId]).first.columnAt(0) as int);
    if (path == null || count < _isolateLoadThreshold) {
      // Small (or in-memory) index: cache even when empty so later upserts
      // are mirrored into it.
      return _vectors[modelId] = _run((db) => loadVectorIndex(db, modelId)) ?? VectorIndex(queryDim);
    }

    final generation = _generation;
    final journal = _journals[modelId] = <bool Function(VectorIndex)>[];
    Future<VectorIndex> load() async {
      VectorIndex? loaded;
      var workerFailed = false;
      try {
        loaded = await _loadInBackground(path, modelId);
      } catch (e) {
        debugPrint('IndexStore: background vector load failed (${describeError(e)}); loading synchronously');
        workerFailed = true;
      }
      if (_closed) throw StateError('IndexStore has been closed');
      if (generation != _generation) {
        // clearAll / recovery happened meanwhile: the snapshot is stale.
        return _vectorIndexFor(modelId, queryDim);
      }
      _loading.remove(modelId);
      _journals.remove(modelId);
      var ok = !workerFailed;
      if (ok && loaded != null) {
        for (final apply in journal) {
          ok = apply(loaded) && ok;
        }
      }
      if (!ok) loaded = _run((db) => loadVectorIndex(db, modelId));
      return _vectors[modelId] = loaded ?? VectorIndex(queryDim);
    }

    return _loading[modelId] = load();
  }

  @override
  Future<List<VectorHit>> searchVector(
    Float32List query, {
    required String modelId,
    SearchFilters filters = SearchFilters.none,
    int limit = 200,
  }) async {
    if (query.isEmpty || limit <= 0) {
      _requireDb();
      return const [];
    }
    final index = await _vectorIndexFor(modelId, query.length);
    _requireDb();
    if (index.dim != query.length) {
      debugPrint('IndexStore: query has ${query.length} dims but $modelId vectors have ${index.dim}');
      return const [];
    }
    final range = filters.dateRange;
    return index.search(
      query,
      startMs: range?.start.millisecondsSinceEpoch,
      endMs: range?.end.millisecondsSinceEpoch,
      kindMask: kindMask(filters.kinds),
      limit: limit,
    );
  }

  @override
  Future<List<GalleryImage>> browse({SearchFilters filters = SearchFilters.none, int limit = 200}) async {
    if (limit <= 0) {
      _requireDb();
      return const [];
    }
    return _run((db) {
      final (filterSql, params) = _filterSql(filters);
      final rows = db.select('''
        SELECT $_imageColumns FROM images i
        WHERE 1 = 1$filterSql
        ORDER BY i.created_at_ms DESC, i.id
        LIMIT ?''', [...params, limit]);
      return [for (final r in rows) _imageFromRow(r)];
    });
  }

  @override
  Future<List<String>> nearDuplicates(int hash, {int maxDistance = 4}) async {
    final hashes = _run((db) {
      var map = _hashes;
      if (map == null) {
        map = <String, int>{};
        for (final r in db.select('SELECT id, phash FROM images WHERE phash IS NOT NULL')) {
          map[r.columnAt(0) as String] = r.columnAt(1) as int;
        }
        _hashes = map;
      }
      return map;
    });
    final out = <(int, String)>[];
    for (final MapEntry(:key, :value) in hashes.entries) {
      final d = hammingDistance64(hash, value);
      if (d <= maxDistance) out.add((d, key));
    }
    out.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    return [for (final (_, id) in out) id];
  }

  @override
  Future<IndexStats> stats() async {
    return _run((db) {
      final r = db.select('''
        SELECT count(*),
               coalesce(sum(kind = 'screenshot'), 0),
               coalesce(sum(trim(ocr_text) <> ''), 0),
               (SELECT count(*) FROM embeddings),
               max(indexed_at_ms)
        FROM images''').first;
      final pageCount = db.select('PRAGMA page_count').first.columnAt(0) as int;
      final pageSize = db.select('PRAGMA page_size').first.columnAt(0) as int;
      final last = r.columnAt(4) as int?;
      return IndexStats(
        indexedImages: r.columnAt(0) as int,
        screenshots: r.columnAt(1) as int,
        imagesWithText: r.columnAt(2) as int,
        imagesWithEmbedding: r.columnAt(3) as int,
        databaseBytes: pageCount * pageSize,
        lastIndexedAt: last == null ? null : DateTime.fromMillisecondsSinceEpoch(last),
      );
    });
  }

  // ------------------------------------------------------- recent searches

  static String _normaliseQuery(String q) => q.trim().replaceAll(_ws, ' ');

  @override
  Future<void> addRecentSearch(String query) async {
    final normalised = _normaliseQuery(query);
    if (normalised.isEmpty) {
      _requireDb();
      return;
    }
    _run((db) {
      _transaction(db, () {
        final maxUsed = db.select('SELECT max(used_at) FROM recent_searches').first.columnAt(0) as int?;
        // Strictly increasing so two searches in the same millisecond keep order.
        final usedAt = math.max(DateTime.now().millisecondsSinceEpoch, (maxUsed ?? 0) + 1);
        db.execute('''
          INSERT INTO recent_searches (query_key, query, used_at) VALUES (?, ?, ?)
          ON CONFLICT (query_key) DO UPDATE SET query = excluded.query, used_at = excluded.used_at''',
            [normalised.toLowerCase(), normalised, usedAt]);
        db.execute('''
          DELETE FROM recent_searches WHERE query_key NOT IN (
            SELECT query_key FROM recent_searches ORDER BY used_at DESC LIMIT ?)''', [_maxRecentSearches]);
      });
    });
  }

  @override
  Future<List<String>> recentSearches({int limit = 8}) async {
    if (limit <= 0) {
      _requireDb();
      return const [];
    }
    return _run((db) => [
          for (final r in db.select('SELECT query FROM recent_searches ORDER BY used_at DESC LIMIT ?', [limit]))
            r.columnAt(0) as String,
        ]);
  }

  @override
  Future<void> clearRecentSearches() async {
    _run((db) {
      db.execute('DELETE FROM recent_searches');
      _truncateWal(db);
    });
  }

  /// secure_delete zeroes freed content in the database file, but in WAL
  /// mode the previous page images stay in the -wal side file until it is
  /// overwritten. After deleting private data (vanished images, recent
  /// searches) checkpoint and truncate the WAL so no copy survives there.
  /// Best effort: a concurrent reader (background vector load) can make the
  /// truncation partial; it then happens on a later call.
  void _truncateWal(Database db) {
    if (_path == null) return;
    try {
      db.select('PRAGMA wal_checkpoint(TRUNCATE)');
    } on SqliteException catch (e) {
      debugPrint('IndexStore: WAL truncation skipped (${describeError(e)})');
    }
  }

  // -------------------------------------------------------------- settings

  @override
  Future<String?> getSetting(String key) async {
    return _run((db) {
      final rows = db.select('SELECT value FROM settings WHERE key = ?', [key]);
      return rows.isEmpty ? null : rows.first.columnAt(0) as String;
    });
  }

  /// A null [value] removes the setting.
  @override
  Future<void> setSetting(String key, String? value) async {
    _run((db) {
      if (value == null) {
        db.execute('DELETE FROM settings WHERE key = ?', [key]);
      } else {
        db.execute(
          'INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value',
          [key, value],
        );
      }
    });
  }
}
