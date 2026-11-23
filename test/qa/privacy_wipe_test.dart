// QA: verifies that "Delete local index", "Clear recent searches" and the
// removal of vanished images physically remove private text from every file
// the index uses (main database, -wal and -shm side files), not just from
// query results.

import 'dart:convert';
import 'dart:io';

import 'package:ai_gallery/data/db/sqlite_index_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../data/fixtures.dart';

/// Unique tokens that never occur in SQLite headers or the schema.
const _ocrMarker = 'qzxvocrsecret7731';
const _queryMarker = 'qzxvquerysecret4418';
const _nameMarker = 'qzxvfilesecret9902';

/// Every file belonging to the database at [dbPath] and which of them
/// contain [needle] (UTF-8 bytes).
List<String> _filesContaining(String dbPath, String needle) {
  final pattern = utf8.encode(needle);
  final hits = <String>[];
  for (final suffix in const ['', '-wal', '-shm', '-journal']) {
    final f = File('$dbPath$suffix');
    if (!f.existsSync()) continue;
    if (_indexOf(f.readAsBytesSync(), pattern) >= 0) hits.add(p.basename(f.path));
  }
  return hits;
}

int _indexOf(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

void main() {
  late Directory dir;
  late String dbPath;
  late SqliteIndexStore store;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('qa_wipe_');
    dbPath = p.join(dir.path, SqliteIndexStore.fileName);
    store = SqliteIndexStore(dbPath);
    await store.open();
  });

  tearDown(() async {
    await store.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> plant() async {
    await store.upsertAll([
      record('secret', ocr: 'IBAN DE89 $_ocrMarker please transfer', filename: '${_nameMarker}_1.png'),
      for (var i = 0; i < 30; i++) record('other$i', ocr: 'ordinary text number $i'),
    ]);
    await store.addRecentSearch('find $_queryMarker');
    // Sanity: the planted text really is on disk (WAL mode, not checkpointed).
    expect(_filesContaining(dbPath, _ocrMarker), isNotEmpty);
    expect(_filesContaining(dbPath, _queryMarker), isNotEmpty);
  }

  test('clearAll leaves no OCR text, file name or query in the db, WAL or SHM', () async {
    await plant();
    await store.clearAll();
    expect(_filesContaining(dbPath, _ocrMarker), isEmpty);
    expect(_filesContaining(dbPath, _nameMarker), isEmpty);
    expect(_filesContaining(dbPath, _queryMarker), isEmpty);
    expect((await store.stats()).indexedImages, 0);
    expect(await store.recentSearches(), isEmpty);
    // After a further write + close (checkpoint) nothing reappears.
    await store.upsert(record('new', ocr: 'fresh content'));
    await store.close();
    expect(_filesContaining(dbPath, _ocrMarker), isEmpty);
  });

  test('clearAll in-place fallback (file cannot be deleted) also wipes the WAL', () async {
    // On Windows an open handle prevents deletion, which forces the
    // DELETE + VACUUM + wal_checkpoint(TRUNCATE) fallback path. On other
    // hosts the file is deleted (main path), which is fine too.
    await plant();
    final reader = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    addTearDown(reader.close);
    await store.clearAll();
    expect(_filesContaining(dbPath, _ocrMarker), isEmpty);
    expect(_filesContaining(dbPath, _queryMarker), isEmpty);
    expect((await store.stats()).indexedImages, 0);
  }, skip: Platform.isWindows ? false : 'fallback only reachable on Windows hosts');

  test('deleting one image (vanished from the gallery) removes its text from every file', () async {
    await plant();
    await store.delete(['secret']);
    expect(await store.get('secret'), isNull);
    expect(await store.searchText(terms: [_ocrMarker]), isEmpty);
    expect(_filesContaining(dbPath, _ocrMarker), isEmpty, reason: 'OCR text survived a delete');
  });

  test('clearRecentSearches removes the query text from every file', () async {
    await plant();
    await store.clearRecentSearches();
    expect(await store.recentSearches(), isEmpty);
    expect(_filesContaining(dbPath, _queryMarker), isEmpty, reason: 'query text survived clearing');
  });

  test('store error logging drops the SQL statement and bound parameters', () {
    final e = SqliteException(
      extendedResultCode: 11,
      message: 'database disk image is malformed',
      causingStatement: 'INSERT INTO images (id, ocr_text) VALUES (?, ?)',
      parametersToStatement: ['42', 'IBAN $_ocrMarker'],
    );
    expect(e.toString(), contains(_ocrMarker)); // why sanitising is needed
    final logged = SqliteIndexStore.describeError(e);
    expect(logged, contains('malformed'));
    expect(logged, isNot(contains(_ocrMarker)));
    expect(logged, isNot(contains('INSERT')));
  });

  test('re-indexing an image with new OCR text removes the old text', () async {
    await plant();
    await store.upsert(record('secret', ocr: 'replaced text'));
    expect(await store.searchText(terms: [_ocrMarker]), isEmpty);
    expect(_filesContaining(dbPath, _ocrMarker), isEmpty, reason: 'old OCR text survived an update');
  },
      skip: 'Open defect (docs/QA_REPORT.md, QA-07): the previous page image stays in the -wal file '
          'until overwritten when an image is re-indexed with different text.');
}
