/// Dependency wiring: binds the domain interfaces to implementations.
///
/// OWNERSHIP: Team Lead. Feature code depends on these providers, never on
/// concrete implementation classes. Tests override them with fakes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/interfaces.dart';
import '../domain/models.dart';
import '../features/gallery/data/android_image_actions.dart';
import '../features/gallery/data/photo_manager_gallery_repository.dart';
import '../features/indexing/default_indexing_service.dart';
import '../features/search/data/hybrid_search_engine.dart';
import '../features/search/data/rule_based_query_parser.dart';
import '../ml/clip/mobile_clip_model.dart';
import '../ml/ocr/mlkit_ocr_engine.dart';

final galleryRepositoryProvider = Provider<GalleryRepository>(
  (ref) => PhotoManagerGalleryRepository(),
);

final imageActionsProvider = Provider<ImageActions>(
  (ref) => AndroidImageActions(ref.watch(galleryRepositoryProvider)),
);

/// Overridden in main() with an already-opened store (opening is async).
final indexStoreProvider = Provider<IndexStore>(
  (ref) => throw UnimplementedError('indexStoreProvider must be overridden with an opened store'),
);

final ocrEngineProvider = Provider<OcrEngine>((ref) {
  final engine = MlKitOcrEngine();
  ref.onDispose(engine.dispose);
  return engine;
});

/// One shared model instance: indexing embeds images, search embeds queries.
/// Loaded lazily by whichever needs it first; failure means text-only mode.
final semanticModelProvider = Provider<SemanticModel>((ref) {
  final model = MobileClipModel();
  ref.onDispose(model.dispose);
  return model;
});

final queryParserProvider = Provider<QueryParser>((ref) => RuleBasedQueryParser());

final indexingServiceProvider = Provider<IndexingService>((ref) {
  final service = DefaultIndexingService(
    gallery: ref.watch(galleryRepositoryProvider),
    store: ref.watch(indexStoreProvider),
    ocr: ref.watch(ocrEngineProvider),
    semantic: ref.watch(semanticModelProvider),
    // The store commits one transaction per batch; ~50 balances UI-isolate
    // blocking time against transaction overhead (docs/DATABASE.md).
    batchSize: 50,
  );
  ref.onDispose(service.dispose);
  return service;
});

final searchEngineProvider = Provider<SearchEngine>(
  (ref) => HybridSearchEngine(
    store: ref.watch(indexStoreProvider),
    parser: ref.watch(queryParserProvider),
    model: ref.watch(semanticModelProvider),
  ),
);

/// Live indexing progress for the UI.
final indexingProgressProvider = StreamProvider<IndexingProgress>((ref) async* {
  final service = ref.watch(indexingServiceProvider);
  yield service.current;
  yield* service.progress;
});

/// Index statistics; invalidate after indexing completes or the index is cleared.
final indexStatsProvider = FutureProvider<IndexStats>((ref) {
  return ref.watch(indexStoreProvider).stats();
});
