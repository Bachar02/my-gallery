import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';

/// UI-facing indexing commands. Failures are reported by the service through
/// its progress stream (phase = error); exceptions thrown directly by the
/// calls are caught here so a button press can never crash the app.
final indexingActionsProvider = Provider<IndexingActions>(IndexingActions.new);

class IndexingActions {
  IndexingActions(this._ref);
  final Ref _ref;

  /// Starts an incremental sync (no-op if one is running). Refreshes stats
  /// when the run finishes.
  Future<void> start() async {
    try {
      await _ref.read(indexingServiceProvider).start();
    } catch (e) {
      debugPrint('Indexing start failed: $e');
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
      debugPrint('Indexing stop failed: $e');
    }
  }

  void _guard(void Function() action) {
    try {
      action();
    } catch (e) {
      debugPrint('Indexing action failed: $e');
    }
  }
}
