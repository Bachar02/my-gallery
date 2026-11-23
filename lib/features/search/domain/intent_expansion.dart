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
  const Expansion(this.text, {required this.concept, this.isPhrase = false, this.decisive = false});

  /// Lower-case term (prefix-matched) or phrase (matched verbatim).
  final String text;

  /// The words in the user's query that triggered it, e.g. "bank details".
  final String concept;
  final bool isPhrase;

  /// Identifies the concept on its own (see [IntentConcept.decisive]).
  final bool decisive;

  @override
  bool operator ==(Object other) => other is Expansion && other.text == text && other.isPhrase == isPhrase;

  @override
  int get hashCode => Object.hash(text, isPhrase);

  @override
  String toString() => 'Expansion($text <- $concept)';
}

class IntentConcept {
  const IntentConcept({
    required this.triggers,
    required this.terms,
    this.decisive = const [],
    this.textCentric = true,
  });

  /// Keyword sequences (space separated, already stop-word free) that
  /// activate the concept. Longest trigger is matched first.
  final List<String> triggers;

  /// Expansions; entries containing a space are searched as phrases.
  final List<String> terms;

  /// Terms specific enough to identify the concept on their own ("IBAN" is
  /// bank details; "flight" in a chat is not a boarding pass). They keep an
  /// image that matches only through expansions even when another image
  /// matches the query literally.
  final List<String> decisive;

  /// The thing asked for is defined by its text (a password, an IBAN, a
  /// boarding pass), not by how it looks. For such queries an image without
  /// any matching text needs strong visual similarity to be shown.
  final bool textCentric;
}

const List<IntentConcept> kIntentConcepts = [
  IntentConcept(
    triggers: ['bank details', 'banking details', 'bank account', 'account details', 'bank info', 'iban'],
    terms: ['iban', 'bic', 'swift', 'sort code', 'routing number', 'account number', 'rib', 'beneficiary'],
    decisive: ['iban', 'swift', 'sort code', 'routing number'],
  ),
  IntentConcept(
    triggers: ['address', 'home address', 'postal address', 'shipping address', 'delivery address'],
    terms: ['street', 'avenue', 'road', 'postcode', 'zip code', 'postal code', 'apartment', 'strasse'],
    decisive: ['postcode', 'zip code', 'postal code'],
  ),
  IntentConcept(
    triggers: ['phone number', 'mobile number', 'cell number', 'contact number', 'phone', 'contact details'],
    terms: ['phone', 'mobile', 'cell', 'telephone', 'contact'],
  ),
  IntentConcept(
    triggers: ['password', 'passwords', 'wifi', 'wi fi', 'wifi password', 'login', 'credentials', 'passcode'],
    terms: ['password', 'passcode', 'ssid', 'wifi', 'wi fi', 'username', 'login'],
    decisive: ['password', 'passcode', 'ssid'],
  ),
  IntentConcept(
    triggers: ['receipt', 'receipts', 'invoice', 'invoices', 'bill', 'purchase'],
    terms: ['receipt', 'invoice', 'total', 'subtotal', 'vat', 'amount due', 'paid', 'payment'],
    decisive: ['receipt', 'invoice', 'subtotal', 'amount due'],
  ),
  // Tickets: one concept per kind, so a boarding pass query does not pull in
  // train or concert tickets (they share words like "seat"). The most
  // specific trigger wins; generic "ticket" only fires on its own.
  IntentConcept(
    triggers: ['boarding pass', 'boarding passes', 'flight', 'flights', 'plane ticket', 'plane tickets',
        'flight ticket', 'flight tickets', 'airline ticket', 'flight details'],
    terms: ['boarding', 'gate', 'flight', 'departure', 'terminal'],
  ),
  IntentConcept(
    triggers: ['train ticket', 'train tickets', 'rail ticket', 'bus ticket', 'bus tickets'],
    terms: ['platform', 'coach', 'booking reference'],
  ),
  IntentConcept(
    triggers: ['concert ticket', 'concert tickets', 'event ticket', 'event tickets', 'show tickets', 'festival ticket'],
    terms: ['admit one', 'doors', 'row'],
  ),
  IntentConcept(
    triggers: ['ticket', 'tickets'],
    terms: ['boarding pass', 'admit one', 'booking reference', 'seat'],
  ),
  IntentConcept(
    triggers: ['menu', 'restaurant menu', 'food menu'],
    terms: ['starters', 'mains', 'desserts', 'appetizers', 'entrees', 'main course'],
    textCentric: false, // menus are also recognisable visually
  ),
  IntentConcept(
    triggers: ['appointment', 'appointments', 'reservation', 'booking', 'doctor appointment'],
    terms: ['appointment', 'reservation', 'booking', 'confirmed', 'confirmation', 'scheduled'],
  ),
  IntentConcept(
    triggers: ['order', 'orders', 'tracking', 'tracking number', 'delivery', 'package', 'parcel', 'shipment'],
    terms: ['order', 'tracking', 'shipped', 'delivery', 'dispatched', 'parcel', 'out for delivery', 'order number'],
    decisive: ['out for delivery', 'order number'],
  ),
  IntentConcept(
    triggers: ['trip', 'vacation', 'holiday', 'travel', 'itinerary'],
    terms: ['flight', 'hotel', 'itinerary', 'booking', 'check in'],
    textCentric: false,
  ),
];

class IntentExpander {
  const IntentExpander({this.concepts = kIntentConcepts});

  final List<IntentConcept> concepts;

  /// Expansions for [keywords] (in query order), excluding terms already in
  /// [keywords]. Each concept fires at most once.
  List<Expansion> expand(List<String> keywords) => match(keywords).expansions;

  /// Concepts found in [keywords] and their expansions. Longer triggers are
  /// matched first and consume their keywords, so "train ticket" fires the
  /// train concept but not the generic ticket concept. Each concept fires at
  /// most once; expansions already among [keywords] are left out.
  ({List<IntentConcept> concepts, List<Expansion> expansions}) match(List<String> keywords) {
    final found = <({IntentConcept concept, String trigger, int start, int length})>[];
    for (final c in concepts) {
      for (final t in c.triggers) {
        final words = t.split(' ');
        for (var i = 0; i + words.length <= keywords.length; i++) {
          var ok = true;
          for (var j = 0; j < words.length && ok; j++) {
            ok = keywords[i + j] == words[j];
          }
          if (ok) found.add((concept: c, trigger: t, start: i, length: words.length));
        }
      }
    }
    found.sort((a, b) => b.length != a.length ? b.length.compareTo(a.length) : a.start.compareTo(b.start));
    final consumed = List<bool>.filled(keywords.length, false);
    final fired = <IntentConcept>[];
    final out = <Expansion>[];
    for (final f in found) {
      if (fired.contains(f.concept)) continue;
      if (Iterable.generate(f.length, (k) => consumed[f.start + k]).any((x) => x)) continue;
      for (var k = 0; k < f.length; k++) {
        consumed[f.start + k] = true;
      }
      fired.add(f.concept);
      for (final term in f.concept.terms) {
        if (keywords.contains(term)) continue;
        final e = Expansion(term,
            concept: f.trigger, isPhrase: term.contains(' '), decisive: f.concept.decisive.contains(term));
        if (!out.contains(e)) out.add(e);
      }
    }
    return (concepts: fired, expansions: out);
  }
}
