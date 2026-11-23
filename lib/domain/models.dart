/// Shared domain models.
///
/// OWNERSHIP: Team Lead. These types are the contract between modules
/// (gallery, indexing, AI, database, UI). Do not change them without
/// updating docs/ARCHITECTURE.md and every implementation.
library;

import 'dart:typed_data';

/// What kind of image an item is. Screenshots are detected from MediaStore
/// metadata (relative path / filename), never guessed from pixels.
enum ImageKind { photo, screenshot }

/// An image visible to the app through Android MediaStore.
class GalleryImage {
  const GalleryImage({
    required this.id,
    required this.width,
    required this.height,
    required this.createdAt,
    required this.modifiedAt,
    required this.kind,
    this.filename,
    this.relativePath,
    this.mimeType,
  });

  /// MediaStore id (stable for the life of the file).
  final String id;
  final String? filename;

  /// e.g. `Pictures/Screenshots/`. May be null on very old devices.
  final String? relativePath;
  final String? mimeType;
  final int width;
  final int height;

  /// Date the picture was taken / created (DATE_TAKEN, falls back to DATE_ADDED).
  final DateTime createdAt;

  /// Last modification time, used for incremental re-indexing.
  final DateTime modifiedAt;
  final ImageKind kind;

  @override
  bool operator ==(Object other) =>
      other is GalleryImage && other.id == id && other.modifiedAt == modifiedAt;

  @override
  int get hashCode => Object.hash(id, modifiedAt);

  @override
  String toString() => 'GalleryImage($id, $filename, $kind)';
}

/// Everything the index knows about one image.
class IndexRecord {
  const IndexRecord({
    required this.image,
    required this.ocrText,
    required this.indexedAt,
    required this.pipelineVersion,
    this.embedding,
    this.embeddingModel,
    this.perceptualHash,
  });

  final GalleryImage image;

  /// Text recognised in the image ('' when none). Never null.
  final String ocrText;

  /// L2-normalised image embedding, or null when semantic model unavailable.
  final Float32List? embedding;

  /// Model id that produced [embedding], e.g. `mobileclip_s0`.
  final String? embeddingModel;

  /// 64-bit difference hash for near-duplicate detection.
  final int? perceptualHash;
  final DateTime indexedAt;

  /// Bumped when the indexing pipeline changes so old records get re-processed.
  final int pipelineVersion;
}

enum GalleryPermission {
  /// Full access to all images.
  granted,

  /// Android 14+ "selected photos only" access.
  limited,

  /// Not granted yet; can still ask.
  denied,

  /// Denied and the system will not show the dialog again; must use settings.
  permanentlyDenied,
}

enum IndexingPhase { idle, scanning, indexing, paused, completed, error, permissionDenied }

class IndexingProgress {
  const IndexingProgress({
    required this.phase,
    this.total = 0,
    this.processed = 0,
    this.failed = 0,
    this.errorMessage,
    this.lastCompletedAt,
  });

  static const idle = IndexingProgress(phase: IndexingPhase.idle);

  final IndexingPhase phase;

  /// Number of images that need processing in this run.
  final int total;
  final int processed;
  final int failed;
  final String? errorMessage;
  final DateTime? lastCompletedAt;

  double get fraction => total == 0 ? 0 : (processed / total).clamp(0, 1).toDouble();
  bool get isRunning => phase == IndexingPhase.scanning || phase == IndexingPhase.indexing;

  IndexingProgress copyWith({
    IndexingPhase? phase,
    int? total,
    int? processed,
    int? failed,
    String? errorMessage,
    DateTime? lastCompletedAt,
  }) =>
      IndexingProgress(
        phase: phase ?? this.phase,
        total: total ?? this.total,
        processed: processed ?? this.processed,
        failed: failed ?? this.failed,
        errorMessage: errorMessage ?? this.errorMessage,
        lastCompletedAt: lastCompletedAt ?? this.lastCompletedAt,
      );
}

