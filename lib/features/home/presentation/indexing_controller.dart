import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';

/// IndexStore setting: '1' after the user deleted the local index. While set,
/// nothing starts indexing automatically (app start, resume, gallery
/// changes) until the user chooses "Rebuild index" or "Re-scan now".
const indexingDisabledSettingKey = 'indexing.disabled';

/// Setting written by the indexing service; removed when the index is
/// deleted so the UI never shows an old "Updated …" time.
const indexingLastCompletedSettingKey = 'indexing.lastCompletedAt';

/// Whether automatic indexing is disabled because the index was deleted.
/// Read errors count as "not disabled" so a store problem can't block search.
final indexingDisabledProvider = FutureProvider<bool>((ref) async {
  try {
    return await ref.watch(indexStoreProvider).getSetting(indexingDisabledSettingKey) == '1';
  } catch (e) {
    debugPrint('Could not read indexing setting: ${e.runtimeType}');
    return false;
  }
}, retry: (_, _) => null);

/// UI-facing indexing commands. Failures are reported by the service through
/// its progress stream (phase = error); exceptions thrown directly by the
/// calls are caught here so a button press can never crash the app.
final indexingActionsProvider = Provider<IndexingActions>(IndexingActions.new);

class IndexingActions {
  IndexingActions(this._ref);
  final Ref _ref;

  /// Automatic start (permission granted, app resumed): skipped while the
  /// user has deleted the index.
  Future<void> autoStart() async {
    if (await _ref.read(indexingDisabledProvider.future)) return;
    await start();
  }

  /// Explicit user request ("Rebuild index", "Re-scan now"): re-enables
  /// automatic indexing, then starts.
  Future<void> rebuild() async {
    try {
      await _ref.read(indexStoreProvider).setSetting(indexingDisabledSettingKey, null);
    } catch (e) {
      debugPrint('Could not clear indexing setting: ${e.runtimeType}');
    }
    if (_ref.mounted) _ref.invalidate(indexingDisabledProvider);
    await start();
  }

  /// Starts an incremental sync (no-op if one is running). Refreshes stats
  /// when the run finishes.
  Future<void> start() async {
    try {
      await _ref.read(indexingServiceProvider).start();
    } catch (e) {
      debugPrint('Indexing start failed: ${e.runtimeType}');
    } finally {
      if (_ref.mounted) _ref.invalidate(indexStatsProvider);
    }
  }

  void pause() => _guard(() => _ref.read(indexingServiceProvider).pause());

  void resume() => _guard(() => _ref.read(indexingServiceProvider).resume());

  Future<void> stop() async {
    try {
      await _ref.read(indexingServiceProvider).stop();
    } catch (e) {
      debugPrint('Indexing stop failed: ${e.runtimeType}');
    }
  }

  void _guard(void Function() action) {
    try {
      action();
    } catch (e) {
      debugPrint('Indexing action failed: ${e.runtimeType}');
    }
  }
}
