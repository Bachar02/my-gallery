# AI Gallery: local index database

Owner: Agent 4 (DB). Implementation: `lib/data/db/`. Tests: `test/data/`.

The index is a **rebuildable cache** derived from the user's gallery. It
holds OCR text, metadata, CLIP embeddings and perceptual hashes. It never
leaves the device. If it is lost or corrupted, the indexing service rebuilds
it on its next run.

| File | Purpose |
|---|---|
| `sqlite_index_store.dart` | `SqliteIndexStore implements IndexStore` |
| `schema.dart` | versioned migrations (`PRAGMA user_version`) |
| `fts_query.dart` | safe FTS5 MATCH construction from user text |
| `vector_index.dart` | in-memory vector index, top-K heap, 64-bit popcount |
| `vector_loader.dart` | builds a vector index from SQLite (also inside a background isolate) |

## Opening

```dart
final store = await SqliteIndexStore.openDefault(); // app-private storage
// tests: SqliteIndexStore.inMemory()..open()
```

`openDefault()` uses `<getApplicationSupportDirectory()>/index/ai_gallery_index.db`.
On Android that is `/data/data/<pkg>/files/index/`, which is private to the app.

Each connection sets these pragmas: `foreign_keys=ON`, `secure_delete=ON`,
`journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=2000`, and
`page_size=16384`. The page size only takes effect on new files (see "Page size" below).

After `close()`, every method throws `StateError`, including `open()`.

## Schema (version 1)

```
images(
  doc_id INTEGER PRIMARY KEY,          -- rowid alias; stable across VACUUM; FTS content_rowid
  id TEXT NOT NULL UNIQUE,             -- MediaStore id (logical key)
  filename, relative_path, mime_type TEXT,
  width, height INTEGER NOT NULL,
  created_at_ms, modified_at_ms INTEGER NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('photo','screenshot')),
  ocr_text TEXT NOT NULL DEFAULT '',
  phash INTEGER,                       -- 64-bit dHash, signed two's complement
  indexed_at_ms, pipeline_version INTEGER NOT NULL)
  INDEX (created_at_ms DESC), INDEX (kind, created_at_ms DESC)

embeddings(
  image_id TEXT PRIMARY KEY REFERENCES images(id) ON DELETE CASCADE,
  model_id TEXT NOT NULL, dim INTEGER NOT NULL,
  vector BLOB NOT NULL CHECK (length(vector) = dim*4))   -- float32 little-endian
  INDEX (model_id)

recent_searches(query_key TEXT PRIMARY KEY, query TEXT, used_at INTEGER)  INDEX (used_at DESC)
settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)
images_fts  -- FTS5, see below
```

The brief asked for `id` as the primary key. `id` is `UNIQUE` (and is the
foreign-key target), and an explicit `INTEGER PRIMARY KEY doc_id` exists only
because an external-content FTS table needs a rowid that `VACUUM` can never renumber.

Each image has one embedding. An upsert replaces it, and a record without an
embedding deletes it. `recent_searches.query_key` is the trimmed,
whitespace-collapsed, lower-cased query; it gives case-insensitive dedupe and
keeps the latest spelling for display.

**Migrations.** `migrations[i]` upgrades version `i` to `i+1`. It runs in a
transaction together with the `user_version` bump. A file whose version is
newer than the app supports is treated as unreadable and recreated.

**Page size.** A 512-d vector row is about 2.1 KB. With 4 KiB pages only one
row fits per page, which wastes half the file. With 16 KiB pages seven rows
fit. Measured at 20k images: **89 MiB with 4 KiB pages, 57 MiB with 16 KiB**,
and the bulk vector load is also faster.

## Full-text search (FTS5)

```sql
CREATE VIRTUAL TABLE images_fts USING fts5(ocr_text, filename,
  content='images', content_rowid='doc_id',
  tokenize='unicode61 remove_diacritics 2', prefix='2 3');
```

* **External content, kept in sync by triggers.** The text is stored once
  (in `images`). `snippet()` still works, which a contentless table could not
  do. Triggers:
  * AFTER INSERT adds the row.
  * AFTER DELETE issues `'delete'` with the old values.
  * AFTER UPDATE OF ocr_text, filename issues delete+insert, but only when the
    text actually changed, so re-indexing unchanged images costs nothing.
* **FTS5 `secure-delete=1`.** Deleted documents are purged from the index
  b-tree immediately instead of leaving delete markers that keep old tokens
  on disk until a merge.
* **Tokenizer.** Matching is case-insensitive and diacritic-insensitive
  ("cafe" finds "Café"). Filename separators (`_`, `-`, `.`) split tokens.
  Prefix indexes on 2 and 3 characters speed up prefix queries.

