// QA: UI-level robustness (stale search responses, odd queries, the
// delete-index snackbar lifetime, privacy-safe logging).

import 'dart:async';

import 'package:ai_gallery/app/providers.dart';
import 'package:ai_gallery/domain/interfaces.dart';
import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/home/presentation/recent_searches_controller.dart';
import 'package:ai_gallery/features/search/presentation/search_controller.dart';
import 'package:ai_gallery/features/settings/presentation/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../core/fakes.dart';

/// Search engine whose responses complete only when the test says so.
class _ControlledEngine implements SearchEngine {
  final pending = <String, Completer<SearchResponse>>{};

  @override
  Future<SearchResponse> search(String query, {SearchFilters filters = SearchFilters.none}) {
    final c = Completer<SearchResponse>();
    pending[query] = c;
    return c.future;
  }

  void answer(String query, List<SearchResult> results) => pending[query]!.complete(SearchResponse(
        query: parsed(query),
        results: results,
        elapsed: Duration.zero,
        semanticSearchUsed: true,
      ));
}

SearchResult _result(String id) => SearchResult(
      image: GalleryImage(
        id: id,
        width: 10,
        height: 10,
        createdAt: DateTime(2026),
        modifiedAt: DateTime(2026),
        kind: ImageKind.photo,
      ),
      score: 1,
      reasons: const [],
    );

class _ThrowingRecentStore extends FakeIndexStore {
  @override
  Future<void> addRecentSearch(String query) async => throw SqliteException(
        extendedResultCode: 13,
        message: 'database or disk is full',
        causingStatement: 'INSERT INTO recent_searches (query_key, query, used_at) VALUES (?, ?, ?)',
        parametersToStatement: [query.toLowerCase(), query, 1],
      );
}

void main() {
  group('search controller', () {
    test('a slow earlier search never overwrites a newer one (stale responses)', () async {
      final engine = _ControlledEngine();
      final container = ProviderContainer(overrides: [
        searchEngineProvider.overrideWithValue(engine),
        indexStoreProvider.overrideWithValue(FakeIndexStore()),
      ]);
      addTearDown(container.dispose);
      final sub = container.listen(searchControllerProvider, (_, _) {});
      addTearDown(sub.close);
      final ctrl = container.read(searchControllerProvider.notifier);

      final first = ctrl.submit('old query');
      final second = ctrl.submit('new query');
      engine.answer('new query', [_result('new')]);
      await second;
      engine.answer('old query', [_result('old')]);
      await first;

      final s = container.read(searchControllerProvider);
      expect(s.status, SearchStatus.success);
      expect(s.query, 'new query');
      expect([for (final r in s.response!.results) r.image.id], ['new']);
    });

    test('many rapid searches: only the last response is shown', () async {
      final engine = _ControlledEngine();
      final container = ProviderContainer(overrides: [
        searchEngineProvider.overrideWithValue(engine),
        indexStoreProvider.overrideWithValue(FakeIndexStore()),
      ]);
      addTearDown(container.dispose);
      final sub = container.listen(searchControllerProvider, (_, _) {});
      addTearDown(sub.close);
      final ctrl = container.read(searchControllerProvider.notifier);
      final futures = [for (var i = 0; i < 20; i++) ctrl.submit('q$i')];
      // Answer in reverse order: the newest first, the oldest last.
      for (var i = 19; i >= 0; i--) {
        engine.answer('q$i', [_result('r$i')]);
      }
      await Future.wait(futures);
      final s = container.read(searchControllerProvider);
      expect(s.query, 'q19');
      expect(s.response!.results.single.image.id, 'r19');
    });

    test('blank / whitespace-only submit goes idle without calling the engine', () async {
      final env = TestEnv();
      final container = ProviderContainer(overrides: env.overrides);
      addTearDown(container.dispose);
      final sub = container.listen(searchControllerProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(searchControllerProvider.notifier).submit('   \n\t ');
      expect(container.read(searchControllerProvider).status, SearchStatus.idle);
      expect(env.search.calls, isEmpty);
    });

    test('recording a recent search that fails does not log the query text', () async {
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
      addTearDown(() => debugPrint = original);

      final container = ProviderContainer(overrides: [indexStoreProvider.overrideWithValue(_ThrowingRecentStore())]);
      addTearDown(container.dispose);
      await container.read(recentSearchesProvider.future);
      await container.read(recentSearchesProvider.notifier).add('IBAN of Jamie Doe');
      expect(logs, isNotEmpty);
      expect(logs.join('\n'), isNot(contains('Jamie')));
    });
  });

  group('settings', () {
    testWidgets('the "Local index deleted" snackbar goes away on its own', (tester) async {
      final env = TestEnv(
        store: FakeIndexStore(statsValue: const IndexStats(
            indexedImages: 3, screenshots: 1, imagesWithText: 1, imagesWithEmbedding: 3, databaseBytes: 1024)),
        indexing: FakeIndexingService(const IndexingProgress(phase: IndexingPhase.completed)),
      );
      await tester.pumpWidget(env.wrap(const SettingsScreen()));
      await tester.pump(const Duration(milliseconds: 200));
      await tapVisible(tester, find.text('Delete local index'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Local index deleted'), findsOneWidget);
      // Found on the device: the snackbar (it has an action, so it persisted
      // by default) was still shown minutes later on the viewer screen.
      // The messenger starts the timeout on the frame after the entrance
      // animation completes, so advance well past the 8 s duration.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 5));
      }
      await tester.pumpAndSettle();
      expect(find.text('Local index deleted'), findsNothing);
    });
  });
}
