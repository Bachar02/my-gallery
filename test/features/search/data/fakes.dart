import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ai_gallery/domain/interfaces.dart';
import 'package:ai_gallery/domain/models.dart';

/// In-memory [IndexStore] with simple FTS-like semantics: terms match word
/// prefixes (OR), phrases must appear verbatim (AND), scores grow with the
/// number of occurrences (larger = better, like the real store's bm25).
class FakeIndexStore implements IndexStore {
  final Map<String, IndexRecord> records = {};
  final List<int> upsertAllSizes = [];
  final List<List<String>> deletes = [];
  final Map<String, String?> settings = {};
  final List<String> recent = [];
  int searchTextCalls = 0;
  int searchVectorCalls = 0;

  void put(IndexRecord r) => records[r.image.id] = r;

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();

  bool _passes(GalleryImage i, SearchFilters f) =>
      (f.dateRange == null || f.dateRange!.contains(i.createdAt)) && (f.kinds.isEmpty || f.kinds.contains(i.kind));

  @override
  Future<void> open() async {}

  @override
  Future<void> close() async {}

  @override
  Future<Map<String, ({int modifiedAtMs, int pipelineVersion})>> indexedVersions() async => {
        for (final r in records.values)
          r.image.id: (modifiedAtMs: r.image.modifiedAt.millisecondsSinceEpoch, pipelineVersion: r.pipelineVersion),
      };

  @override
  Future<void> upsert(IndexRecord record) async => put(record);

  @override
  Future<void> upsertAll(List<IndexRecord> list) async {
    upsertAllSizes.add(list.length);
    list.forEach(put);
  }

  @override
  Future<void> delete(Iterable<String> imageIds) async {
    deletes.add(imageIds.toList());
    imageIds.forEach(records.remove);
  }

  @override
  Future<IndexRecord?> get(String imageId) async => records[imageId];

  @override
  Future<List<GalleryImage>> getImages(List<String> imageIds) async =>
      [for (final id in imageIds) if (records[id] != null) records[id]!.image];