**Query construction** (`buildFtsQuery`). No user text reaches FTS5 as syntax:
1. Each term or phrase is reduced to its word characters
   (`\p{L}\p{N}\p{M}\p{Co}`). This removes `" * ( ) : ^ - +` and similar.
2. Bare operator words (`AND OR NOT NEAR`) are dropped from *terms*. Inside
   phrases they stay, because quoted text has no operator meaning.
3. Each part becomes one double-quoted FTS5 string, with inner quotes doubled
   as a second line of defence:
   * a term becomes the prefix match `"term"*`;
   * a term with inner punctuation (`e-mail`) becomes the prefix phrase `"e mail"*`;
   * a phrase becomes `"word word"` (verbatim, consecutive, no prefix).
4. Parts are joined with `OR`, so partial coverage still matches.
   Duplicate parts (case-insensitive) are merged.
5. The expression is bound as a parameter. Filters and the limit are bound
   too. No user value is ever interpolated into SQL.

**Ranking.** `bm25(images_fts, 4.0, 1.0)` weights OCR text 4× over the
filename. It is negated so that higher is better, giving `TextHit.score > 0`.
bm25 sums per-term contributions, so hits covering more terms rank higher.
Filters (`created_at_ms` in [start, end), `kind IN (...)`) are applied in the
same SQL statement.

**matchedTerms.** For each part, the store reads that part's FTS doclist
(`MATCH '"term"*'`) and intersects it with the hit set. This uses exactly the
same tokenizer and normalisation as the main query, so a term is reported
only if it really occurs in that image's OCR text or filename. With a single
part, no extra query is needed. This was measured much faster than
constraining with `rowid IN (...)`: about 3 ms per very common prefix,
compared with 60 to 100 ms.

**Snippet.** When the OCR text is 120 characters or less, the whole text is
returned (whitespace collapsed). Otherwise it is FTS5
`snippet(..., -1, '', '', '…', 20)`, the best window of about 20 tokens
(roughly 120 characters).

## Vector search

* **Lazy load.** On the first query for a `model_id`, every vector of that
  model is loaded into one contiguous `Float32List` (row-major). It sits
  alongside parallel `Int64List created_at` and `Uint8List kind-bit` arrays
  and a `Map<id, slot>`. At 20k × 512 that is 40 MB of RAM.
* **Background load.** For 2,000 or more vectors on a file database, the load
  runs in `Isolate.run` with its own read-only connection (WAL allows
  concurrent readers). The finished index returns via `Isolate.exit`, which
  transfers it without a copy. Writes made while the load runs are journalled
  and replayed onto the loaded index. If a `clearAll` or recovery happens
  during the load, the stale snapshot is discarded and the load restarts.
  Concurrent first queries share one load. Smaller indexes, and in-memory
  stores, load synchronously.
