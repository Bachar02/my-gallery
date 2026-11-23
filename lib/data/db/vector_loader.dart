/// Builds a [VectorIndex] from the `embeddings` table.
///
/// [loadVectorIndexFromFile] is meant to run inside `Isolate.run`: it opens
/// its own read-only connection (WAL allows it to read concurrently with the
/// main connection) and returns the finished index. `Isolate.run` hands the
/// result back with `Isolate.exit`, which transfers the typed arrays without
/// copying them, so the UI isolate never pays for reading ~40 MB of blobs.
library;

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../domain/models.dart';
import 'vector_index.dart';

/// Null when the model has no stored vectors.
VectorIndex? loadVectorIndex(Database db, String modelId) {
  final count = db.select('SELECT count(*) FROM embeddings WHERE model_id = ?', [modelId]).first.columnAt(0) as int;
  if (count == 0) return null;
  final stmt = db.prepare('''
    SELECT e.image_id, e.dim, e.vector, i.created_at_ms, i.kind
    FROM embeddings e JOIN images i ON i.id = e.image_id
    WHERE e.model_id = ?''');
  VectorIndex? index;
  var skipped = 0;
  try {
    final cursor = stmt.selectCursor([modelId]);
    while (cursor.moveNext()) {
      final r = cursor.current;
      final dim = r.columnAt(1) as int;
      index ??= VectorIndex(dim, initialCapacity: count);
      if (dim != index.dim) {
        skipped++;
        continue;
      }
      index.putBlob(
        r.columnAt(0) as String,
        r.columnAt(2) as Uint8List,
        createdAtMs: r.columnAt(3) as int,
        kind: ImageKind.values.byName(r.columnAt(4) as String),
      );
    }
  } finally {
    stmt.close();
  }
  if (skipped > 0) debugPrint('IndexStore: skipped $skipped $modelId vectors with a different dimension');
  return index;
}

VectorIndex? loadVectorIndexFromFile(String path, String modelId) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    return loadVectorIndex(db, modelId);
  } finally {
    db.close();
  }
}
