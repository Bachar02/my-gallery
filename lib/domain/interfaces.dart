/// Shared module interfaces.
///
/// OWNERSHIP: Team Lead. Implementations live in feature modules
/// (see docs/ARCHITECTURE.md for who owns which implementation).
library;

import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

/// Android MediaStore access. Implementation: `PhotoManagerGalleryRepository`.
abstract interface class GalleryRepository {
  Future<GalleryPermission> permissionStatus();

  /// Shows the system permission dialog when possible.
  Future<GalleryPermission> requestPermission();

  /// Opens the app's system settings page (for permanently denied access).
  Future<void> openAppSettings();

  /// Android 14+: lets the user change which photos are shared (limited access).
  Future<void> manageLimitedSelection();

  /// All images currently accessible, newest first, delivered in pages.
  Stream<List<GalleryImage>> listAllImages({int pageSize = 200});

  Future<int> countImages();

  /// Null when the image no longer exists or is no longer accessible.
  Future<GalleryImage?> getImage(String id);

  /// Encoded (JPEG) thumbnail whose longest side is about [size] px.
  /// Must be cheap to call repeatedly (implementation caches).
  Future<Uint8List?> thumbnail(String id, {int size = 256});

  /// Encoded (JPEG) image suitable for full-screen display, longest side
  /// <= [maxSide]. Works for every format MediaStore can decode (HEIC etc).
  Future<Uint8List?> displayImage(String id, {int maxSide = 2048});

  /// The original file (may be copied to a cache on some devices).
  Future<File?> originalFile(String id);

  /// Emits whenever MediaStore reports that images changed.
  Stream<void> get changes;
}

/// Native share sheet etc. Implementation: `AndroidImageActions`.
abstract interface class ImageActions {
  Future<void> share(GalleryImage image);
}

/// On-device text recognition. Implementation: `MlKitOcrEngine`.
abstract interface class OcrEngine {
  /// Returns the recognised text and its line layout ([OcrResult.empty] if
  /// none). Throws [OcrException] on failure.
  Future<OcrResult> recognize(File imageFile);
  Future<void> dispose();
}

/// On-device face *presence* detection: how many faces an image contains.
/// No identity, landmarks, expressions or any other attribute is computed or
/// stored. Implementation: `MlKitFaceCounter`.
abstract interface class FaceCounter {
  /// Number of faces large enough to matter in a photo, or null when the
  /// image could not be analysed.
  Future<int?> countFaces(File imageFile);
  Future<void> dispose();
}

class OcrException implements Exception {
  OcrException(this.message);
  final String message;
  @override
  String toString() => 'OcrException: $message';
}

/// Joint image/text embedding model (MobileCLIP). Implementation: `MobileClipModel`.
abstract interface class SemanticModel {
  String get modelId;
  int get dimension;

  /// Loads model files. Returns false (never throws) if the model is
  /// missing or the device cannot run it; the app then works text-only.
  Future<bool> load();
  bool get isLoaded;

  /// [encodedImage] is a JPEG/PNG (e.g. a 256 px thumbnail). Returns an
  /// L2-normalised vector of length [dimension].
  Future<Float32List> embedImage(Uint8List encodedImage);

  /// Returns an L2-normalised vector of length [dimension].
  Future<Float32List> embedText(String text);
  Future<void> dispose();
}

/// Turns raw user text into a [ParsedQuery]. Implementation: `RuleBasedQueryParser`.
abstract interface class QueryParser {
  ParsedQuery parse(String raw, {DateTime? now});
}

/// Local persistent index (SQLite). Implementation: `SqliteIndexStore`.
abstract interface class IndexStore {
  Future<void> open();
  Future<void> close();

  /// id -> (modifiedAt millis, pipelineVersion) for every indexed image;
  /// used to compute incremental work.
  Future<Map<String, ({int modifiedAtMs, int pipelineVersion})>> indexedVersions();

  Future<void> upsert(IndexRecord record);
  Future<void> upsertAll(List<IndexRecord> records);
  Future<void> delete(Iterable<String> imageIds);

  Future<IndexRecord?> get(String imageId);
  Future<List<GalleryImage>> getImages(List<String> imageIds);

  /// Full-text search over OCR text and filenames. [terms] are matched as
  /// prefixes, [phrases] verbatim. Inputs are user text: the implementation
  /// must escape them (no raw FTS syntax passes through).
  Future<List<TextHit>> searchText({
    required List<String> terms,
    List<String> phrases = const [],
    SearchFilters filters = SearchFilters.none,
    int limit = 200,
  });

  /// Cosine similarity search over embeddings produced by [modelId].
  Future<List<VectorHit>> searchVector(
    Float32List query, {
    required String modelId,
    SearchFilters filters = SearchFilters.none,
    int limit = 200,
  });

  /// Structured screen info of indexed screenshots whose type is in [types]
  /// (all analysed screenshots when empty), restricted by [filters].
  /// Used by conversation search to match chat titles.
  Future<Map<String, ScreenInfo>> screenInfos({
    Set<ScreenType> types = const {},
    SearchFilters filters = SearchFilters.none,
  });

  /// Images matching only filters (e.g. "screenshots from last week"), newest first.
  Future<List<GalleryImage>> browse({SearchFilters filters = SearchFilters.none, int limit = 200});

  /// Ids of images whose perceptual hash is within [maxDistance] bits of [hash].
  Future<List<String>> nearDuplicates(int hash, {int maxDistance = 4});

  Future<IndexStats> stats();

  /// Deletes every indexed record and recent search (the "Delete index" action).
  Future<void> clearAll();

  Future<void> addRecentSearch(String query);
  Future<List<String>> recentSearches({int limit = 8});
  Future<void> clearRecentSearches();

  Future<String?> getSetting(String key);
  Future<void> setSetting(String key, String? value);
}

/// Orchestrates gallery scan -> OCR -> embedding -> store.
/// Implementation: `DefaultIndexingService`.
abstract interface class IndexingService {
  Stream<IndexingProgress> get progress;
  IndexingProgress get current;

  /// Incremental sync: index new/changed images, drop deleted ones.
  /// No-op if already running.
  Future<void> start();
  void pause();
  void resume();
  Future<void> stop();
}

/// Hybrid retrieval. Implementation: `HybridSearchEngine`.
abstract interface class SearchEngine {
  Future<SearchResponse> search(String query, {SearchFilters filters = SearchFilters.none});
}
