import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/settings/presentation/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../core/fakes.dart';

const _stats = IndexStats(
  indexedImages: 1500,
  screenshots: 420,
  imagesWithText: 610,
  imagesWithEmbedding: 1500,
  databaseBytes: 3 * 1024 * 1024,
);

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<TestEnv> pumpSettings(WidgetTester tester, {TestEnv? env}) async {
  final e = env ??
      TestEnv(
        store: FakeIndexStore(statsValue: _stats, recent: ['menu']),
        indexing: FakeIndexingService(const IndexingProgress(phase: IndexingPhase.completed)),
      );
  await tester.pumpWidget(e.wrap(const SettingsScreen()));
  await settle(tester);
  return e;
}

Future<void> openDeleteDialog(WidgetTester tester) async {
  await tapVisible(tester, find.text('Delete local index'));
  await tester.pumpAndSettle();
  expect(find.text('Delete local index?'), findsOneWidget);
}

void main() {
  testWidgets('shows permission, stats and privacy information', (tester) async {
    await pumpSettings(tester);
    expect(find.text('Full access'), findsOneWidget);
    expect(find.text('1,500'), findsWidgets);
    expect(find.text('420'), findsOneWidget);
    expect(find.text('610'), findsOneWidget);
    expect(find.text('3.0 MB'), findsOneWidget);
    await tester.ensureVisible(find.text('Nothing leaves your device'));
    expect(find.textContaining('no internet permission'), findsOneWidget);
  });

  testWidgets('re-scan starts indexing', (tester) async {
    final env = await pumpSettings(tester);
    await tapVisible(tester, find.text('Re-scan now'));
    await tester.pump();
    expect(env.indexing.startCalls, 1);
  });

  testWidgets('permanently denied offers system settings', (tester) async {
    final env = TestEnv(gallery: FakeGalleryRepository(permission: GalleryPermission.permanentlyDenied));
    await pumpSettings(tester, env: env);
    await tapVisible(tester, find.text('Open Settings'));
    await tester.pump();
    expect(env.gallery.openSettingsCalls, 1);
  });

  testWidgets('cancelling delete keeps the index', (tester) async {
    final env = await pumpSettings(tester);
    await openDeleteDialog(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(env.store.clearAllCalls, 0);
  });

  testWidgets('confirming delete stops indexing, clears, refreshes stats and offers re-index', (tester) async {
    final env = await pumpSettings(tester);
    final statsCallsBefore = env.store.statsCalls;
    await openDeleteDialog(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester);

    expect(env.indexing.stopCalls, 1);
    expect(env.store.clearAllCalls, 1);
    expect(env.store.statsCalls, greaterThan(statsCallsBefore));
    expect(find.text('Local index deleted'), findsOneWidget);
    // Durable: auto-indexing is disabled and the card says so (QA-20, QA-13).
    expect(env.store.settings['indexing.disabled'], '1');
    expect(find.text('Search index deleted'), findsOneWidget);
    expect(find.text('Up to date'), findsNothing);

    await tester.tap(find.text('Rebuild index').last);
    await settle(tester);
    expect(env.indexing.startCalls, 1);
    expect(env.store.settings.containsKey('indexing.disabled'), isFalse);
  });

  testWidgets('deleted index: card offers Rebuild index; Re-scan also re-enables', (tester) async {
    final env = TestEnv(
      store: FakeIndexStore()..settings['indexing.disabled'] = '1',
      indexing: FakeIndexingService(const IndexingProgress(phase: IndexingPhase.completed)),
    );
    await pumpSettings(tester, env: env);
    expect(find.text('Search index deleted'), findsOneWidget);
    await tapVisible(tester, find.text('Re-scan now'));
    await settle(tester);
    expect(env.indexing.startCalls, 1);
    expect(env.store.settings.containsKey('indexing.disabled'), isFalse);
  });

  testWidgets('delete removes the stale last-completed time', (tester) async {
    final env = await pumpSettings(tester);
    env.store.settings['indexing.lastCompletedAt'] = '123';
    await openDeleteDialog(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester);
    expect(env.store.settings.containsKey('indexing.lastCompletedAt'), isFalse);
  });

  testWidgets('delete failure is reported', (tester) async {
    final env = TestEnv(store: FakeIndexStore(statsValue: _stats)..clearAllError = Exception('locked'));
    await pumpSettings(tester, env: env);
    await openDeleteDialog(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester);
    expect(find.textContaining('Couldn’t delete the index'), findsOneWidget);
  });

  testWidgets('stats failure shows retry', (tester) async {
    final env = TestEnv(store: FakeIndexStore()..statsError = Exception('db'));
    await pumpSettings(tester, env: env);
    expect(find.text('Couldn’t load statistics'), findsOneWidget);
  });
}
