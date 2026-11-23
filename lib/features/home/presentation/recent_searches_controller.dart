import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';

/// Recent search queries (newest first) from the local index store.
final recentSearchesProvider = AsyncNotifierProvider<RecentSearchesController, List<String>>(
  RecentSearchesController.new,
  retry: (_, _) => null,
);

class RecentSearchesController extends AsyncNotifier<List<String>> {
  @override
  Future<List<String>> build() => ref.watch(indexStoreProvider).recentSearches();

  /// Records [query]; failures are non-fatal (search still works).
  Future<void> add(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    try {
      await ref.read(indexStoreProvider).addRecentSearch(q);
      if (!ref.mounted) return;
      state = AsyncData(await ref.read(indexStoreProvider).recentSearches());
    } catch (e) {
      debugPrint('Could not record recent search: $e');
    }
  }

  /// Throws on failure so the caller can tell the user.
  Future<void> clear() async {
    await ref.read(indexStoreProvider).clearRecentSearches();
    if (ref.mounted) state = const AsyncData([]);
  }
}
