/// Query understanding: decides *what kind* of query it is and which
/// evidence may answer it.
///
///  * [QueryIntent.visual]: the head noun is something you recognise by how
///    it looks ("a man", "red car", "restaurant menu", "beach at sunset").
///    The image model decides; recognised text may only support a visual
///    match, never create one.
///  * [QueryIntent.text]: the answer is written text ("IBAN", "Wi-Fi password",
///    "order number", quoted text). OCR decides.
///  * [QueryIntent.conversation]: a person in a conversation context
///    ("conversation with Jamie", "what Jamie sent me"). Chat screenshots
///    whose header names the person; body-only mentions are a separate group.
///  * [QueryIntent.hybrid]: a kind of screen plus content ("screenshot of the
///    map to the hotel"), a screenshot of a visual thing, or words the
///    lexicons do not know. Signals must agree.
///
/// Rule-based and deterministic (English): the head noun is the last known
/// noun of the first noun phrase, phrases being split at linking words
/// ("map | to the hotel", "menu | of the restaurant"); a modifier never acts
/// as the head ("restaurant menu" is a menu).
library;

import '../../../domain/models.dart';
import 'intent_expansion.dart';
import 'person_mentions.dart';
import 'query_lexicon.dart';
import 'query_vocabulary.dart';

enum QueryIntent { visual, text, conversation, hybrid, filterOnly, empty }

class QueryPlan {
  const QueryPlan({
    required this.parsed,
    required this.intent,
    this.person,
    this.head,
    this.modifiers = const [],
    this.visualPhrase = '',
    this.textTerms = const [],
    this.screenType,
    this.wantsScreenshot = false,
    this.peopleSubject = false,
  });

  final ParsedQuery parsed;
  final QueryIntent intent;

  /// Lower-case person name for conversation queries.
  final String? person;

  /// Head noun ("menu" in "restaurant menu"); null when there is none.
  final String? head;

  /// Other descriptive words of the head's noun phrase ("restaurant").
  final List<String> modifiers;

  /// Caption-like phrase for the image model, e.g. "a restaurant menu".
  final String visualPhrase;

  /// Words to look for in recognised text (text, hybrid, conversation topic).
  final List<String> textTerms;

  /// Screen kind named in the query ("map", "chat", "settings"...).
  final ScreenType? screenType;

  /// The query asked for a screenshot ("screenshot of ...").
  final bool wantsScreenshot;

  /// The head noun refers to people ("a man", "kids").
  final bool peopleSubject;

  /// Head and its inflections, for "the word is printed in the image".
  List<String> get headForms => head == null ? const [] : [head!, ...?kWordForms[head!]];

  @override
  String toString() => 'QueryPlan(${intent.name}, head: $head, phrase: "$visualPhrase", '
      'text: $textTerms, screen: ${screenType?.name}, person: $person)';
}

class QueryAnalyzer {
  const QueryAnalyzer({this.expander = const IntentExpander()});

  final IntentExpander expander;

  static final RegExp _quoted = RegExp(r'"[^"]*"|“[^”]*”|„[^“”]*[“”]|«[^»]*»');
  static final RegExp _token = RegExp(r"[\p{L}\p{N}]+(?:'[\p{L}]+)?", unicode: true);
  static final RegExp _pictureOf = RegExp(r'\b(?:photo|photos|picture|pictures|pic|pics|image|images)\s+of\b');

