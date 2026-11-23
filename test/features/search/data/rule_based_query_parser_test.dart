import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/search/data/rule_based_query_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Monday 23 November 2026, 15:30 local time.
  final now = DateTime(2026, 11, 23, 15, 30);
  final parser = RuleBasedQueryParser(clock: () => now);
  ParsedQuery parse(String q, {DateTime? at}) => parser.parse(q, now: at ?? now);

  void expectRange(DateRange? r, DateTime start, DateTime end, [String? label]) {
    expect(r, isNotNull);
    expect(r!.start, start, reason: 'start of ${r.label}');
    expect(r.end, end, reason: 'end of ${r.label}');
    if (label != null) expect(r.label, label);
  }

  group('example queries', () {
    test('screenshot of my conversation with Jamie', () {
      final q = parse('Find the screenshot of my conversation with Jamie');
      expect(q.kind, ImageKind.screenshot);
      expect(q.keywords, ['jamie']);
      expect(q.semanticText, 'conversation jamie');
      expect(q.dateRange, isNull);
      expect(q.phrases, isEmpty);
    });

    test('restaurant menu I took last summer', () {
      final q = parse('Show me the picture of the restaurant menu I took last summer');
      expect(q.kind, isNull, reason: '"picture" must not force photo kind');
      expect(q.keywords, ['restaurant', 'menu']);
      expect(q.semanticText, 'restaurant menu');
      expectRange(q.dateRange, DateTime(2026, 6), DateTime(2026, 9), 'Summer 2026');
    });

    test('someone sent me their bank details', () {
      final q = parse('Find the screenshot where someone sent me their bank details');
      expect(q.kind, ImageKind.screenshot);
      expect(q.keywords, ['bank', 'details']);
      expect(q.semanticText, 'bank details');
    });

    test('the red car', () {
      final q = parse('Show me the picture of the red car');
      expect(q.keywords, ['red', 'car']);
      expect(q.semanticText, 'red car');
      expect(q.kind, isNull);
      expect(q.dateRange, isNull);
    });

    test('conversation where we discussed our trip to Germany', () {
      final q = parse('Find the conversation where we discussed our trip to Germany');
      expect(q.keywords, ['trip', 'germany']);
      expect(q.semanticText, 'conversation trip germany');
      expect(q.kind, isNull);
    });

    test('filter-only query has no content', () {
      final q = parse('screenshots from last week');
      expect(q.kind, ImageKind.screenshot);
      expect(q.keywords, isEmpty);
      expect(q.semanticText, isEmpty);
      expect(q.hasContent, isFalse);
      expectRange(q.dateRange, DateTime(2026, 11, 16), DateTime(2026, 11, 23), 'Last week');
    });
  });

  group('keywords', () {
    test('lower-case, punctuation stripped, possessive removed, digits kept', () {
      final q = parse("Jamie's ADDRESS, flight #4521!");
      expect(q.keywords, ['jamie', 'address', 'flight', '4521']);
    });

    test('filler and stop words removed, duplicates collapsed', () {
      final q = parse('can you please show me the pic I sent to Alex about the wifi wifi password');
      expect(q.keywords, ['alex', 'wifi', 'password']);
    });

    test('single letters dropped, single digits kept', () {
      expect(parse('photo of x and 7').keywords, ['7']);
    });

    test('a bare picture word is not content', () {
      final q = parse('pictures');
      expect(q.hasContent, isFalse);
      expect(q.kind, isNull);
    });

    test('unicode letters are kept', () {
      expect(parse('Café Zoë in München').keywords, ['café', 'zoë', 'münchen']);
    });
  });

  group('phrases', () {
    test('straight and curly quotes become lower-case phrases', () {
      final q = parse('screenshot that says "Out for delivery!" and “Wifi  Password”');
      expect(q.phrases, ['out for delivery', 'wifi password']);
      expect(q.keywords, isEmpty);
      expect(q.hasContent, isTrue);
      expect(q.kind, ImageKind.screenshot);
    });

    test('words in phrases are not also keywords, words outside are', () {
      final q = parse('"see you friday" from Sam');
      expect(q.phrases, ['see you friday']);
      expect(q.keywords, ['sam']);
      expect(q.dateRange, isNull);
    });
  });

  group('kind', () {
    for (final s in ['screenshot', 'Screenshots', 'screen shot', 'screen-shots', 'screengrab', 'screencap']) {
      test('"$s" -> screenshot', () => expect(parse('the $s of the receipt').kind, ImageKind.screenshot));
    }
    for (final s in ['photo', 'picture', 'pic', 'image']) {
      test('"$s" does not set a kind', () => expect(parse('the $s of the receipt').kind, isNull));
    }
  });

  group('relative dates', () {
    test('today / yesterday / day before yesterday', () {
      expectRange(parse('photos from today').dateRange, DateTime(2026, 11, 23), DateTime(2026, 11, 24), 'Today');
      expectRange(parse('yesterday').dateRange, DateTime(2026, 11, 22), DateTime(2026, 11, 23), 'Yesterday');
      expectRange(parse('the day before yesterday').dateRange, DateTime(2026, 11, 21), DateTime(2026, 11, 22));
    });

    test('this week starts on Monday', () {
      expectRange(parse('this week').dateRange, DateTime(2026, 11, 23), DateTime(2026, 11, 30), 'This week');
      final sunday = DateTime(2026, 11, 29, 10);
      expectRange(parse('this week', at: sunday).dateRange, DateTime(2026, 11, 23), DateTime(2026, 11, 30));
      expectRange(parse('last week', at: sunday).dateRange, DateTime(2026, 11, 16), DateTime(2026, 11, 23));
    });

    test('this / last month and year', () {
      expectRange(parse('this month').dateRange, DateTime(2026, 11), DateTime(2026, 12), 'November 2026');
      expectRange(parse('last month').dateRange, DateTime(2026, 10), DateTime(2026, 11), 'October 2026');
      expectRange(parse('last month', at: DateTime(2026, 1, 5)).dateRange, DateTime(2025, 12), DateTime(2026, 1),
          'December 2025');
      expectRange(parse('this year').dateRange, DateTime(2026), DateTime(2027), '2026');
      expectRange(parse('last year').dateRange, DateTime(2025), DateTime(2026), '2025');
    });

    test('N units ago', () {
      expectRange(parse('3 days ago').dateRange, DateTime(2026, 11, 19), DateTime(2026, 11, 22), 'Around 3 days ago');
      expectRange(parse('a day ago').dateRange, DateTime(2026, 11, 22), DateTime(2026, 11, 23), 'Yesterday');
      expectRange(parse('two weeks ago').dateRange, DateTime(2026, 11, 6), DateTime(2026, 11, 13), 'About 2 weeks ago');
      expectRange(parse('2 months ago').dateRange, DateTime(2026, 9), DateTime(2026, 10), 'September 2026');
      expectRange(parse('a year ago').dateRange, DateTime(2025), DateTime(2026), '2025');
      expectRange(parse('a few days ago').dateRange, DateTime(2026, 11, 17), DateTime(2026, 11, 23), 'A few days ago');
    });

    test('last N days / past week', () {
      expectRange(parse('in the last 7 days').dateRange, DateTime(2026, 11, 17), DateTime(2026, 11, 24), 'Last 7 days');
      expectRange(parse('past week').dateRange, DateTime(2026, 11, 17), DateTime(2026, 11, 24), 'Past week');
      expectRange(parse('past 2 weeks').dateRange, DateTime(2026, 11, 10), DateTime(2026, 11, 24), 'Last 2 weeks');
    });

    test('last weekend / this weekend', () {
      // Monday: last weekend = Sat 21 - Mon 23.
      expectRange(parse('last weekend').dateRange, DateTime(2026, 11, 21), DateTime(2026, 11, 23), 'Last weekend');
      // On Sunday 22nd, "last weekend" is the previous one.
      final sunday = DateTime(2026, 11, 22, 12);
      expectRange(parse('last weekend', at: sunday).dateRange, DateTime(2026, 11, 14), DateTime(2026, 11, 16));
      expectRange(parse('this weekend', at: sunday).dateRange, DateTime(2026, 11, 21), DateTime(2026, 11, 23));
      final wednesday = DateTime(2026, 11, 25);
      expectRange(parse('last weekend', at: wednesday).dateRange, DateTime(2026, 11, 21), DateTime(2026, 11, 23));
    });

    test('last friday', () {
      expectRange(parse('last friday').dateRange, DateTime(2026, 11, 20), DateTime(2026, 11, 21), 'Last Friday');
      // On a Friday, "last friday" is a week ago.
      expectRange(parse('last friday', at: DateTime(2026, 11, 20, 9)).dateRange, DateTime(2026, 11, 13),
          DateTime(2026, 11, 14));
    });

    test('recently = last 30 days', () {
      expectRange(parse('recent screenshots').dateRange, DateTime(2026, 10, 25), DateTime(2026, 11, 24), 'Last 30 days');
      expect(parse('recent screenshots').hasContent, isFalse);
    });
  });

  group('seasons (northern hemisphere, meteorological)', () {
    test('last season = most recent completed one', () {
      expectRange(parse('last summer').dateRange, DateTime(2026, 6), DateTime(2026, 9), 'Summer 2026');
      expectRange(parse('last spring').dateRange, DateTime(2026, 3), DateTime(2026, 6), 'Spring 2026');
      // Autumn 2026 is still running on 23 Nov, so last autumn is 2025.
      expectRange(parse('last autumn').dateRange, DateTime(2025, 9), DateTime(2025, 12), 'Autumn 2025');
      expectRange(parse('last fall').dateRange, DateTime(2025, 9), DateTime(2025, 12));
      expectRange(parse('last winter').dateRange, DateTime(2025, 12), DateTime(2026, 3), 'Winter 2025–26');
    });

    test('last summer while it is summer means the previous year', () {
      expectRange(parse('last summer', at: DateTime(2026, 7, 15)).dateRange, DateTime(2025, 6), DateTime(2025, 9));
    });

    test('last winter in January skips the running winter', () {
      expectRange(parse('last winter', at: DateTime(2026, 1, 10)).dateRange, DateTime(2024, 12), DateTime(2025, 3));
      expectRange(parse('this winter', at: DateTime(2026, 1, 10)).dateRange, DateTime(2025, 12), DateTime(2026, 3));
    });

    test('season with year, and "in summer"', () {
      expectRange(parse('summer 2024').dateRange, DateTime(2024, 6), DateTime(2024, 9), 'Summer 2024');
      expectRange(parse('winter of 2024').dateRange, DateTime(2024, 12), DateTime(2025, 3), 'Winter 2024–25');
      expectRange(parse('beach photos in summer').dateRange, DateTime(2026, 6), DateTime(2026, 9));
      expectRange(parse('during the winter', at: DateTime(2026, 5, 1)).dateRange, DateTime(2025, 12), DateTime(2026, 3));
    });

    test('a bare season word is not a date (could be a name)', () {
      final q = parse('chat with Summer');
      expect(q.dateRange, isNull);
      expect(q.keywords, ['summer']);
    });
  });

  group('months and years', () {
    test('month without year = most recent occurrence', () {
      expectRange(parse('in March').dateRange, DateTime(2026, 3), DateTime(2026, 4), 'March 2026');
      expectRange(parse('photos from November').dateRange, DateTime(2026, 11), DateTime(2026, 12));
      expectRange(parse('in December').dateRange, DateTime(2025, 12), DateTime(2026, 1), 'December 2025');
      expectRange(parse('from may').dateRange, DateTime(2026, 5), DateTime(2026, 6), 'May 2026');
      expectRange(parse('receipt october').dateRange, DateTime(2026, 10), DateTime(2026, 11));
    });

    test('month with year', () {
      expectRange(parse('March 2024').dateRange, DateTime(2024, 3), DateTime(2024, 4), 'March 2024');
      expectRange(parse('sept, 2023').dateRange, DateTime(2023, 9), DateTime(2023, 10), 'September 2023');
      expectRange(parse('dec 2025 invoice').dateRange, DateTime(2025, 12), DateTime(2026, 1));
      expect(parse('dec 2025 invoice').keywords, ['invoice']);
    });

    test('last / this month name', () {
      expectRange(parse('last march').dateRange, DateTime(2026, 3), DateTime(2026, 4));
      expectRange(parse('last december').dateRange, DateTime(2025, 12), DateTime(2026, 1));
      expectRange(parse('last november').dateRange, DateTime(2025, 11), DateTime(2025, 12));
    });

    test('month words that are names or verbs stay keywords', () {
      for (final q in ['chat with June', 'message from Jan', 'may I see the receipt', 'the march poster']) {
        expect(parse(q).dateRange, isNull, reason: q);
      }
      expect(parse('chat with June').keywords, ['june']);
      expect(parse('message from Jan').keywords, ['jan']);
    });

    test('years', () {
      expectRange(parse('in 2023').dateRange, DateTime(2023), DateTime(2024), '2023');
      expectRange(parse('back in 2019').dateRange, DateTime(2019), DateTime(2020));
      expect(parse('code 2023').dateRange, isNull);
      expect(parse('code 2023').keywords, ['code', '2023']);
      expect(parse('in 2031').dateRange, isNull, reason: 'future year');
    });
  });

  test('deterministic and uses the injected clock when now is omitted', () {
    final a = parser.parse('screenshots from last week of the receipt');
    final b = parser.parse('screenshots from last week of the receipt');
    expect(a.keywords, b.keywords);
    expect(a.dateRange!.start, b.dateRange!.start);
    expect(a.dateRange!.start, DateTime(2026, 11, 16));
    expect(a.keywords, ['receipt']);
  });

  test('raw is preserved', () {
    expect(parse('  Red CAR ').raw, '  Red CAR ');
  });
}
