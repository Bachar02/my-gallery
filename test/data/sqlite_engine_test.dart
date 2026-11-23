import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Verifies the bundled SQLite build has the features the index relies on.
void main() {
  test('bundled SQLite has FTS5, JSON and FTS5 secure-delete', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final options = [for (final r in db.select('PRAGMA compile_options')) r.columnAt(0) as String];
    // ignore: avoid_print
    print('SQLite ${sqlite3.version.libVersion}; compile options: ${options.join(', ')}');
    expect(options, contains('ENABLE_FTS5'));

    db.execute("CREATE VIRTUAL TABLE t USING fts5(x, tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3')");
    db.execute("INSERT INTO t (t, rank) VALUES ('secure-delete', 1)");
    db.execute('INSERT INTO t (x) VALUES (?)', ['Café crème']);
    expect(db.select('SELECT x FROM t WHERE t MATCH ?', ['"cafe"*']), hasLength(1));
    expect(db.select("SELECT value FROM json_each('[1,2]')"), hasLength(2));
  });
}
