/// Detects people referred to in a query ("conversation with Jamie",
/// "the message from alex", "Jamie's address", "what Sam said").
///
/// Product rule: the app never claims a person matched without evidence in
/// the image. A detected name is therefore REQUIRED literal text: only images
/// whose recognised text contains it may be returned, and it is not sent to
/// the image model (CLIP cannot know who "Jamie" is).
///
/// Only person contexts fire, so places and things do not ("trip to Germany",
/// "picture of the red car", "someone sent me their bank details").
library;

import 'query_vocabulary.dart';

abstract final class PersonMentions {
  static const _name = r"([\p{L}][\p{L}\-]*)";

  /// Communication words that make "with/from/to X" refer to a person.
  static const _comm =
      r'(?:conversations?|chats?|messages?|texts?|threads?|dms?|sms|emails?|calls?|whatsapps?|'
      r'sent|send|sending|texted|messaged|wrote|replied|talked|talking|spoke|speaking|chatted)';

  static const _speechVerbs = r'(?:sent|texted|messaged|wrote|replied|said|told|asked)';

  static final List<RegExp> _patterns = [
    // "conversation with Jamie", "messages from alex", "sent to Sam", "talking to mom"
    RegExp('\\b$_comm\\s+(?:it\\s+|this\\s+|that\\s+|them\\s+)?(?:with|from|to)\\s+$_name', unicode: true),
    // "between me and Jamie"
    RegExp('\\bbetween\\s+(?:me|us)\\s+and\\s+$_name', unicode: true),
    // "Jamie sent", "what Sam said"
    RegExp('\\b$_name\\s+$_speechVerbs\\b', unicode: true),
    // "told Sam", "asked alex"
    RegExp('\\b(?:told|asked|texted|messaged|called|emailed)\\s+$_name', unicode: true),
    // "Jamie's number / address / messages ..."
    RegExp(
        "\\b$_name's\\s+(?:numbers?|phone|address|email|messages?|chats?|texts?|birthday|contact|details|iban|account)\\b",
        unicode: true),
  ];

  /// Patterns that need the name to be capitalised in the raw query.
  static final List<RegExp> _capitalisedOnly = [
    // "screenshot from Alex". Not after other words: "photos from Paris" and
    // "flights from Berlin" are places ("message from alex" is matched above).
    RegExp('\\b[Ss]creen\\s?[Ss]hots?\\s+from\\s+$_name', unicode: true),
    // "with Jamie": a capitalised name after "with" is a person context.
    RegExp('\\bwith\\s+$_name', unicode: true),
    // "Jamie's ..."
    RegExp("\\b$_name's\\b", unicode: true),
  ];

  static final RegExp _quoted = RegExp(r'"[^"]*"|“[^”]*”|„[^“”]*[“”]|«[^»]*»');

  /// Lower-case names in query order, without duplicates.
  static List<String> detect(String raw) {
    final text = raw.replaceAll(_quoted, ' | ').replaceAll('’', "'");
    final lower = text.toLowerCase();
    final names = <String>[];
    void add(String? n) {
      if (n == null) return;
      final w = n.toLowerCase();
      if (!_isNameLike(w) || names.contains(w)) return;
      names.add(w);
    }

    for (final re in _patterns) {
      for (final m in re.allMatches(lower)) {
        add(m[1]);
      }
    }
    for (final re in _capitalisedOnly) {
      for (final m in re.allMatches(text)) {
        final n = m[1]!;
        if (n[0] == n[0].toUpperCase() && n[0] != n[0].toLowerCase()) add(n);
      }
    }
    return names;
  }

  static bool _isNameLike(String w) {
    if (w.length < 2) return false;
    if (kStopWords.contains(w) || kContextNouns.contains(w) || kContextVerbs.contains(w)) return false;
    if (_notNames.contains(w)) return false;
    if (kMonthNames.contains(w) && w != 'june' && w != 'april' && w != 'may' && w != 'august') {
      return false;
    }
    return !kWeekdayNames.contains(w);
  }

  static const Set<String> _notNames = {
    'someone', 'somebody', 'anyone', 'anybody', 'everyone', 'everybody', 'nobody', 'people', 'person',
    'friend', 'friends', 'family', 'group', 'team', 'work', 'colleague', 'colleagues', 'today', 'yesterday',
    'tomorrow', 'tonight', 'last', 'this', 'next', 'week', 'month', 'year', 'weekend', 'morning', 'evening',
    'night', 'afternoon', 'summer', 'winter', 'spring', 'autumn', 'fall', 'details', 'link', 'photo', 'picture',
    'screenshot', 'file', 'document', 'bank', 'address', 'number', 'code', 'password', 'receipt', 'ticket', 'menu',
  };
}
