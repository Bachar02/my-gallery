import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/interfaces.dart';
import '../../domain/models.dart';
import '../../ml/image/dhash.dart';
import 'pipeline_version.dart';

/// Computes a 64-bit perceptual hash from encoded image bytes, or null.
typedef ImageHasher = Future<int?> Function(Uint8List encoded);

/// Incremental gallery indexer: scan -> diff -> OCR + embedding + dHash -> store.
///
/// * Diff: new images, images whose `modifiedAt` changed, and records from an
///   older pipeline (see [kPipelineVersion] / [pipelineStamp]) are processed;
///   records whose image is no longer listed are deleted from the index.
/// * Per image: OCR on the original file (falls back to a 2048 px JPEG
///   rendition written to a temp file when the original is missing or
///   unreadable, e.g. some HEIC files or cloud placeholders); a 256 px
///   thumbnail feeds the dHash (decoded in a background isolate) and, when the
///   semantic model is loaded, the image embedding.
/// * Work is sequential, newest images first, with progress after every
///   item and `upsertAll` every [batchSize] records (and before pausing).
/// * A failing item is counted in [IndexingProgress.failed] and skipped; it is
///   retried on the next sync. If the gallery permission was revoked, the run
///   ends with [IndexingPhase.permissionDenied].
/// * [pause]/[resume] take effect at item boundaries; [stop] cancels.
/// * After the first [start], gallery change notifications trigger a
///   debounced re-sync while idle (or right after the current run).
class DefaultIndexingService implements IndexingService {
  DefaultIndexingService({
    required this._gallery,
    required this._store,
    required this._ocr,
    required this._semantic,
    ImageHasher? hasher,
    Future<Directory> Function()? tempDirectory,
    DateTime Function()? clock,
    this.batchSize = 20,
    this.resyncDebounce = const Duration(seconds: 3),
    this.thumbnailSize = 256,
    this.ocrFallbackMaxSide = 2048,
  })  : _hasher = hasher ?? isolateDHash,
        _tempDirectory = tempDirectory ?? getTemporaryDirectory,
        _clock = clock ?? DateTime.now;

  static const String lastCompletedSettingKey = 'indexing.lastCompletedAt';

  final GalleryRepository _gallery;
  final IndexStore _store;
  final OcrEngine _ocr;
  final SemanticModel _semantic;
  final ImageHasher _hasher;
  final Future<Directory> Function() _tempDirectory;
  final DateTime Function() _clock;
  final int batchSize;
  final Duration resyncDebounce;
  final int thumbnailSize;
  final int ocrFallbackMaxSide;

  final StreamController<IndexingProgress> _controller = StreamController.broadcast();
  IndexingProgress _current = IndexingProgress.idle;
  Future<void>? _running;
  bool _stopRequested = false;
  bool _pauseRequested = false;
  Completer<void>? _resumeGate;
  StreamSubscription<void>? _changes;
  Timer? _debounce;
  bool _resyncPending = false;
  bool _disposed = false;
  DateTime? _lastCompletedAt;
  int _tempCounter = 0;

  /// dHash computed in a short-lived background isolate.
  static Future<int?> isolateDHash(Uint8List encoded) => Isolate.run(() => DHash.ofEncoded(encoded));

  @override
  Stream<IndexingProgress> get progress => _controller.stream;

  @override
  IndexingProgress get current => _current;

  /// Starts an incremental sync and completes when it ends. If a sync is
  /// already running, returns that sync's future (no second run).
  @override
  Future<void> start() {
    if (_disposed) return Future.value();
    _changes ??= _gallery.changes.listen((_) => _onGalleryChanged());
    final running = _running;
    if (running != null) return running;
    _stopRequested = false;
    _pauseRequested = false;
    late final Future<void> run;
    run = _sync().whenComplete(() {
      if (identical(_running, run)) _running = null;
      if (_resyncPending && !_disposed && !_stopRequested) {
        _resyncPending = false;
        _onGalleryChanged();
      }
    });
    _running = run;
    return run;
  }

  @override
  void pause() {
    if (_running == null) return;
    _pauseRequested = true;
  }

  @override
  void resume() {
    _pauseRequested = false;
    final gate = _resumeGate;
    _resumeGate = null;
    gate?.complete();
  }

  @override
  Future<void> stop() async {
    _debounce?.cancel();
    final running = _running;
    if (running == null) return;
    _stopRequested = true;
    resume();
    await running;
  }

  /// Stops any run and releases the change subscription.
  Future<void> dispose() async {
    _disposed = true;
    await stop();
    await _changes?.cancel();
    _changes = null;
    await _controller.close();
  }

