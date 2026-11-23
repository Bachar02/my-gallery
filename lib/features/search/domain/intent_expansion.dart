/// Curated intent expansion: maps what people *ask for* ("bank details") to
/// words that actually *appear* in such screenshots ("IBAN", "SWIFT").
///
/// Kept deliberately small and precise. Every expansion is weaker evidence
/// than a literal query word: the search engine scores expansion matches
/// with a lower weight and labels them "related to ..." in match reasons.
/// Avoid very short or very common words here: the index matches terms as
/// prefixes, so "st" would match "stop", "store", ...
library;

/// One extra search term or phrase derived from a concept in the query.
class Expansion {
  const Expansion(this.text, {required this.concept, this.isPhrase = false});

  /// Lower-case term (prefix-matched) or phrase (matched verbatim).
  final String text;

  /// The words in the user's query that triggered it, e.g. "bank details".
  final String concept;
  final bool isPhrase;

  @override
  bool operator ==(Object other) => other is Expansion && other.text == text && other.isPhrase == isPhrase;

  @override
  int get hashCode => Object.hash(text, isPhrase);

  @override
  String toString() => 'Expansion($text <- $concept)';
}

class IntentConcept {
  const IntentConcept({required this.triggers, required this.terms});

  /// Keyword sequences (space separated, already stop-word free) that
  /// activate the concept. Longest trigger is matched first.
  final List<String> triggers;

  /// Expansions; entries containing a space are searched as phrases.
  final List<String> terms;
}

const List<IntentConcept> kIntentConcepts = [
  IntentConcept(
    triggers: ['bank details', 'banking details', 'bank account', 'account details', 'bank info', 'iban'],
    terms: ['iban', 'bic', 'swift', 'sort code', 'routing number', 'account number', 'rib', 'beneficiary'],
  ),
  IntentConcept(
    triggers: ['address', 'home address', 'postal address', 'shipping address', 'delivery address'],
    terms: ['street', 'avenue', 'road', 'postcode', 'zip code', 'postal code', 'apartment', 'strasse'],
  ),
  IntentConcept(
    triggers: ['phone number', 'mobile number', 'cell number', 'contact number', 'phone', 'contact details'],
    terms: ['phone', 'mobile', 'cell', 'telephone', 'contact'],
  ),
  IntentConcept(
    triggers: ['password', 'passwords', 'wifi', 'wi fi', 'wifi password', 'login', 'credentials', 'passcode'],
    terms: ['password', 'passcode', 'ssid', 'wifi', 'wi fi', 'username', 'login'],
  ),
  IntentConcept(
    triggers: ['receipt', 'receipts', 'invoice', 'invoices', 'bill', 'purchase'],
    terms: ['receipt', 'invoice', 'total', 'subtotal', 'vat', 'amount due', 'paid', 'payment'],
  ),
  IntentConcept(
    triggers: ['ticket', 'tickets', 'boarding pass', 'flight', 'plane ticket', 'train ticket', 'flight details'],
    terms: ['boarding', 'gate', 'seat', 'flight', 'departure', 'booking reference', 'terminal', 'platform'],
  ),
  IntentConcept(
    triggers: ['menu', 'restaurant menu', 'food menu'],
    terms: ['starters', 'mains', 'desserts', 'appetizers', 'entrees', 'main course'],
  ),
  IntentConcept(
    triggers: ['appointment', 'appointments', 'reservation', 'booking', 'doctor appointment'],
    terms: ['appointment', 'reservation', 'booking', 'confirmed', 'confirmation', 'scheduled'],
  ),
  IntentConcept(
    triggers: ['order', 'orders', 'tracking', 'tracking number', 'delivery', 'package', 'parcel', 'shipment'],
    terms: ['order', 'tracking', 'shipped', 'delivery', 'dispatched', 'parcel', 'out for delivery', 'order number'],
  ),
  IntentConcept(
    triggers: ['trip', 'vacation', 'holiday', 'travel', 'itinerary'],
    terms: ['flight', 'hotel', 'itinerary', 'booking', 'check in'],
  ),
];

class IntentExpander {
  const IntentExpander({this.concepts = kIntentConcepts});

  final List<IntentConcept> concepts;

  /// Expansions for [keywords] (in query order), excluding terms already in
  /// [keywords]. Each concept fires at most once.
  List<Expansion> expand(List<String> keywords) {
    final joined = ' ${keywords.join(' ')} ';
    final out = <Expansion>[];
    for (final c in concepts) {
      final triggers = [...c.triggers]..sort((a, b) => b.length.compareTo(a.length));
      final hit = triggers.firstWhere((t) => joined.contains(' $t '), orElse: () => '');
      if (hit.isEmpty) continue;
      for (final term in c.terms) {
        if (keywords.contains(term)) continue;
        final e = Expansion(term, concept: hit, isPhrase: term.contains(' '));
        if (!out.contains(e)) out.add(e);
      }
    }
    return out;
  }
}
