import 'package:ai_gallery/core/widgets/highlighted_text.dart';
import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/viewer/presentation/viewer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../core/fakes.dart';

const _reasons = [
  MatchReason(
    signal: MatchSignal.textInImage,
    description: 'Contains the text “Jamie”',
    matchedTerms: ['jamie'],
    snippet: 'Hey Jamie, see you at 8',
    strength: 0.9,
  ),
  MatchReason(signal: MatchSignal.imageType, description: 'Is a screenshot'),
];

SearchResult _result(String id) =>
    SearchResult(image: fakeImage(id, kind: ImageKind.screenshot, filename: 'Screenshot_$id.png'), score: 1, reasons: _reasons);

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('shows why it matched with highlighted snippet, details and shares', (tester) async {
    final env = TestEnv(
      gallery: FakeGalleryRepository(images: {'a': fakeImage('a', kind: ImageKind.screenshot, filename: 'Screenshot_a.png')}),
    );
    await tester.pumpWidget(env.wrap(ViewerScreen(results: [_result('a')])));
    await settle(tester);

    expect(find.text('Why this matched'), findsOneWidget);
    expect(find.text('Contains the text “Jamie”'), findsOneWidget);
    expect(find.text('Strong match'), findsOneWidget);
    expect(find.byType(HighlightedText), findsOneWidget);
    expect(find.textContaining('Hey Jamie', findRichText: true), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);

    await tester.drag(find.text('Why this matched'), const Offset(0, -400));
    await settle(tester);
    expect(find.text('Screenshot_a.png'), findsOneWidget);
    expect(find.text('1080 × 2400'), findsOneWidget);

    await tester.tap(find.byTooltip('Share'));
    await settle(tester);
    expect(env.actions.shared.single.id, 'a');
  });

  testWidgets('missing image shows an explanation and disables share', (tester) async {
    final env = TestEnv(gallery: FakeGalleryRepository(images: {}));
    await tester.pumpWidget(env.wrap(ViewerScreen(results: [_result('gone')])));
    await settle(tester);

    expect(find.text('This photo is no longer available'), findsOneWidget);
    final share = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.share_outlined));
    expect(share.onPressed, isNull);
  });

  testWidgets('image that can no longer be decoded is treated as missing', (tester) async {
    final env = TestEnv(gallery: FakeGalleryRepository(images: {'a': fakeImage('a')}));
    env.gallery.undecodable.add('a');
    await tester.pumpWidget(env.wrap(ViewerScreen(results: [_result('a')])));
    await settle(tester);
    expect(find.text('This photo is no longer available'), findsOneWidget);
  });

  testWidgets('share failure shows a message', (tester) async {
    final env = TestEnv(gallery: FakeGalleryRepository(images: {'a': fakeImage('a')}));
    env.actions.error = Exception('no activity');
    await tester.pumpWidget(env.wrap(ViewerScreen(results: [_result('a')])));
    await settle(tester);
    await tester.tap(find.byTooltip('Share'));
    await settle(tester);
    expect(find.textContaining('Couldn’t open the share menu'), findsOneWidget);
  });

  testWidgets('swipes between results', (tester) async {
    final env = TestEnv(gallery: FakeGalleryRepository(images: {'a': fakeImage('a'), 'b': fakeImage('b')}));
    await tester.pumpWidget(env.wrap(ViewerScreen(results: [_result('a'), _result('b')])));
    await settle(tester);
    expect(find.text('1 of 2'), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(-600, 0), 2000);
    await tester.pumpAndSettle();
    expect(find.text('2 of 2'), findsOneWidget);
  });
}
