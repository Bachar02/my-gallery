import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/indexing/screen_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Layout-level unit checks. Accuracy on real ML Kit output for 141
/// screenshots is measured by test/eval/real_corpus_eval_test.dart.
void main() {
  const analyzer = ScreenAnalyzer();
  GalleryImage shot({String name = 'Screenshot_20261102-184512.png'}) => GalleryImage(
        id: '1',
        filename: name,
        width: 1080,
        height: 2400,
        createdAt: DateTime(2026, 11, 2),
        modifiedAt: DateTime(2026, 11, 2),
        kind: ImageKind.screenshot,
      );
  OcrLine l(String t, double left, double top, double right, double bottom) => OcrLine(t, left, top, right, bottom);

  final statusBar = [l('18:42', 0.04, 0.012, 0.12, 0.03), l('87%', 0.86, 0.012, 0.95, 0.03)];

  test('chat: title from the header, body without header, input bar and times', () {
    final lines = [
      ...statusBar,
      l('Jamie', 0.2, 0.055, 0.34, 0.075),
      l('online', 0.2, 0.08, 0.3, 0.094),
      l('Are we still on for dinner?', 0.05, 0.2, 0.62, 0.215),
      l('18:40', 0.55, 0.22, 0.62, 0.23),
      l('Yes! 7:30 at the usual place', 0.38, 0.27, 0.95, 0.285),
      l('18:41 ✓✓', 0.85, 0.29, 0.95, 0.3),
      l('Perfect, see you there', 0.05, 0.34, 0.55, 0.355),
      l('Great', 0.8, 0.4, 0.95, 0.415),
      l('Message', 0.15, 0.9, 0.3, 0.915),
    ];
    final info = analyzer.analyze(shot(), lines);
    expect(info.type, ScreenType.chat);
    expect(info.chatTitle, 'Jamie');
    expect(info.isGroupChat, isFalse);
    expect(info.chatBody, isNot(contains('Message')));
    expect(info.chatBody, isNot(contains('online')));
    expect(info.chatBody, contains('Are we still on for dinner?'));
  });

  test('a chat that mentions restaurants and a menu stays a chat', () {
    final lines = [
      ...statusBar,
      l('Sam', 0.2, 0.055, 0.3, 0.075),
      l('last seen today at 10:41', 0.2, 0.08, 0.55, 0.094),
      l('The menu at that restaurant was great', 0.05, 0.2, 0.7, 0.215),
      l('Restaurants near the hotel are pricey', 0.3, 0.27, 0.95, 0.285),
      l('Hotels Restaurants Coffee', 0.05, 0.34, 0.6, 0.355),
      l('Message', 0.15, 0.9, 0.3, 0.915),
    ];
    final info = analyzer.analyze(shot(), lines);
    expect(info.type, ScreenType.chat);
    expect(info.chatTitle, 'Sam');
  });

  test('map: search bar and category chips', () {
    final lines = [
      ...statusBar,
      l('Search here', 0.15, 0.06, 0.5, 0.08),
      l('Restaurants', 0.05, 0.1, 0.3, 0.115),
      l('Hotels', 0.33, 0.1, 0.48, 0.115),
      l('Gas', 0.52, 0.1, 0.6, 0.115),
      l('Coffee', 0.63, 0.1, 0.8, 0.115),
      l('Trattoria Roma', 0.05, 0.7, 0.4, 0.715),
      l('4.5 ★ (812) · Italian restaurant · 1.2 km', 0.05, 0.72, 0.8, 0.735),
    ];
    expect(analyzer.analyze(shot(), lines).type, ScreenType.map);
  });

  test('group chat: members line under the title', () {
    final lines = [
      ...statusBar,
      l("Jamie's birthday", 0.2, 0.055, 0.5, 0.075),
      l('You, Jamie, Alex, Sam', 0.2, 0.08, 0.5, 0.094),
      l('Who brings the cake?', 0.05, 0.2, 0.5, 0.215),
      l('I will', 0.8, 0.27, 0.95, 0.285),
      l('Message', 0.15, 0.9, 0.3, 0.915),
    ];
    final info = analyzer.analyze(shot(), lines);
    expect(info.type, ScreenType.chat);
    expect(info.isGroupChat, isTrue);
  });

  test('app label from Samsung-style file names', () {
    expect(ScreenAnalyzer.sourceAppFromFilename('Screenshot_20261102_184512_Messages.jpg'), 'Messages');
    expect(ScreenAnalyzer.sourceAppFromFilename('Screenshot_20261102-184512_Google_Maps.jpg'), 'Google Maps');
    expect(ScreenAnalyzer.sourceAppFromFilename('Screenshot_20261102-184512.png'), isNull);
    expect(ScreenAnalyzer.sourceAppFromFilename('IMG_20261102_184512.jpg'), isNull);
  });

  test('photos are not analysed', () {
    final photo = GalleryImage(
      id: 'p',
      width: 4000,
      height: 3000,
      createdAt: DateTime(2026),
      modifiedAt: DateTime(2026),
      kind: ImageKind.photo,
    );
    expect(analyzer.analyze(photo, [l('MENU', 0.4, 0.1, 0.6, 0.2)]).type, ScreenType.unknown);
  });
}
