import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/home/presentation/home_screen.dart';
import 'package:ai_gallery/features/search/presentation/search_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../core/fakes.dart';

const _stats = IndexStats(
  indexedImages: 1200,
  screenshots: 300,
  imagesWithText: 500,
  imagesWithEmbedding: 1200,
  databaseBytes: 4096,
);

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<TestEnv> pumpHome(WidgetTester tester, IndexingProgress progress, {TestEnv? env, double textScale = 1}) async {
  final e = env ?? TestEnv(store: FakeIndexStore(statsValue: _stats), indexing: FakeIndexingService(progress));
  await tester.pumpWidget(e.wrap(const HomeScreen(), textScale: textScale));
  await settle(tester);
  return e;
}

void main() {
  testWidgets('welcome, search bar and example queries', (tester) async {
    await pumpHome(tester, IndexingProgress.idle);
    expect(find.text('What are you looking for?'), findsOneWidget);
    expect(find.text('Describe the photo you’re looking for'), findsOneWidget);
    for (final q in exampleQueries) {
      expect(find.text(q), findsOneWidget);
    }
  });

  testWidgets('indexing state shows progress and pauses', (tester) async {
    final env = await pumpHome(tester, const IndexingProgress(phase: IndexingPhase.indexing, total: 400, processed: 100));
    expect(find.text('Preparing photos for search'), findsOneWidget);
    expect(find.textContaining('100 of 400'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(find.text('Pause'));
    expect(env.indexing.pauseCalls, 1);
  });

  testWidgets('paused state resumes', (tester) async {
    final env = await pumpHome(tester, const IndexingProgress(phase: IndexingPhase.paused, total: 4, processed: 1));
    await tester.tap(find.text('Resume'));
    expect(env.indexing.resumeCalls, 1);
  });

  testWidgets('live progress updates the card', (tester) async {
    final env = await pumpHome(tester, IndexingProgress.idle);
    env.indexing.emit(const IndexingProgress(phase: IndexingPhase.completed));
    await settle(tester);
    expect(find.text('1,200 photos ready to search'), findsOneWidget);
  });

  testWidgets('error state retries', (tester) async {
    final env = await pumpHome(
      tester,
      const IndexingProgress(phase: IndexingPhase.error, errorMessage: 'disk full'),
    );
    expect(find.text('Preparing photos stopped'), findsOneWidget);
    expect(find.text('disk full'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(env.indexing.startCalls, 1);
  });

  testWidgets('permission denied state asks for access', (tester) async {
    final env = TestEnv(
      store: FakeIndexStore(statsValue: _stats),
      indexing: FakeIndexingService(const IndexingProgress(phase: IndexingPhase.permissionDenied)),
    );
    await pumpHome(tester, IndexingProgress.idle, env: env);
    expect(find.text('Photo access needed'), findsOneWidget);
    await tester.tap(find.text('Allow access'));
    await settle(tester);
    expect(env.gallery.requestCalls, 1);
    expect(env.indexing.startCalls, 1);
  });

  testWidgets('recent searches are listed and clearable', (tester) async {
    final env = TestEnv(store: FakeIndexStore(recent: ['bank details', 'red car'], statsValue: _stats));
    await pumpHome(tester, IndexingProgress.idle, env: env);
    expect(find.text('bank details'), findsOneWidget);
    await tapVisible(tester, find.text('Clear'));
    await settle(tester);
    expect(find.text('red car'), findsNothing);
    expect(env.store.recent, isEmpty);
  });

  testWidgets('limited access banner opens the selection picker', (tester) async {
    final env = TestEnv(gallery: FakeGalleryRepository(permission: GalleryPermission.limited));
    await pumpHome(tester, IndexingProgress.idle, env: env);
    await tester.tap(find.text('Change selection'));
    await settle(tester);
    expect(env.gallery.manageLimitedCalls, 1);
    expect(env.indexing.startCalls, 1);
  });

  testWidgets('tapping an example opens search and runs it', (tester) async {
    final env = await pumpHome(tester, IndexingProgress.idle);
    await tapVisible(tester, find.text('Restaurant menu'));
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsOneWidget);
    expect(env.search.calls.single.$1, 'Restaurant menu');
  });

  testWidgets('fits at 200% text size on a small phone', (tester) async {
    tester.view.physicalSize = const Size(640, 1136);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final env = TestEnv(
      gallery: FakeGalleryRepository(permission: GalleryPermission.limited),
      store: FakeIndexStore(recent: ['a long recent search about a receipt'], statsValue: _stats),
      indexing: FakeIndexingService(const IndexingProgress(phase: IndexingPhase.indexing, total: 12000, processed: 4000)),
    );
    await pumpHome(tester, IndexingProgress.idle, env: env, textScale: 2);
    expect(tester.takeException(), isNull);
  });
}
