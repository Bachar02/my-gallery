import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/search/data/hybrid_search_engine.dart';
import 'package:ai_gallery/features/search/data/rule_based_query_parser.dart';
import 'package:ai_gallery/features/search/domain/search_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  final now = DateTime(2026, 11, 23, 15);
  late FakeIndexStore store;
  late FakeSemanticModel model;

  HybridSearchEngine engine({FakeSemanticModel? m}) => HybridSearchEngine(
        store: store,
        parser: RuleBasedQueryParser(),
        model: m ?? model,
        clock: () => now,
      );

  List<String> ids(SearchResponse r) => [for (final x in r.results) x.image.id];
  Iterable<String> descriptions(SearchResult r) => r.reasons.map((x) => x.description);

  setUp(() {
    store = FakeIndexStore();
    model = FakeSemanticModel(loadResult: false);
  });

  group('text retrieval', () {
    test('conversation: the chat title names the person; body-only mentions are a separate group', () async {
      store
        ..put(record(galleryImage('chat'), text: 'Jamie\nHey! Are we still on for Berlin?\nYes, flight lands 10:40',
            screen: chat('Jamie', body: 'Hey! Are we still on for Berlin?\nYes, flight lands 10:40')))
        ..put(record(galleryImage('mention'), text: 'Alex\nAsk Jamie for the keys',
            screen: chat('Alex', body: 'Ask Jamie for the keys')))
        ..put(record(galleryImage('jamieson'), text: 'Jamieson Plumbing\nAppointment confirmed',
            screen: chat('Jamieson Plumbing', body: 'Appointment confirmed')))
        ..put(record(galleryImage('notes'), text: 'Meeting notes\nQ3 roadmap'))
        ..put(record(galleryImage('photo', kind: ImageKind.photo), text: 'Jamie'));

      final r = await engine().search('Find the screenshot of my conversation with Jamie');

      expect([for (final x in r.primary) x.image.id], ['chat']);
      expect([for (final x in r.mentions) x.image.id], ['mention']);
      expect(r.intent, SearchIntent.conversation);
      expect(r.mentionsLabel, 'Mentions Jamie');
      expect(r.semanticSearchUsed, isFalse);
      final primary = r.primary.single.reasons.firstWhere((x) => x.signal == MatchSignal.conversation);
      expect(primary.description, 'Conversation with “Jamie”');
      expect(r.mentions.single.reasons.first.description, 'Mentions “Jamie” in a chat with “Alex”');
      expect(r.mentions.single.reasons.first.snippet, contains('Jamie'));
      expect(descriptions(r.primary.single), contains('Screenshot'));
      // Never claims to recognise a person.
      for (final res in r.results) {
        for (final d in descriptions(res)) {
          expect(d.toLowerCase(), isNot(contains('person')));
          expect(d.toLowerCase(), isNot(contains('face')));
        }
      }
      expect(r.query.kind, ImageKind.screenshot);
    });

    test('conversation topic words must appear in the messages', () async {
      store
        ..put(record(galleryImage('wifi'), text: 'Priya\nnetwork CabinNet, password pinecone2026',
            screen: chat('Priya', body: 'network CabinNet, password pinecone2026')))
        ..put(record(galleryImage('other'), text: 'Priya\nSee you tomorrow', screen: chat('Priya', body: 'See you tomorrow')));
      final r = await engine().search('what did Priya say about the wifi');
      expect([for (final x in r.primary) x.image.id], ['wifi'], reason: 'password is related to wifi');
    });

    test('group chats named after the person are mentions, not the conversation', () async {
      store.put(record(galleryImage('group'), text: "Jamie's birthday\nYou, Jamie, Alex",
          screen: chat("Jamie's birthday", body: 'Who brings the cake?', group: true)));
      final r = await engine().search('chat with Jamie');
      expect(r.primary, isEmpty);
      expect([for (final x in r.mentions) x.image.id], ['group']);
      expect(r.mentions.single.reasons.first.description, 'Group chat “Jamie\'s birthday”');
    });

    test('intent expansion: literal matches outrank expansion matches, reasons say why', () async {
      store
        ..put(record(galleryImage('literal'), text: 'Bank details\nIBAN DE89 3704 0044 0532 0130 00\nBIC COBADEFFXXX'))
        ..put(record(galleryImage('iban'), text: 'Please pay to\nIBAN: GB33BUKB20201555555555'))
        ..put(record(galleryImage('swift'), text: 'Wire transfer\nSWIFT code: BUKBGB22'))
        ..put(record(galleryImage('noise'), text: 'Weather forecast sunny'));
      for (var i = 0; i < 6; i++) {
        store.put(record(galleryImage('order$i'), text: 'Order details #$i shipped'));
      }

      final r = await engine().search('Find the screenshot where someone sent me their bank details');

      expect(ids(r).first, 'literal');
      expect(ids(r), containsAll(['iban', 'swift']));
      expect(ids(r), isNot(contains('noise')));
      final ibanIndex = ids(r).indexOf('iban');
      for (final id in ids(r).where((id) => id.startsWith('order'))) {
        expect(ids(r).indexOf(id), greaterThan(ibanIndex), reason: '"details" alone is weaker than IBAN');
      }
      final ibanResult = r.results[ibanIndex];
      expect(descriptions(ibanResult), contains('Mentions “iban” (related to “bank details”)'));
      expect(r.results.first.score, greaterThan(ibanResult.score));
    });

    test('prefix-only matches are not evidence; plurals are', () async {
      store
        ..put(record(galleryImage('receiptless'), text: 'Receiptless returns policy'))
        ..put(record(galleryImage('receipts'), text: 'All receipts for March'));
      final r = await engine().search('receipt');
      expect(ids(r), ['receipts']);
    });

    test('accent-insensitive verification', () async {
      store.put(record(galleryImage('cafe'), text: 'Café de Flore — menu'));
      // The fake store is accent-sensitive, so search the accented form;
      // verification must still accept it as an exact word.
      final r = await engine().search('café');
      expect(ids(r), ['cafe']);
    });

    test('quoted phrases are required', () async {
      store
        ..put(record(galleryImage('a'), text: 'Your parcel is out for delivery today'))
        ..put(record(galleryImage('b'), text: 'Delivery scheduled; we are out of stock'));
      final r = await engine().search('screenshot that says "out for delivery"');
      expect(ids(r), ['a']);
      expect(r.query.phrases, ['out for delivery']);
    });

    test('file name matches get their own reason', () async {
      store.put(record(galleryImage('x', filename: 'boarding_pass_LH123.png'), text: ''));
      final r = await engine().search('boarding pass');
      expect(ids(r), ['x']);
      expect(r.results.single.reasons.any((x) => x.signal == MatchSignal.filename), isTrue);
    });

    test('partial coverage: best partial matches stay, much weaker ones are cut', () async {
      store
        ..put(record(galleryImage('both'), text: 'Our trip to Germany: flights booked'))
        ..put(record(galleryImage('germany'), text: 'Germany travel guide'));
      for (var i = 0; i < 10; i++) {
        store.put(record(galleryImage('trip$i'), text: 'Trip summary $i'));
      }
      final r = await engine().search('our trip to Germany');
      expect(ids(r).first, 'both');
      expect(ids(r), contains('germany'));
      expect(ids(r).where((id) => id.startsWith('trip')), isEmpty);
    });
  });

  group('no evidence, no results', () {
    test('nothing matching returns an empty list, not the least bad images', () async {
      model = FakeSemanticModel(texts: {'purple elephant': unit(1, 1)});
      for (var i = 0; i < 5; i++) {
        store.put(record(galleryImage('p$i', kind: ImageKind.photo), text: 'random', embedding: unit(0.10 + i * 0.01)));
      }
      final r = await engine().search('purple elephant');
      expect(r.results, isEmpty);
      expect(r.semanticSearchUsed, isTrue);
    });

    test('empty query and no filters returns nothing', () async {
      store.put(record(galleryImage('a'), text: 'hello'));
      final r = await engine().search('show me the pictures');
      expect(r.results, isEmpty);
    });
  });

  group('visual retrieval', () {
    setUp(() {
      model = FakeSemanticModel(texts: {'red car': unit(1, 1)});
      const sims = {'v30': 0.30, 'v27': 0.27, 'v24': 0.24, 'v21': 0.21, 'v15': 0.15};
      sims.forEach((id, s) {
        store.put(record(galleryImage(id, kind: ImageKind.photo), embedding: unit(s, 2)));
      });
    });

    test('absolute floor and margin to the best hit', () async {
      final r = await engine().search('Show me the picture of the red car');
      expect(r.semanticSearchUsed, isTrue);
      expect(model.prompts.single, 'a photo of the red car.');
      // best 0.30 -> keep >= max(floor, 0.30 - margin)
      final cut = [SearchTuning.visualFloor, 0.30 - SearchTuning.visualMargin].reduce((a, b) => a > b ? a : b);
      final expected = ['v30', 'v27', 'v24', 'v21'].where((id) => int.parse(id.substring(1)) / 100 >= cut - 1e-9);
      expect(ids(r), expected.toList());
      final reason = r.results.first.reasons.single;
      expect(reason.signal, MatchSignal.visualContent);
      expect(reason.description, 'Looks like “the red car”');
      expect(reason.strength, greaterThan(0));
      expect(r.results.first.score, greaterThan(r.results.last.score));
    });

    test('text and visual agreement ranks above either alone', () async {
      store.put(record(galleryImage('both', kind: ImageKind.photo), text: 'Red car rally 2026', embedding: unit(0.28, 2)));
      final r = await engine().search('red car');
      expect(ids(r).first, 'both');
      final signals = r.results.first.reasons.map((x) => x.signal).toSet();
      expect(signals, containsAll([MatchSignal.textInImage, MatchSignal.visualContent]));
    });

    test('screenshot filter uses a screenshot prompt', () async {
      await engine().search('screenshot of a red car');
      expect(model.prompts.single, 'a screenshot of a red car.');
    });

    test('model that fails to load degrades to text-only', () async {
      final r = await engine(m: FakeSemanticModel(loadResult: false)).search('red car');
      expect(r.semanticSearchUsed, isFalse);
      expect(r.results, isEmpty);
    });

    test('no embeddings in the store: the model is not even asked', () async {
      store.records.clear();
      store.put(record(galleryImage('t'), text: 'red car'));
      final r = await engine().search('red car');
      expect(r.semanticSearchUsed, isFalse);
      expect(model.prompts, isEmpty);
      expect(ids(r), ['t']);
    });
  });

  group('filters', () {
    test('filter-only query browses newest first with reasons', () async {
      store
        ..put(record(galleryImage('old', created: DateTime(2026, 11, 1))))
        ..put(record(galleryImage('a', created: DateTime(2026, 11, 17, 9))))
        ..put(record(galleryImage('b', created: DateTime(2026, 11, 20, 9))))
        ..put(record(galleryImage('photo', kind: ImageKind.photo, created: DateTime(2026, 11, 18))));
      final r = await engine().search('screenshots from last week');
      expect(ids(r), ['b', 'a']);
      expect(descriptions(r.results.first), containsAll(['Taken last week', 'Screenshot']));
      expect(store.searchTextCalls, 0);
    });

    test('UI filters override parsed ones', () async {
      store
        ..put(record(galleryImage('nov', created: DateTime(2026, 11, 20)), text: 'receipt total'))
        ..put(record(galleryImage('mar', kind: ImageKind.photo, created: DateTime(2026, 3, 5)), text: 'receipt total'));
      final ui = SearchFilters(
        dateRange: DateRange(DateTime(2026, 3), DateTime(2026, 4), label: 'March 2026'),
        kinds: const {ImageKind.photo},
      );
      final r = await engine().search('screenshot of the receipt from last week', filters: ui);
      expect(ids(r), ['mar']);
      expect(r.query.dateRange!.label, 'March 2026');
      expect(r.query.kind, ImageKind.photo);
      expect(descriptions(r.results.single), contains('Taken in March 2026'));
    });
  });

  group('near-duplicates', () {
    test('bursts collapse to the best shot', () async {
      final t = DateTime(2026, 11, 10, 12);
      store
        ..put(record(galleryImage('b1', created: t), text: 'menu specials menu', hash: 0x0F0F))
        ..put(record(galleryImage('b2', created: t.add(const Duration(seconds: 4))), text: 'menu specials', hash: 0x0F0E))
        ..put(record(galleryImage('far', created: t.add(const Duration(days: 3))), text: 'menu', hash: 0x0F0F));
      final r = await engine().search('menu');
      expect(ids(r), ['b1', 'far'], reason: 'same hash but days apart and different text: kept');
    });

    test('same screenshot saved twice (identical text) collapses regardless of time', () async {
      store
        ..put(record(galleryImage('s1', created: DateTime(2026, 1, 1)), text: 'Wifi password: hunter2', hash: 99))
        ..put(record(galleryImage('s2', created: DateTime(2026, 6, 1)), text: 'WiFi password:  hunter2', hash: 99));
      final r = await engine().search('wifi password');
      expect(r.results.length, 1);
    });

    test('isNearDuplicate needs both hashes', () {
      final a = record(galleryImage('a'), hash: 1);
      final b = record(galleryImage('b'));
      expect(HybridSearchEngine.isNearDuplicate(a, b), isFalse);
    });
  });

  group('end-to-end fixture gallery (tool/fixtures/make_fixtures.py)', () {
    // Desktop MobileCLIP cosines of the fixture screenshots for the prompts
    // "a screenshot of bank details" (a) and "a screenshot of conversation" (b).
    Float32List vec(double a, double b) {
      final v = Float32List(4);
      v[0] = a;
      v[3] = b;
      v[1] = math.sqrt(1 - a * a - b * b);
      return v;
    }

    const jamieText = '12:41\nJ Jamie\nonline\nAre we still on for dinner on Friday?\nYes! 7:30 at the usual place\n'
        "Perfect, I'll book a table for four\nGreat, see you then Jamie\nMessage";
    const samText = '12:41\nS Sam\nonline\nSo for our trip to Germany, Berlin first or Munich?\n'
        'Berlin first, then the train to Munich on Thursday\nI found flights for 89 euros each\n'
        "Book them! Can't wait for the trip\nMessage";
    const alexText = '12:41\nA Alex\nonline\nCan you send me the details for the rent?\nSure, here are my bank details:\n'
        'IBAN: DE89 3704 0044 0532 0130 00 BIC: COBADEFFXXX Account holder: Alex Morgan\nThanks, transferring now\nMessage';
    const receiptText = 'CORNER MARKET\nMilk 1.29\nBread 2.49\nCoffee beans 8.99\nTOTAL 12.77\nCard payment';

    setUp(() {
      model = FakeSemanticModel(texts: {
        'bank details': Float32List.fromList([1, 0, 0, 0]),
        'conversation': Float32List.fromList([0, 0, 0, 1]),
      });
      store
        ..put(record(galleryImage('jamie', created: DateTime(2026, 11, 2)), text: jamieText, embedding: vec(0.197, 0.233),
            screen: chat('Jamie', body: jamieText)))
        ..put(record(galleryImage('sam', created: DateTime(2026, 10, 15)), text: samText, embedding: vec(0.221, 0.208),
            screen: chat('Sam', body: samText)))
        ..put(record(galleryImage('alex', created: DateTime(2026, 10, 20)), text: alexText, embedding: vec(0.264, 0.210),
            screen: chat('Alex', body: alexText)))
        ..put(record(galleryImage('receipt', created: DateTime(2026, 11, 1)), text: receiptText,
            embedding: vec(0.230, 0.189)));
    });

    test('conversation with Jamie: matched from the chat title, never visually', () async {
      final r = await engine().search('Find the screenshot of my conversation with Jamie');
      expect([for (final x in r.primary) x.image.id], ['jamie']);
      expect(model.prompts, isEmpty, reason: 'the image model is not asked about people');
      expect(descriptions(r.primary.single), contains('Conversation with “Jamie”'));
    });

    test('a name that appears in no image gives an empty result', () async {
      final r = await engine().search('chat with Priya');
      expect(r.results, isEmpty);
    });

    test('a name only as a prefix of a longer word is not evidence', () async {
      store.put(record(galleryImage('jamieson'), text: 'Jamieson Ltd invoice', embedding: vec(0.1, 0.3)));
      final r = await engine().search('messages from jamie');
      expect(ids(r), ['jamie']);
    });

    test('bank details: strong text evidence keeps borderline visual-only chats out', () async {
      final r = await engine().search('Find the screenshot where someone sent me their bank details');
      // sam (0.221) and receipt (0.230) pass the 0.20 floor and the 0.07 margin
      // to alex (0.264), but alex covers "bank details" in its text.
      expect(ids(r), ['alex']);
      expect(descriptions(r.results.single), contains('Contains the text “bank” and “details”'));
    });

    test('QA-06: text-centric intent with no text evidence drops borderline visual-only images', () async {
      store.records.remove('alex');
      final r = await engine().search('Find the screenshot where someone sent me their bank details');
      // receipt (0.230) and sam (0.221) pass the plain floor and margin, but
      // "bank details" is defined by its text and no image has any.
      expect(r.results, isEmpty);
    });

    test('QA-06: a clearly similar image is still shown for a text-centric intent', () async {
      store.records.remove('alex');
      store.put(record(galleryImage('bankapp'), text: '', embedding: vec(0.31, 0.1)));
      final r = await engine().search('bank details');
      expect(ids(r), ['bankapp']);
    });

    test('trip to Germany finds the Sam chat (chat screens with the topic, no false person)', () async {
      final r = await engine().search('Find the conversation where we discussed our trip to Germany');
      expect(r.intent, SearchIntent.hybrid);
      expect(ids(r), ['sam']);
    });
  });

  group('QA fixes', () {
    test('QA-06: Wi-Fi password with no Wi-Fi screenshot returns nothing', () async {
      model = FakeSemanticModel(texts: {'wi fi password': unit(1, 1), 'wifi password': unit(1, 1)});
      store
        ..put(record(galleryImage('chat'), text: 'See you at the station', embedding: unit(0.22, 2)))
        ..put(record(galleryImage('plain', kind: ImageKind.photo), embedding: unit(0.21, 2)));
      final r = await engine().search('Wi-Fi password');
      expect(r.results, isEmpty);
    });

    test('QA-06: non-intent visual queries keep the normal floor', () async {
      model = FakeSemanticModel(texts: {'red car': unit(1, 1)});
      store.put(record(galleryImage('car', kind: ImageKind.photo), embedding: unit(0.22, 2)));
      final r = await engine().search('red car');
      expect(ids(r), ['car']);
    });

    test('QA-12: semanticSearchUsed reports availability, also for filter-only and stop-word queries', () async {
      model = FakeSemanticModel();
      store.put(record(galleryImage('a', created: DateTime(2026, 11, 18)), embedding: unit(0.5)));
      expect((await engine().search('screenshots from last week')).semanticSearchUsed, isTrue);
      expect((await engine().search('the of and with')).semanticSearchUsed, isTrue);
      expect((await engine(m: FakeSemanticModel(loadResult: false)).search('the of and with')).semanticSearchUsed,
          isFalse);
      store.records.clear();
      store.put(record(galleryImage('b'), text: 'hello'));
      expect((await engine().search('hello')).semanticSearchUsed, isFalse, reason: 'no embeddings');
    });

    test('QA-14: a pasted page issues a bounded number of index queries', () async {
      store.put(record(galleryImage('a'), text: 'word1 word2'));
      final long = List.generate(1000, (i) => 'word$i').join(' ');
      final r = await engine().search(long);
      expect(r.query.keywords.length, lessThanOrEqualTo(RuleBasedQueryParser.maxKeywords));
      expect(store.searchTextCalls, lessThanOrEqualTo(RuleBasedQueryParser.maxKeywords + 16));
    });

    test('QA-15: boarding pass does not return train/concert tickets or a chat that mentions a flight', () async {
      store
        ..put(record(galleryImage('bp'), text: 'BOARDING PASS\nLH 2471\nGate G24 Seat 14C\nDeparture 07:55'))
        ..put(record(galleryImage('bp2'), text: 'easyJet\nFlight EZY6123\nGate closes 06:10\nDeparture 06:40'))
        ..put(record(galleryImage('train'), text: 'DB Ticket\nCoach 7 Seat 61\nBooking reference QX7P2L'))
        ..put(record(galleryImage('concert'), text: 'ADMIT ONE\nRow F Seat 22'))
        ..put(record(galleryImage('chat'), text: 'I found flights for 89 euros each'));
      final r = await engine().search('Boarding pass');
      expect(ids(r).first, 'bp');
      expect(ids(r).toSet(), {'bp', 'bp2'}, reason: 'bp2 has gate + flight + departure');
    });

    test('QA-15: a lone decisive expansion (IBAN) survives a literal "bank details" match', () async {
      store
        ..put(record(galleryImage('lit'), text: 'Here are my bank details'))
        ..put(record(galleryImage('iban'), text: 'IBAN: GB33BUKB20201555555555'))
        ..put(record(galleryImage('rib'), text: 'Prime rib special'));
      final r = await engine().search('bank details');
      expect(ids(r), ['lit', 'iban']);
    });
  });

  test('date reason wording', () {
    String d(String label) => HybridSearchEngine.describeDateRange(DateRange(now, now, label: label));
    expect(d('Summer 2025'), 'Taken in Summer 2025');
    expect(d('Today'), 'Taken today');
    expect(d('Last week'), 'Taken last week');
    expect(d('Last Friday'), 'Taken last Friday');
    expect(d('Last 30 days'), 'Taken in the last 30 days');
    expect(d('Past week'), 'Taken in the past week');
    expect(d('About 2 weeks ago'), 'Taken about 2 weeks ago');
    expect(d('2024'), 'Taken in 2024');
  });

  test('elapsed time and parsed query are reported', () async {
    store.put(record(galleryImage('a'), text: 'hello world'));
    final r = await engine().search('hello');
    expect(r.elapsed, isNot(Duration.zero));
    expect(r.query.keywords, ['hello']);
  });
}
