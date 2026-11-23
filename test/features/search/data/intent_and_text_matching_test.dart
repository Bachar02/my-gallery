import 'package:ai_gallery/features/search/domain/intent_expansion.dart';
import 'package:ai_gallery/features/search/domain/text_matching.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IntentExpander', () {
    const expander = IntentExpander();

    test('bank details expands to banking terms, marked with the concept', () {
      final e = expander.expand(['bank', 'details']);
      expect(e.map((x) => x.text), containsAll(['iban', 'bic', 'swift', 'sort code', 'account number']));
      expect(e.every((x) => x.concept == 'bank details'), isTrue);
      expect(e.firstWhere((x) => x.text == 'sort code').isPhrase, isTrue);
      expect(e.firstWhere((x) => x.text == 'iban').isPhrase, isFalse);
    });

    test('longest trigger wins and literal keywords are not repeated', () {
      final e = expander.expand(['wifi', 'password']);
      expect(e.map((x) => x.concept).toSet(), {'wifi password'});
      expect(e.map((x) => x.text), isNot(contains('wifi')));
      expect(e.map((x) => x.text), isNot(contains('password')));
    });

    test('triggers must be whole keyword sequences', () {
      expect(expander.expand(['menus']), isEmpty);
      expect(expander.expand(['red', 'car']), isEmpty);
      expect(expander.expand(['restaurant', 'menu']).map((x) => x.concept).toSet(), {'restaurant menu'});
    });

    test('specific ticket kinds win over the generic ticket concept', () {
      expect(expander.expand(['train', 'ticket']).map((x) => x.concept).toSet(), {'train ticket'});
      expect(expander.expand(['boarding', 'pass']).map((x) => x.text), isNot(contains('seat')));
      expect(expander.expand(['ticket']).map((x) => x.concept).toSet(), {'ticket'});
      final iban = expander.expand(['bank', 'details']).firstWhere((x) => x.text == 'iban');
      expect(iban.decisive, isTrue);
    });

    test('several concepts can fire', () {
      final concepts = expander.expand(['trip', 'germany', 'tickets']).map((x) => x.concept).toSet();
      expect(concepts, {'trip', 'tickets'});
    });

    test('expansions are modest', () {
      for (final c in kIntentConcepts) {
        expect(c.terms.length, lessThanOrEqualTo(10));
        for (final t in c.terms) {
          expect(t.replaceAll(' ', '').length, greaterThanOrEqualTo(3), reason: '"$t" would prefix-match too much');
          expect(t, t.toLowerCase());
        }
      }
    });
  });

  group('TextMatching', () {
    test('normalize folds case, accents and punctuation', () {
      expect(TextMatching.normalize('  Café—MÜNCHEN, Straße! '), 'cafe munchen straße');
    });

    test('hasWord: whole words and plurals only', () {
      final w = TextMatching.words('Used cars and a cardigan; boxes');
      expect(TextMatching.hasWord(w, 'car'), isTrue);
      expect(TextMatching.hasWord(w, 'cars'), isTrue);
      expect(TextMatching.hasWord(w, 'box'), isTrue);
      expect(TextMatching.hasWord(w, 'card'), isFalse);
      expect(TextMatching.hasWord(w, 'use'), isFalse);
    });

    test('containsPhrase respects word boundaries', () {
      final n = TextMatching.normalize('Your parcel is OUT for delivery.');
      expect(TextMatching.containsPhrase(n, 'out for delivery'), isTrue);
      expect(TextMatching.containsPhrase(n, 'ut for deliver'), isFalse);
    });

    test('snippet: around the first whole-word hit, one line, with ellipses', () {
      final text = '${'lorem ipsum ' * 10}\nIBAN: DE89 3704\nBIC: COBADEFF\n${'dolor sit ' * 10}';
      final s = TextMatching.snippet(text, ['iban'], radius: 20)!;
      expect(s, contains('IBAN: DE89 3704 · BIC'));
      expect(s.startsWith('…'), isTrue);
      expect(s.endsWith('…'), isTrue);
      expect(TextMatching.snippet(text, ['nothing']), isNull);
      expect(TextMatching.snippet('Café Zoë', ['cafe']), 'Café Zoë');
    });
  });
}