  void _onGalleryChanged() {
    if (_disposed) return;
    _debounce?.cancel();
    _debounce = Timer(resyncDebounce, () {
      if (_disposed) return;
      if (_running != null) {
        _resyncPending = true;
        return;
      }
      start();
    });
  }

  void _emit(IndexingProgress p) {
    _current = p;
    if (!_controller.isClosed) _controller.add(p);
  }

  IndexingProgress _phase(IndexingPhase phase, {int total = 0, int processed = 0, int failed = 0, String? error}) =>
      IndexingProgress(
        phase: phase,
        total: total,
        processed: processed,
        failed: failed,
        errorMessage: error,
        lastCompletedAt: _lastCompletedAt,
      );

  // ------------------------------------------------------------------ run

  Future<void> _sync() async {
    final sw = Stopwatch()..start();
    var embedded = 0;
    try {
      await _syncInner(onEmbedded: () => embedded++);
    } finally {
      // Counts only: no file names, ids or recognised text in logs.
      final p = _current;
      debugPrint('Indexing run ended: phase=${p.phase.name} processed=${p.processed} '
          'failed=${p.failed} total=${p.total} elapsedMs=${sw.elapsedMilliseconds} '
          'embeddings=${embedded > 0 ? 'yes ($embedded)' : 'no'}');
    }
  }

  Future<void> _syncInner({required void Function() onEmbedded}) async {
    var total = 0;
    var processed = 0;
    var failed = 0;
    final batch = <IndexRecord>[];
    Future<void> flush() async {
      if (batch.isEmpty) return;
      final copy = List<IndexRecord>.of(batch);
      batch.clear();
      await _store.upsertAll(copy);
    }

    try {
      _lastCompletedAt ??= DateTime.tryParse(await _store.getSetting(lastCompletedSettingKey) ?? '');
      if (!_isGranted(await _gallery.permissionStatus())) {
        _emit(_phase(IndexingPhase.permissionDenied));
        return;
      }
      _emit(_phase(IndexingPhase.scanning));

      final modelAvailable = _semantic.isLoaded || await _semantic.load();

      final images = <GalleryImage>[];
      await for (final page in _gallery.listAllImages()) {
        images.addAll(page);
        if (_stopRequested) {
          _emit(_phase(IndexingPhase.idle));
          return;
        }
      }

      final indexed = await _store.indexedVersions();
      final listed = {for (final i in images) i.id};
      final gone = [for (final id in indexed.keys) if (!listed.contains(id)) id];
      if (gone.isNotEmpty) await _store.delete(gone);

      final work = [
        for (final img in images)
          if (_needsWork(img, indexed[img.id], modelAvailable)) img,
      ];
      total = work.length;
      _emit(_phase(IndexingPhase.indexing, total: total));

      for (final image in work) {
        if (_pauseRequested && !_stopRequested) {
          await flush();
          _emit(_phase(IndexingPhase.paused, total: total, processed: processed, failed: failed));
          final gate = _resumeGate ??= Completer<void>();
          if (_pauseRequested) await gate.future;
          if (!_stopRequested) {
            _emit(_phase(IndexingPhase.indexing, total: total, processed: processed, failed: failed));
          }
        }
        if (_stopRequested) break;

        final outcome = await _processOne(image, indexed[image.id], modelAvailable);
        switch (outcome) {
          case _Indexed(:final record):
            batch.add(record);
            if (record.embedding != null) onEmbedded();
          case _Vanished():
            await _store.delete([image.id]);
          case _Failed():
            failed++;
          case _PermissionLost():
            await flush();
            _emit(_phase(IndexingPhase.permissionDenied, total: total, processed: processed, failed: failed));
            return;
        }
        processed++;
        if (batch.length >= batchSize) await flush();
        _emit(_phase(IndexingPhase.indexing, total: total, processed: processed, failed: failed));
      }
      await flush();

      if (_stopRequested) {
        _emit(_phase(IndexingPhase.idle, total: total, processed: processed, failed: failed));
        return;
      }
      final done = _clock();
      _lastCompletedAt = done;
      await _store.setSetting(lastCompletedSettingKey, done.toIso8601String());
      _emit(_phase(IndexingPhase.completed, total: total, processed: processed, failed: failed));
    } catch (e, st) {
      debugPrint('Indexing failed: ${e.runtimeType}\n$st');
      try {
        await flush();
      } catch (_) {
        // The store itself is failing; the error below says so.
      }
      _emit(_phase(IndexingPhase.error, total: total, processed: processed, failed: failed, error: userFacingError(e)));
    }
  }

