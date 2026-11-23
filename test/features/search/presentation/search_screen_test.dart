import 'package:ai_gallery/core/widgets/gallery_thumbnail.dart';
import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/search/presentation/date_presets.dart';
import 'package:ai_gallery/features/search/presentation/search_screen.dart';
import 'package:ai_gallery/features/viewer/presentation/viewer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../core/fakes.dart';

SearchResult result(String id, {ImageKind kind = ImageKind.screenshot}) => SearchResult(
      image: fakeImage(id, kind: kind),
      score: 1,
      reasons: const [
        MatchReason(signal: MatchSignal.textInImage, description: 'Contains the text “Jamie”', matchedTerms: ['jamie']),
      ],
    );

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> typeAndSearch(WidgetTester tester, String q) async {
  await tester.enterText(find.byType(TextField), q);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await settle(tester);
}

void main() {
  group('date presets', () {
    final now = DateTime(2025, 6, 4, 15); // Wednesday

    test('today and this week (Monday start)', () {
      final today = rangeForPreset(DatePreset.today, now)!;
      expect(today.start, DateTime(2025, 6, 4));
      expect(today.end, DateTime(2025, 6, 5));
      final week = rangeForPreset(DatePreset.thisWeek, now)!;
      expect(week.start, DateTime(2025, 6, 2));
      expect(week.end, DateTime(2025, 6, 9));
    });

    test('month, year and any time', () {
      expect(rangeForPreset(DatePreset.thisMonth, now)!.end, DateTime(2025, 7));
      expect(rangeForPreset(DatePreset.thisYear, now)!.start, DateTime(2025));
      expect(rangeForPreset(DatePreset.anyTime, now), isNull);
    });

    test('custom range end is exclusive and labelled', () {
      final r = customRange(DateTime(2025, 6, 1), DateTime(2025, 7, 3));
      expect(r.end, DateTime(2025, 7, 4));
      expect(r.contains(DateTime(2025, 7, 3, 23, 59)), isTrue);
      expect(r.label, 'Jun 1 – Jul 3, 2025');
    });
  });

  test('interpretation omits parts already set by filters', () {
    final q = parsed('screenshots summer', kind: ImageKind.screenshot,
        dateRange: DateRange(DateTime(2025, 6), DateTime(2025, 9), label: 'Summer 2025'));
    expect(interpretationOf(q, SearchFilters.none), 'Screenshots · Summer 2025');
    expect(interpretationOf(q, const SearchFilters(kinds: {ImageKind.photo})), 'Summer 2025');
    expect(interpretationOf(parsed('cat'), SearchFilters.none), isNull);
  });

  testWidgets('shows results, interpretation and records the search', (tester) async {
    final env = TestEnv(search: FakeSearchEngine(results: [result('1'), result('2'), result('3')]));
    env.search.parse = (q) => parsed(q,
        kind: ImageKind.screenshot,
        dateRange: DateRange(DateTime(2025, 6), DateTime(2025, 9), label: 'Summer 2025'));
    await tester.pumpWidget(env.wrap(const SearchScreen()));
    await settle(tester);
    expect(find.text('Describe what you remember'), findsOneWidget);

    await typeAndSearch(tester, 'screenshot with Jamie last summer');
    expect(find.byType(ResultTile), findsNWidgets(3));
    expect(find.text('Understood as Screenshots · Summer 2025'), findsOneWidget);
    expect(find.textContaining('3 matches'), findsOneWidget);
    expect(find.byType(TextOnlyNotice), findsNothing);
    expect(env.store.recent, ['screenshot with Jamie last summer']);
  });

  testWidgets('text-only notice when semantic search was not used', (tester) async {
    final env = TestEnv(search: FakeSearchEngine(results: [result('1')], semantic: false));
    await tester.pumpWidget(env.wrap(const SearchScreen()));
    await typeAndSearch(tester, 'menu');
    expect(find.byType(TextOnlyNotice), findsOneWidget);
  });

  testWidgets('empty results are honest and offer tips', (tester) async {
    final env = TestEnv(
      indexing: FakeIndexingService(const IndexingProgress(phase: IndexingPhase.indexing, total: 10, processed: 4)),
    );
    await tester.pumpWidget(env.wrap(const SearchScreen()));
    await typeAndSearch(tester, 'purple elephant');
    expect(find.text('No matching photos'), findsOneWidget);
    expect(find.textContaining('purple elephant'), findsWidgets);
    expect(find.textContaining('still being prepared'), findsOneWidget);
    expect(find.byType(ResultTile), findsNothing);
  });

  testWidgets('errors show retry which searches again', (tester) async {
    final env = TestEnv(search: FakeSearchEngine()..error = Exception('db'));
    await tester.pumpWidget(env.wrap(const SearchScreen()));
    await typeAndSearch(tester, 'receipt');
    expect(find.text('Search didn’t work'), findsOneWidget);

    env.search.error = null;
    env.search.results = [result('9')];
    await tester.tap(find.text('Try again'));
    await settle(tester);
    expect(find.byType(ResultTile), findsOneWidget);
    expect(env.search.calls, hasLength(2));
  });

  testWidgets('type and date filters are passed to the engine and can be cleared', (tester) async {
    final env = TestEnv();
    await tester.pumpWidget(env.wrap(const SearchScreen()));
    await typeAndSearch(tester, 'beach');

    await tester.tap(find.text('Photos'));
    await settle(tester);
    expect(env.search.calls.last.$2.kinds, {ImageKind.photo});

    await tester.tap(find.text('Any time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('This month'));
    await tester.pumpAndSettle();
    final filters = env.search.calls.last.$2;
    expect(filters.dateRange?.label, 'This month');
    expect(filters.kinds, {ImageKind.photo});
    expect(find.text('This month'), findsOneWidget); // chip label

    await tester.tap(find.text('Clear filters'));
    await settle(tester);
    expect(env.search.calls.last.$2.isEmpty, isTrue);
    // Filter changes don't add duplicate recent searches.
    expect(env.store.recent, ['beach']);
  });

  testWidgets('tapping a result opens the viewer', (tester) async {
    final env = TestEnv(
      gallery: FakeGalleryRepository(images: {'1': fakeImage('1')}),
      search: FakeSearchEngine(results: [result('1')]),
    );
    await tester.pumpWidget(env.wrap(const SearchScreen()));
    await typeAndSearch(tester, 'jamie');
    await tester.tap(find.byType(ResultTile));
    await tester.pumpAndSettle();
    expect(find.byType(ViewerScreen), findsOneWidget);
  });

  testWidgets('grid uses more columns on tablets and fits at 200% text', (tester) async {
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final env = TestEnv(search: FakeSearchEngine(results: [for (var i = 0; i < 8; i++) result('$i')]));
    await tester.pumpWidget(env.wrap(const SearchScreen(), textScale: 2));
    await typeAndSearch(tester, 'jamie');
    expect(tester.takeException(), isNull);
    final first = tester.getTopLeft(find.byType(ResultTile).at(0));
    final fourth = tester.getTopLeft(find.byType(ResultTile).at(3));
    expect(fourth.dy, first.dy, reason: '800dp wide → 4 columns in one row');
  });
}