  QueryPlan analyze(String raw, ParsedQuery parsed) {
    final wantsScreenshot = parsed.kind == ImageKind.screenshot;
    final lower = raw.replaceAll(_quoted, ' | ').toLowerCase().replaceAll('’', "'");
    final people = [for (final n in PersonMentions.detect(raw)) if (parsed.keywords.contains(n)) n];
    final keywords = [for (final k in parsed.keywords) if (!people.contains(k)) k];

    if (!parsed.hasContent) {
      final filters = parsed.dateRange != null || parsed.kind != null;
      return QueryPlan(parsed: parsed, intent: filters ? QueryIntent.filterOnly : QueryIntent.empty);
    }

    // Tokens of the query in order, with the words the parser kept.
    final tokens = <String>[];
    for (final m in _token.allMatches(lower)) {
      var w = m[0]!;
      if (w.endsWith("'s")) w = w.substring(0, w.length - 2);
      tokens.add(w.replaceAll("'", ''));
    }
    ScreenType? screenType;
    for (final t in tokens) {
      final s = kScreenNouns[t];
      if (s != null) {
        screenType = s;
        break;
      }
    }

    // ---------------------------------------------------------- people
    if (people.isNotEmpty) {
      final topic = [for (final k in keywords) if (!kScreenNouns.containsKey(k)) k];
      return QueryPlan(
        parsed: parsed,
        intent: QueryIntent.conversation,
        person: people.first,
        textTerms: topic,
        screenType: ScreenType.chat,
        wantsScreenshot: true,
      );
    }

    // Head noun: split the content words into noun phrases at linking words.
    final content = {...keywords};
    bool isContent(String t) => content.contains(t) || kScreenNouns.containsKey(t);
    final segments = <List<String>>[[]];
    for (final t in tokens) {
      if (kLinkWords.contains(t) || t == '|') {
        if (segments.last.isNotEmpty) segments.add([]);
        continue;
      }
      if (isContent(t)) segments.last.add(t);
    }
    segments.removeWhere((s) => s.isEmpty);
    bool known(String t) => kVisualNouns.contains(t) || kTextNouns.contains(t) || kScreenNouns.containsKey(t);
    String? head;
    for (final s in segments) {
      final nouns = s.where(known).toList();
      if (nouns.isNotEmpty) {
        head = nouns.last;
        break;
      }
    }
    head ??= segments.isNotEmpty ? segments.first.last : null;
    final modifiers = [
      for (final s in segments)
        for (final t in s)
          if (t != head && content.contains(t)) t,
    ];

    final textCentric = expander.match(keywords).concepts.any((c) => c.textCentric);
    final visualPhrase = _visualPhrase(tokens, content, head, screenType);
    final peopleSubject = head != null && kPeopleNouns.contains(head);
    final explicitPhoto = _pictureOf.hasMatch(lower);

    QueryIntent intent;
    var hint = screenType;
    if (parsed.phrases.isNotEmpty) {
      intent = QueryIntent.text;
    } else if (head != null && kScreenNouns.containsKey(head)) {
      intent = QueryIntent.hybrid;
      hint = kScreenNouns[head];
    } else if (head != null && kTextNouns.contains(head) || textCentric && !(head != null && kVisualNouns.contains(head))) {
      intent = explicitPhoto ? QueryIntent.hybrid : QueryIntent.text;
    } else if (head != null && kVisualNouns.contains(head)) {
      if (wantsScreenshot || screenType != null) {
        intent = QueryIntent.hybrid;
        if (head == 'menu' || head == 'menus') hint = ScreenType.menu;
      } else {
        intent = QueryIntent.visual;
      }
    } else {
      intent = QueryIntent.hybrid;
    }
    final textTerms = [
      for (final k in keywords)
        if (!(kScreenNouns.containsKey(k) && intent == QueryIntent.hybrid && kScreenNouns[k] == hint)) k,
    ];
    return QueryPlan(
      parsed: parsed,
      intent: intent,
      head: head,
      modifiers: modifiers,
      visualPhrase: visualPhrase,
      textTerms: textTerms,
      screenType: hint,
      wantsScreenshot: wantsScreenshot,
      peopleSubject: peopleSubject,
    );
  }

  /// The descriptive part of the query as a caption fragment: content words
  /// with the small words between them ("a plate of food", "sunset over the
  /// sea"), an article added for a bare singular noun ("dog" -> "a dog").
  static String _visualPhrase(List<String> tokens, Set<String> content, String? head, ScreenType? screen) {
    bool keep(String t) => content.contains(t) && !kTextOnlyModifiers.contains(t);
    final first = tokens.indexWhere(keep);
    if (first < 0) return head ?? '';
    final last = tokens.lastIndexWhere(keep);
    final out = <String>[];
    if (first > 0 && const {'a', 'an', 'the'}.contains(tokens[first - 1])) out.add(tokens[first - 1]);
    for (var i = first; i <= last; i++) {
      final t = tokens[i];
      if (keep(t) || kPhraseConnectors.contains(t)) out.add(t);
    }
    // Connectors left dangling by removed words ("of the").
    while (out.isNotEmpty && kPhraseConnectors.contains(out.last)) {
      out.removeLast();
    }
    if (out.isEmpty) return head ?? '';
    final startsWithDeterminer = const {'a', 'an', 'the', 'some'}.contains(out.first);
    final h = head ?? out.last;
    if (!startsWithDeterminer && !h.endsWith('s') && !kMassNouns.contains(h) && !kStopWords.contains(out.first)) {
      out.insert(0, RegExp('^[aeiou]').hasMatch(out.first) ? 'an' : 'a');
    }
    return out.join(' ');
  }
}

/// Query words that describe the request rather than what is shown
/// ("nearby", "photographed"). Never part of the visual phrase.
const Set<String> kTextOnlyModifiers = {'nearby', 'photographed', 'screenshotted', 'saved', 'old', 'new'};

/// Nouns used without an article ("pizza", "snow", "food").
const Set<String> kMassNouns = {
  'food', 'pizza', 'snow', 'sushi', 'pasta', 'coffee', 'tea', 'wine', 'beer', 'bread', 'breakfast', 'lunch',
  'dinner', 'brunch', 'fruit', 'chocolate', 'soup', 'salad', 'water', 'sand', 'grass', 'sky', 'traffic',
};