* **Kept in sync.** After each successful commit, the loaded indexes are
  updated by `upsert`/`upsertAll`. This covers a new vector, a replaced
  vector, a model change (the vector moves to the other model's index), a
  removed embedding, and changed date or kind. `delete` and `clearAll`/close
  update them too. A dimension change for a model drops that index, and it
  reloads on the next query.
* **Scan.** Vectors are L2-normalised, so cosine similarity is the dot
  product. The dot product uses `Float32x4` SIMD with two accumulators; a
  scalar path handles `dim % 4 != 0`. Filters are checked against the
  parallel arrays before the dot product, so filtered queries are cheaper.
* **Top-K.** A bounded min-heap of size K gives O(n log K). Only the K
  survivors are sorted.
* A query whose length differs from the stored dimension returns `[]` and
  logs a message.

**Near duplicates.** The id→dHash map is loaded lazily and kept in sync like
the vectors. Distance is `popCount64(a ^ b)`, a SWAR popcount using `>>>`
(logical shift) with wrapping multiplication. It is correct for negative
(top-bit-set) hashes and is tested against a naive bit loop. Results are
ordered by distance, then id.

## Measured performance (host)

Measured on this Windows laptop with `flutter test` (JIT), using
`test/data/benchmark_test.dart`: 20,000 images, 512-d vectors, about 2/3 of
images carrying ~40-word OCR text. The vocabulary is synthetic and small, so
the text search is a dense worst case where nearly every document matches.
The table shows two runs.

| Operation | Time |
|---|---|
| `upsertAll` 100 records (one transaction) | 17–20 ms |
| `upsertAll` 19,900 records | 2.9–5.2 s (150–260 µs/record) |
| DB file size | 57 MiB |
| first `searchVector` (lazy load) | ~130 ms wall clock, **max UI-isolate stall 6.5 ms** |
| `searchVector` top-200, warm | **median 5.6–8.4 ms**, max 14–18 ms (includes JIT warm-up) |
| `searchVector` with date and kind filters | median 1.3–2.0 ms |
| `searchText`, 3 terms and 1 phrase, worst-case dense corpus | median 32–57 ms |
| `nearDuplicates`, first call / warm | 17–31 ms / 0.6–1.2 ms |
| `clearAll` (file recreate) | ~50 ms |

Before the rework, the measurements were: `clearAll` by in-place
DELETE + VACUUM took 22 s, because `secure_delete` zeroes every freed page;
`searchText` took 308 ms when matchedTerms used `rowid IN`; and the DB was
91 MiB with 4 KiB pages.

## Threading decisions

`package:sqlite3` makes synchronous FFI calls on the calling isolate. Every
public method runs its SQL without an `await` in between, so methods are
atomic with respect to each other and need no lock.

* **Vector scan stays on the UI isolate.** A warm scan takes about 6 ms on
  the host. Mid-range phones (AOT) are expected to be 2–4× slower, so roughly
  12–25 ms, which is inside the 50 ms target. Running the scan in another
  isolate per query would mean copying 40 MB or maintaining a resident worker
  isolate, which costs more than the scan itself. Revisit this if the device
  measurement exceeds about 30 ms (option: a long-lived worker isolate that
  owns the matrix).
* **Vector lazy load goes to a background isolate**, as described above.
  It reads ~40 MB of blobs.
* **Bulk writes.** `upsertAll` is one synchronous transaction, about 0.2 ms
  per record on the host. **The indexing service should send batches of
  about 50–100 records** (about 20 ms on the host). A single 20k-record call
  would block for seconds.
* `searchText` on large, dense corpora can take tens of milliseconds. Real
  OCR vocabularies are much sparser, and the parser removes stop words.
  Measure on the device; if it is slow, the next step is to move reads to a
  worker isolate with its own connection.

## Robustness

* **Unreadable file on open.** This covers a file that is not a database
  (`SQLITE_NOTADB`), a failed migration, a schema version that is too new,
  or a missing table. The store logs with `debugPrint`, deletes the db,
  `-wal`, `-shm` and `-journal` files, and recreates an empty index. It never
  throws to the app. The old file is **deleted, not backed up**, because it
  contains private OCR text and the index can be rebuilt.
* **Corruption at runtime.** If a call fails with `SQLITE_CORRUPT` or
  `SQLITE_NOTADB`, the database is recreated empty and the error is rethrown
  for that one call. The next incremental sync then re-indexes everything,
  because `indexedVersions()` is empty.
* `upsertAll` is all-or-nothing (tested with a failing trigger). In-memory
  indexes are only updated after the commit succeeds.

## Privacy notes

* The database lives in app-private internal storage. No other app can read
  it, and it is never written to shared or external storage.
* `PRAGMA secure_delete=ON` overwrites deleted content with zeros. FTS5
  `secure-delete` removes deleted tokens from the full-text index straight
  away.
* `clearAll()` ("Delete index") closes the connection, **deletes the database
  file and its WAL/SHM files**, and creates a fresh file. Only the
  `settings` rows are carried over. Images, OCR text, embeddings, hashes and
  recent searches are all gone, and no old page survives in the new file or
  its WAL. If the file cannot be deleted (Windows only, while a reader has it
  open), the store falls back to an in-place DELETE, then VACUUM, then
  `wal_checkpoint(TRUNCATE)`. Physical flash blocks are protected by Android
  file-based encryption.
* **The database must be excluded from Android backup.** This is for the
  Android owner: `files/` is included in Auto Backup by default. Exclude
  `index/` in both `data_extraction_rules.xml` (API 31+) and
  `full_backup_content.xml`:
  ```xml
  <exclude domain="file" path="index/" />
  ```
  Alternatively, set `android:allowBackup="false"`.
* Recent searches are capped at 50 entries. `clearRecentSearches()` and
  `clearAll()` remove them.

## Bundled SQLite and FTS5 availability

`sqlite3` 3.9.2 bundles its own SQLite build through build hooks: it uses
the same precompiled upstream binaries for Android (armv7a, aarch64, x86,
x64) and Windows, compiled with `SQLITE_ENABLE_FTS5`. It never uses the
system SQLite, which on Android varies by OEM and may lack FTS5.
`test/data/sqlite_engine_test.dart` checks `PRAGMA compile_options` for
`ENABLE_FTS5` (host: SQLite 3.54.1). It also creates an FTS5 table with the
production tokenizer, enables secure-delete, and uses `json_each`. The build
hook downloads the binary for each ABI at build time, so the first Android
build needs network access, or a cached artifact through `url_pattern`.