  @override
  Future<List<TextHit>> searchText({
    required List<String> terms,
    List<String> phrases = const [],
    SearchFilters filters = SearchFilters.none,
    int limit = 200,
  }) async {
    searchTextCalls++;
    final hits = <TextHit>[];
    for (final r in records.values) {
      if (!_passes(r.image, filters)) continue;
      final text = _norm('${r.ocrText} ${r.image.filename ?? ''}');
      final words = text.split(' ');
      if (!phrases.every((p) => ' $text '.contains(' ${_norm(p)} '))) continue;
      final matched = <String>[];
      var score = phrases.length.toDouble();
      for (final t in terms) {
        final n = words.where((w) => w.startsWith(_norm(t))).length;
        if (n > 0) {
          matched.add(t);
          score += n;
        }
      }
      if (terms.isNotEmpty && matched.isEmpty) continue;
      if (terms.isEmpty && phrases.isEmpty) continue;
      hits.add(TextHit(imageId: r.image.id, score: score, matchedTerms: matched, snippet: '[store snippet]'));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList();
  }

  @override
  Future<List<VectorHit>> searchVector(
    Float32List query, {
    required String modelId,
    SearchFilters filters = SearchFilters.none,
    int limit = 200,
  }) async {
    searchVectorCalls++;
    final hits = <VectorHit>[];
    for (final r in records.values) {
      final e = r.embedding;
      if (e == null || r.embeddingModel != modelId || !_passes(r.image, filters)) continue;
      var d = 0.0;
      for (var i = 0; i < e.length; i++) {
        d += e[i] * query[i];
      }
      hits.add(VectorHit(imageId: r.image.id, similarity: d));
    }
    hits.sort((a, b) => b.similarity.compareTo(a.similarity));
    return hits.take(limit).toList();
  }

  @override
  Future<Map<String, ScreenInfo>> screenInfos({
    Set<ScreenType> types = const {},
    SearchFilters filters = SearchFilters.none,
  }) async =>
      {
        for (final r in records.values)
          if (r.screen.type != ScreenType.unknown &&
              (types.isEmpty || types.contains(r.screen.type)) &&
              _passes(r.image, filters))
            r.image.id: r.screen,
      };

  @override
  Future<List<GalleryImage>> browse({SearchFilters filters = SearchFilters.none, int limit = 200}) async {
    final list = [for (final r in records.values) if (_passes(r.image, filters)) r.image]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list.take(limit).toList();
  }

  @override
  Future<List<String>> nearDuplicates(int hash, {int maxDistance = 4}) async => [
        for (final r in records.values)
          if (r.perceptualHash != null && _bits(r.perceptualHash! ^ hash) <= maxDistance) r.image.id,
      ];

  static int _bits(int x) {
    var c = 0;
    while (x != 0) {
      x &= x - 1;
      c++;
    }
    return c;
  }

  @override
  Future<IndexStats> stats() async => IndexStats(
        indexedImages: records.length,
        screenshots: records.values.where((r) => r.image.kind == ImageKind.screenshot).length,
        imagesWithText: records.values.where((r) => r.ocrText.isNotEmpty).length,
        imagesWithEmbedding: records.values.where((r) => r.embedding != null).length,
        databaseBytes: 0,
      );

  @override
  Future<void> clearAll() async => records.clear();

  @override
  Future<void> addRecentSearch(String query) async => recent.insert(0, query);

  @override
  Future<List<String>> recentSearches({int limit = 8}) async => recent.take(limit).toList();

  @override
  Future<void> clearRecentSearches() async => recent.clear();

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<void> setSetting(String key, String? value) async => settings[key] = value;
}

/// [SemanticModel] over a tiny embedding space. Text vectors are looked up by
/// the prompt with any "a photo of " / "a screenshot of " prefix removed;
/// image vectors by the encoded bytes interpreted as UTF-8 image ids.
class FakeSemanticModel implements SemanticModel {
  FakeSemanticModel({
    this.loadResult = true,
    Map<String, Float32List>? texts,
    Map<String, Float32List>? images,
    this.failImageIds = const {},
  })  : texts = texts ?? {},
        images = images ?? {};

  final bool loadResult;
  final Map<String, Float32List> texts;
  final Map<String, Float32List> images;
  final Set<String> failImageIds;
  final List<String> prompts = [];
  int loadCalls = 0;
  int imageCalls = 0;
  bool _loaded = false;

  @override
  String get modelId => 'fake_clip';

  @override
  int get dimension => 4;

  @override
  bool get isLoaded => _loaded;

  @override
  Future<bool> load() async {
    loadCalls++;
    _loaded = loadResult;
    return loadResult;
  }

  @override
  Future<Float32List> embedImage(Uint8List encodedImage) async {
    imageCalls++;
    final id = String.fromCharCodes(encodedImage);
    if (failImageIds.contains(id)) throw StateError('embed failed for $id');
    return images[id] ?? unit(0, 0);
  }

  @override
  Future<Float32List> embedText(String text) async {
    prompts.add(text);
    final key = text.replaceFirst(RegExp(r'^a (photo|screenshot) of '), '');
    return texts[key] ?? unit(3, 1);
  }

