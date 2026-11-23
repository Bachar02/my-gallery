/// Database schema and versioned migrations for the local index.
///
/// The schema version lives in `PRAGMA user_version`. Each entry of
/// [migrations] upgrades the schema by exactly one version and runs inside a
/// transaction together with the version bump, so a crash mid-migration
/// leaves the previous version intact. Never edit a released migration: add
/// a new one instead.
library;

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

/// Schema version produced by running every migration.
int get latestSchemaVersion => migrations.length;

typedef Migration = void Function(Database db);

/// `migrations[i]` upgrades from version `i` to `i + 1`.
final List<Migration> migrations = [_v1];

/// Runs every pending migration. Throws [IncompatibleSchemaException] when
/// the file was written by a newer app version (the caller treats the index
/// as a disposable cache and recreates it).
void migrate(Database db) {
  final current = db.userVersion;
  if (current > latestSchemaVersion) {
    throw IncompatibleSchemaException(current, latestSchemaVersion);
  }
  for (var v = current; v < latestSchemaVersion; v++) {
    db.execute('BEGIN IMMEDIATE');
    try {
      migrations[v](db);
      db.userVersion = v + 1;
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}

class IncompatibleSchemaException implements Exception {
  IncompatibleSchemaException(this.found, this.supported);
  final int found;
  final int supported;
  @override
  String toString() => 'IncompatibleSchemaException: database version $found, app supports $supported';
}

void _v1(Database db) {
  // `doc_id` is an INTEGER PRIMARY KEY (a rowid alias) so it is stable across
  // VACUUM; the external-content FTS table points at it. The MediaStore id is
  // the logical key (`id`, UNIQUE) and is what other tables reference.
  db.execute('''
    CREATE TABLE images (
      doc_id           INTEGER PRIMARY KEY,
      id               TEXT    NOT NULL UNIQUE,
      filename         TEXT,
      relative_path    TEXT,
      mime_type        TEXT,
      width            INTEGER NOT NULL,
      height           INTEGER NOT NULL,
      created_at_ms    INTEGER NOT NULL,
      modified_at_ms   INTEGER NOT NULL,
      kind             TEXT    NOT NULL CHECK (kind IN ('photo', 'screenshot')),
      ocr_text         TEXT    NOT NULL DEFAULT '',
      phash            INTEGER,
      indexed_at_ms    INTEGER NOT NULL,
      pipeline_version INTEGER NOT NULL
    )''');
  db.execute('CREATE INDEX images_created_idx ON images (created_at_ms DESC)');
  db.execute('CREATE INDEX images_kind_created_idx ON images (kind, created_at_ms DESC)');

  db.execute('''
    CREATE TABLE embeddings (
      image_id TEXT    NOT NULL PRIMARY KEY REFERENCES images (id) ON DELETE CASCADE,
      model_id TEXT    NOT NULL,
      dim      INTEGER NOT NULL CHECK (dim > 0),
      vector   BLOB    NOT NULL CHECK (length(vector) = dim * 4)
    )''');
  db.execute('CREATE INDEX embeddings_model_idx ON embeddings (model_id)');

  // query_key is the case-folded, whitespace-normalised query used for
  // de-duplication; query keeps the most recently typed spelling.
  db.execute('''
    CREATE TABLE recent_searches (
      query_key TEXT    NOT NULL PRIMARY KEY,
      query     TEXT    NOT NULL,
      used_at   INTEGER NOT NULL
    )''');
  db.execute('CREATE INDEX recent_searches_used_idx ON recent_searches (used_at DESC)');

  db.execute('''
    CREATE TABLE settings (
      key   TEXT NOT NULL PRIMARY KEY,
      value TEXT NOT NULL
    )''');

  // External-content FTS5 index: the text is stored once (images.ocr_text)
  // and triggers keep the index in sync. snippet()/highlight() still work
  // because FTS5 reads column values back from `images`.
  db.execute('''
    CREATE VIRTUAL TABLE images_fts USING fts5 (
      ocr_text,
      filename,
      content = 'images',
      content_rowid = 'doc_id',
      tokenize = 'unicode61 remove_diacritics 2',
      prefix = '2 3'
    )''');
  db.execute('''
    CREATE TRIGGER images_fts_ai AFTER INSERT ON images BEGIN
      INSERT INTO images_fts (rowid, ocr_text, filename)
      VALUES (new.doc_id, new.ocr_text, new.filename);
    END''');
  db.execute('''
    CREATE TRIGGER images_fts_ad AFTER DELETE ON images BEGIN
      INSERT INTO images_fts (images_fts, rowid, ocr_text, filename)
      VALUES ('delete', old.doc_id, old.ocr_text, old.filename);
    END''');
  db.execute('''
    CREATE TRIGGER images_fts_au AFTER UPDATE OF ocr_text, filename ON images
    WHEN old.ocr_text IS NOT new.ocr_text OR old.filename IS NOT new.filename BEGIN
      INSERT INTO images_fts (images_fts, rowid, ocr_text, filename)
      VALUES ('delete', old.doc_id, old.ocr_text, old.filename);
      INSERT INTO images_fts (rowid, ocr_text, filename)
      VALUES (new.doc_id, new.ocr_text, new.filename);
    END''');

  // FTS5 secure-delete: removed documents are purged from the index b-tree
  // immediately instead of leaving "delete markers" that keep the old tokens
  // on disk until the next merge. Requires SQLite >= 3.42 (the bundled build
  // is newer); tolerate older engines rather than failing the migration.
  try {
    db.execute("INSERT INTO images_fts (images_fts, rank) VALUES ('secure-delete', 1)");
  } on SqliteException catch (e) {
    debugPrint('IndexStore: FTS5 secure-delete unavailable ($e)');
  }
}
