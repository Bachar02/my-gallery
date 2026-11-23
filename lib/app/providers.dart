/// Dependency wiring: binds the domain interfaces to implementations.
///
/// OWNERSHIP: Team Lead. Feature code depends on these providers, never on
/// concrete implementation classes. Tests override them with fakes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/interfaces.dart';
import '../domain/models.dart';

final galleryRepositoryProvider = Provider<GalleryRepository>(
  (ref) => throw UnimplementedError('galleryRepositoryProvider not wired'),
);

final imageActionsProvider = Provider<ImageActions>(
  (ref) => throw UnimplementedError('imageActionsProvider not wired'),
);

/// Overridden in main() with an already-opened store.
final indexStoreProvider = Provider<IndexStore>(
  (ref) => throw UnimplementedError('indexStoreProvider must be overridden with an opened store'),
);

final ocrEngineProvider = Provider<OcrEngine>(
  (ref) => throw UnimplementedError('ocrEngineProvider not wired'),
);

final semanticModelProvider = Provider<SemanticModel>(
  (ref) => throw UnimplementedError('semanticModelProvider not wired'),
);

final queryParserProvider = Provider<QueryParser>(
  (ref) => throw UnimplementedError('queryParserProvider not wired'),
);

final indexingServiceProvider = Provider<IndexingService>(
  (ref) => throw UnimplementedError('indexingServiceProvider not wired'),
);

final searchEngineProvider = Provider<SearchEngine>(
  (ref) => throw UnimplementedError('searchEngineProvider not wired'),
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
