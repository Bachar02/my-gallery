import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../home/presentation/indexing_controller.dart';
import '../../home/presentation/recent_searches_controller.dart';

/// App version shown in About. Keep in sync with `version:` in pubspec.yaml.
const appVersion = '1.0.0';

/// State of the "Delete local index" operation.
final deleteIndexProvider = NotifierProvider.autoDispose<DeleteIndexController, AsyncValue<void>>(
  DeleteIndexController.new,
);

class DeleteIndexController extends Notifier<AsyncValue<void>> {
  @override
  AsyncValue<void> build() => const AsyncData(null);

  /// Stops indexing, deletes every indexed record and recent search, and
  /// refreshes dependent providers. Returns true on success.
  Future<bool> deleteIndex() async {
    state = const AsyncLoading();
    try {
      await ref.read(indexingActionsProvider).stop();
      await ref.read(indexStoreProvider).clearAll();
      if (!ref.mounted) return true;
      ref.invalidate(indexStatsProvider);
      ref.invalidate(recentSearchesProvider);
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      if (ref.mounted) state = AsyncError(e, st);
      return false;
    }
  }
}
