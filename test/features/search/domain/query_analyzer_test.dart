import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/search/data/rule_based_query_parser.dart';
import 'package:ai_gallery/features/search/domain/query_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final parser = RuleBasedQueryParser();
  const analyzer = QueryAnalyzer();
  final now = DateTime(2026, 11, 25, 12);
  QueryPlan plan(String q) => analyzer.analyze(q, parser.parse(q, now: now));

  group('phone regressions', () {
    test('"restaurant menu" is a visual query about a menu', () {
      final p = plan('restaurant menu');
      expect(p.intent, QueryIntent.visual);
      expect(p.head, 'menu');
      expect(p.modifiers, ['restaurant']);
      expect(p.visualPhrase, 'a restaurant menu');
    });

    test('"picture of a man" is a visual people query', () {
      final p = plan('picture of a man');
      expect(p.intent, QueryIntent.visual);
      expect(p.head, 'man');
      expect(p.peopleSubject, isTrue);
      expect(p.visualPhrase, 'a man');
      expect(p.headForms, containsAll(['man', 'men']));
    });

    test('"screenshot with Jamie" and "conversation with Jamie" are conversations', () {
      for (final q in ['screenshot with Jamie', 'conversation with Jamie', 'chat with Jamie', 'messages from Jamie',
          'what Jamie sent me']) {
        final p = plan(q);
        expect(p.intent, QueryIntent.conversation, reason: q);
        expect(p.person, 'jamie', reason: q);
        expect(p.textTerms, isEmpty, reason: q);
      }
    });
  });

  test('conversation topic words are kept as text terms', () {
    final p = plan('what did Priya say about the wifi');
    expect(p.intent, QueryIntent.conversation);
    expect(p.person, 'priya');
    expect(p.textTerms, ['wifi']);
  });

  test('text-in-image queries', () {
    for (final q in ['IBAN', 'Wi-Fi password', 'order number', 'bank details', 'tracking number', 'doctor appointment',
        'banana bread recipe', 'train ticket to Munich']) {
      expect(plan(q).intent, QueryIntent.text, reason: q);
    }
    expect(plan('"pinecone2026"').intent, QueryIntent.text);
  });

  test('visual queries and their head nouns', () {
    const cases = {
      'a red car': 'car',
      'beach at sunset': 'beach',
      'sunset over the sea': 'sunset',
      'a plate of food': 'plate',
      'snowy mountains': 'mountains',
      'someone playing guitar': 'guitar',
      'notes on a whiteboard': 'whiteboard',
      'my dog': 'dog',
      'photos of men': 'men',
    };
    cases.forEach((q, head) {
      final p = plan(q);
      expect(p.intent, QueryIntent.visual, reason: q);
      expect(p.head, head, reason: q);
    });
    expect(plan('sunset over the sea').visualPhrase, 'a sunset over the sea');
    expect(plan('a plate of food').visualPhrase, 'a plate of food');
  });

  test('hybrid: kind of screen plus content', () {
    final map = plan('screenshot of the map to the hotel');
    expect(map.intent, QueryIntent.hybrid);
    expect(map.screenType, ScreenType.map);
    expect(map.textTerms, ['hotel']);

    final settings = plan('wifi settings screenshot');
    expect(settings.intent, QueryIntent.hybrid);
    expect(settings.screenType, ScreenType.settings);
    expect(settings.textTerms, ['wifi']);

    final menu = plan('screenshot of a restaurant menu');
    expect(menu.intent, QueryIntent.hybrid);
    expect(menu.screenType, ScreenType.menu);

    final shop = plan("screenshot of men's jackets");
    expect(shop.intent, QueryIntent.hybrid);
    expect(shop.head, 'jackets');
  });

  test('dates are filters, not content', () {
    final p = plan('the menu I photographed last summer');
    expect(p.intent, QueryIntent.visual);
    expect(p.head, 'menu');
    expect(p.parsed.dateRange, isNotNull);
    expect(p.visualPhrase, 'the menu');
  });

  test('filter-only and empty queries', () {
    expect(plan('screenshots from last week').intent, QueryIntent.filterOnly);
    expect(plan('the of and with').intent, QueryIntent.empty);
  });
}