class IndexStats {
  const IndexStats({
    required this.indexedImages,
    required this.screenshots,
    required this.imagesWithText,
    required this.imagesWithEmbedding,
    required this.databaseBytes,
    this.lastIndexedAt,
  });

  static const empty = IndexStats(
      indexedImages: 0, screenshots: 0, imagesWithText: 0, imagesWithEmbedding: 0, databaseBytes: 0);

  final int indexedImages;
  final int screenshots;
  final int imagesWithText;
  final int imagesWithEmbedding;
  final int databaseBytes;
  final DateTime? lastIndexedAt;
}

// ---------------------------------------------------------------- search

/// Inclusive start, exclusive end.
class DateRange {
  const DateRange(this.start, this.end, {required this.label});
  final DateTime start;
  final DateTime end;

  /// Human label shown to the user, e.g. "Summer 2025".
  final String label;

  bool contains(DateTime t) => !t.isBefore(start) && t.isBefore(end);

  @override
  String toString() => 'DateRange($label: $start – $end)';
}

/// A natural-language query decomposed into structured parts.
class ParsedQuery {
  const ParsedQuery({
    required this.raw,
    required this.semanticText,
    required this.keywords,
    this.phrases = const [],
    this.dateRange,
    this.kind,
  });

  final String raw;

  /// Query with filler ("find", "show me the picture of") and date/type
  /// phrases removed; used for the semantic (CLIP) text embedding.
  final String semanticText;

  /// Content words to look for in OCR text (lower-case, stop words removed).
  final List<String> keywords;

  /// Quoted phrases that must appear verbatim in OCR text.
  final List<String> phrases;
  final DateRange? dateRange;

  /// e.g. "screenshot" in the query restricts to screenshots.
  final ImageKind? kind;

  bool get hasContent => keywords.isNotEmpty || phrases.isNotEmpty || semanticText.trim().isNotEmpty;
}

/// Explicit filters chosen in the UI; they combine with (and override) what
/// the parser inferred from the query text.
class SearchFilters {
  const SearchFilters({this.dateRange, this.kinds = const {}});
  static const none = SearchFilters();
  final DateRange? dateRange;

  /// Empty = all kinds.
  final Set<ImageKind> kinds;

  bool get isEmpty => dateRange == null && kinds.isEmpty;
}

enum MatchSignal { textInImage, visualContent, date, imageType, filename }

/// One human-readable reason why an image matched. Shown in the viewer.
class MatchReason {
  const MatchReason({
    required this.signal,
    required this.description,
    this.matchedTerms = const [],
    this.snippet,
    this.strength,
  });

  final MatchSignal signal;

  /// e.g. 'Contains the text “Jamie”' or 'Looks like: red car'.
  final String description;
  final List<String> matchedTerms;

  /// Short excerpt of OCR text around the match, if any.
  final String? snippet;

  /// 0..1 confidence of this signal, when meaningful.
  final double? strength;
}

class SearchResult {
  const SearchResult({required this.image, required this.score, required this.reasons});
  final GalleryImage image;

  /// Final fused score (higher = better). Only comparable within one response.
  final double score;
  final List<MatchReason> reasons;
}

class SearchResponse {
  const SearchResponse({
    required this.query,
    required this.results,
    required this.elapsed,
    required this.semanticSearchUsed,
  });

  final ParsedQuery query;
  final List<SearchResult> results;
  final Duration elapsed;

  /// False when the visual model is not loaded / no embeddings exist, so the
  /// UI can say "text-only search".
  final bool semanticSearchUsed;
}

// ---------------------------------------------------- store query results

class TextHit {
  const TextHit({required this.imageId, required this.score, required this.matchedTerms, this.snippet});
  final String imageId;

  /// Higher = better (store converts bm25 so larger is better).
  final double score;
  final List<String> matchedTerms;
  final String? snippet;
}

class VectorHit {
  const VectorHit({required this.imageId, required this.similarity});
  final String imageId;

  /// Cosine similarity, -1..1.
  final double similarity;
}