  /// Short description of [e] for the status card (and safe to log): only
  /// the first line, without file paths. `SqliteException.toString()` appends
  /// the failing SQL and its bound parameters (recognised text, file names),
  /// and `FileSystemException` includes the path.
  @visibleForTesting
  static String userFacingError(Object e) {
    var s = e.toString().split('\n').first.trim();
    s = s.replaceAll(RegExp(r",?\s*path = '[^']*'"), '');
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }

  static bool _isGranted(GalleryPermission p) => p == GalleryPermission.granted || p == GalleryPermission.limited;

  static bool _needsWork(GalleryImage img, ({int modifiedAtMs, int pipelineVersion})? v, bool modelAvailable) {
    if (v == null) return true;
    if (v.modifiedAtMs != img.modifiedAt.millisecondsSinceEpoch) return true;
    return !isStampCurrent(v.pipelineVersion, modelAvailable: modelAvailable);
  }

  // ------------------------------------------------------------ one image

  Future<_Outcome> _processOne(
    GalleryImage image,
    ({int modifiedAtMs, int pipelineVersion})? previous,
    bool modelAvailable,
  ) async {
    try {
      String? text;
      int? hash;
      // Same file, same pipeline, only the embedding is missing: keep the
      // OCR text and hash instead of recognising the image again.
      if (previous != null &&
          previous.modifiedAtMs == image.modifiedAt.millisecondsSinceEpoch &&
          previous.pipelineVersion == pipelineStamp(withEmbedding: false)) {
        final old = await _store.get(image.id);
        text = old?.ocrText;
        hash = old?.perceptualHash;
      }
      text ??= await _recognize(image);
      if (text == null) return await _diagnoseFailure(image);

      final thumb = await _safe(() => _gallery.thumbnail(image.id, size: thumbnailSize));
      if (thumb != null) {
        hash ??= await _safe(() => _hasher(thumb));
      }
      Float32List? embedding;
      if (modelAvailable && thumb != null) {
        embedding = await _safe(() => _semantic.embedImage(thumb));
      }
      return _Indexed(IndexRecord(
        image: image,
        ocrText: text,
        embedding: embedding,
        embeddingModel: embedding != null ? _semantic.modelId : null,
        perceptualHash: hash,
        indexedAt: _clock(),
        pipelineVersion: pipelineStamp(withEmbedding: embedding != null),
      ));
    } catch (e) {
      debugPrint('Indexing an image failed: ${e.runtimeType}');
      return _diagnoseFailure(image);
    }
  }

  /// OCR text, or null when the image could not be read at all.
  Future<String?> _recognize(GalleryImage image) async {
    final original = await _safe(() => _gallery.originalFile(image.id));
    if (original != null) {
      try {
        return await _ocr.recognize(original);
      } catch (e) {
        debugPrint('OCR on an original failed (${e.runtimeType}), using rendition');
      }
    }
    final bytes = await _safe(() => _gallery.displayImage(image.id, maxSide: ocrFallbackMaxSide));
    if (bytes == null || bytes.isEmpty) return null;
    final dir = await _tempDirectory();
    final tmp = File(p.join(dir.path, 'ocr_${DateTime.now().microsecondsSinceEpoch}_${_tempCounter++}.jpg'));
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      return await _ocr.recognize(tmp);
    } catch (e) {
      debugPrint('OCR on a rendition failed: ${e.runtimeType}');
      return null;
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // Temp directory cleanup is best effort.
      }
    }
  }

  /// Distinguishes "permission revoked" and "image deleted meanwhile" from a
  /// genuine per-item failure.
  Future<_Outcome> _diagnoseFailure(GalleryImage image) async {
    final permission = await _safe(_gallery.permissionStatus);
    if (permission != null && !_isGranted(permission)) return const _PermissionLost();
    final stillThere = await _safe(() => _gallery.getImage(image.id));
    if (permission != null && stillThere == null) return const _Vanished();
    return const _Failed();
  }

  static Future<T?> _safe<T>(Future<T?> Function() f) async {
    try {
      return await f();
    } catch (e) {
      debugPrint('Indexing step failed: ${e.runtimeType}');
      return null;
    }
  }
}

sealed class _Outcome {
  const _Outcome();
}

class _Indexed extends _Outcome {
  const _Indexed(this.record);
  final IndexRecord record;
}

class _Vanished extends _Outcome {
  const _Vanished();
}

class _Failed extends _Outcome {
  const _Failed();
}

class _PermissionLost extends _Outcome {
  const _PermissionLost();
}