  @override
  Future<void> dispose() async {}
}

/// Unit vector in 4-D whose cosine with axis 0 is [cos] (rest on [axis]).
Float32List unit(double cos, [int axis = 1]) {
  final v = Float32List(4);
  v[0] = cos;
  v[axis == 0 ? 1 : axis] = math.sqrt(math.max(0, 1 - cos * cos));
  return v;
}

GalleryImage galleryImage(
  String id, {
  ImageKind kind = ImageKind.screenshot,
  DateTime? created,
  DateTime? modified,
  String? filename,
}) {
  final c = created ?? DateTime(2026, 11, 1, 12);
  return GalleryImage(
    id: id,
    width: 1080,
    height: 2400,
    createdAt: c,
    modifiedAt: modified ?? c,
    kind: kind,
    filename: filename ?? 'IMG_$id.jpg',
  );
}

IndexRecord record(
  GalleryImage image, {
  String text = '',
  Float32List? embedding,
  int? hash,
  int pipelineVersion = 11,
}) =>
    IndexRecord(
      image: image,
      ocrText: text,
      embedding: embedding,
      embeddingModel: embedding == null ? null : 'fake_clip',
      perceptualHash: hash,
      indexedAt: DateTime(2026, 11, 2),
      pipelineVersion: pipelineVersion,
    );

/// [GalleryRepository] backed by a list; thumbnails are the id's bytes.
class FakeGallery implements GalleryRepository {
  FakeGallery(this.images);

  List<GalleryImage> images;
  GalleryPermission permission = GalleryPermission.granted;
  final Set<String> noOriginal = {};
  final Set<String> unreadable = {};
  final StreamController<void> changesController = StreamController.broadcast();
  int listCalls = 0;

  /// Called before serving any per-image request (to simulate events mid-run).
  void Function(String id)? onAccess;

  bool get _granted => permission == GalleryPermission.granted || permission == GalleryPermission.limited;

  GalleryImage? _find(String id) {
    for (final i in images) {
      if (i.id == id) return i;
    }
    return null;
  }

  @override
  Future<GalleryPermission> permissionStatus() async => permission;

  @override
  Future<GalleryPermission> requestPermission() async => permission;

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<void> manageLimitedSelection() async {}

  @override
  Stream<List<GalleryImage>> listAllImages({int pageSize = 200}) async* {
    listCalls++;
    final all = List.of(images);
    for (var i = 0; i < all.length; i += 2) {
      yield all.sublist(i, math.min(i + 2, all.length));
    }
  }

  @override
  Future<int> countImages() async => images.length;

  @override
  Future<GalleryImage?> getImage(String id) async => _granted ? _find(id) : null;

  @override
  Future<Uint8List?> thumbnail(String id, {int size = 256}) async {
    onAccess?.call(id);
    if (!_granted || _find(id) == null || unreadable.contains(id)) return null;
    return Uint8List.fromList(id.codeUnits);
  }

  @override
  Future<Uint8List?> displayImage(String id, {int maxSide = 2048}) async {
    if (!_granted || _find(id) == null || unreadable.contains(id)) return null;
    return Uint8List.fromList('rendition:$id'.codeUnits);
  }

  @override
  Future<File?> originalFile(String id) async {
    onAccess?.call(id);
    if (!_granted || _find(id) == null || noOriginal.contains(id) || unreadable.contains(id)) return null;
    return File('/fake/original/$id.jpg');
  }

  @override
  Stream<void> get changes => changesController.stream;
}

/// OCR fake: text per image id (from the original path or the rendition
/// bytes written to a temp file).
class FakeOcr implements OcrEngine {
  FakeOcr(this.textById);

  final Map<String, String> textById;
  final Set<String> failIds = {};
  final List<String> calls = [];

  /// Completes before each recognition; lets tests block the pipeline.
  Future<void> Function(String id)? beforeRecognize;

  /// Optional layouts returned with the text, by image id.
  final Map<String, List<OcrLine>> linesById = {};

  @override
  Future<OcrResult> recognize(File imageFile) async {
    String id;
    if (imageFile.path.startsWith('/fake/original/')) {
      id = imageFile.uri.pathSegments.last.replaceAll('.jpg', '');
    } else {
      id = String.fromCharCodes(await imageFile.readAsBytes()).replaceFirst('rendition:', '');
    }
    calls.add(id);
    await beforeRecognize?.call(id);
    if (failIds.contains(id)) throw OcrException('cannot read $id');
    return OcrResult(text: textById[id] ?? '', lines: linesById[id] ?? const []);
  }

  @override
  Future<void> dispose() async {}
}
