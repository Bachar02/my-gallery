import '../../../domain/interfaces.dart';
import '../../../domain/models.dart';
import '../domain/query_vocabulary.dart';

/// Deterministic, rule-based natural-language query parser (English).
///
/// Extracts, in this order:
///  1. quoted phrases (`"out for delivery"`, curly quotes too) -> [ParsedQuery.phrases]
///  2. image kind: "screenshot(s)", "screen shot", "screengrab" -> [ImageKind.screenshot].
///     "photo"/"picture"/"pic" do NOT force [ImageKind.photo]: people call
///     screenshots pictures too, so these words are simply dropped.
///  3. one date expression -> [DateRange] (see [_dateRules] for the grammar),
///     evaluated against the injected `now` in local time. Seasons are
///     meteorological, northern hemisphere: spring Mar-May, summer Jun-Aug,
///     autumn/fall Sep-Nov, winter Dec-Feb.
///  4. keywords: lower-case words minus stop words / request filler, with
///     names and numbers kept ("with Jamie" -> `jamie`).
///  5. semantic text for the image-text model: keywords plus context nouns
///     ("conversation", "chat"), in query order.
///
/// Intent expansion (e.g. "bank details" -> IBAN, SWIFT ...) is deliberately
/// not done here, because [ParsedQuery] has no way to mark expanded terms as
/// weaker than literal ones: the search engine applies `IntentExpander` to the
/// keywords instead.
class RuleBasedQueryParser implements QueryParser {
  RuleBasedQueryParser({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  static final RegExp _quoted = RegExp(r'"([^"]+)"|“([^”]+)”|„([^“”]+)[“”]|«([^»]+)»');
  static final RegExp _kind = RegExp(
    r'\b(?:screen[\s-]?shots?|screen[\s-]?grabs?|screen[\s-]?caps?|screencaps?)\b',
  );
  static final RegExp _token = RegExp(r"[\p{L}\p{N}]+(?:'[\p{L}]+)?", unicode: true);
  static final RegExp _spaces = RegExp(r'\s+');

  @override
  ParsedQuery parse(String raw, {DateTime? now}) {
    final clock = now ?? _clock();

    // 1. Quoted phrases. Replaced by a separator so the words on either side
    //    never form a multi-word date expression together.
    final phrases = <String>[];
    var text = raw.replaceAllMapped(_quoted, (m) {
      final inner = (m[1] ?? m[2] ?? m[3] ?? m[4] ?? '').toLowerCase().replaceAll(_spaces, ' ').trim();
      final cleaned = inner.replaceAll(RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$', unicode: true), '');
      if (cleaned.isNotEmpty && !phrases.contains(cleaned)) phrases.add(cleaned);
      return ' | ';
    });

    text = text.toLowerCase().replaceAll('’', "'").replaceAll('‘', "'");

    // 2. Image kind.
    ImageKind? kind;
    text = text.replaceAllMapped(_kind, (m) {
      kind = ImageKind.screenshot;
      return ' | ';
    });

    // 3. Date: the first rule that matches wins; every matched date
    //    expression is removed from the text.
    DateRange? range;
    for (final rule in _dateRules) {
      text = text.replaceAllMapped(rule.pattern, (m) {
        final r = rule.build(m, clock);
        if (r == null) return m[0]!;
        range ??= r;
        return ' | ';
      });
    }

    // 4./5. Keywords and semantic text.
    final keywords = <String>[];
    final semantic = <String>[];
    for (final m in _token.allMatches(text)) {
      var word = m[0]!;
      if (word.endsWith("'s")) word = word.substring(0, word.length - 2);
      word = word.replaceAll("'", '');
      if (word.isEmpty) continue;
      if (kStopWords.contains(word) || kContextVerbs.contains(word)) continue;
      if (kContextNouns.contains(word)) {
        semantic.add(word);
        continue;
      }
      final isNumber = RegExp(r'^\d+$').hasMatch(word);
      if (word.length < 2 && !isNumber) continue;
      semantic.add(word);
      if (!keywords.contains(word)) keywords.add(word);
    }

    return ParsedQuery(
      raw: raw,
      semanticText: semantic.join(' '),
      keywords: keywords,
      phrases: phrases,
      dateRange: range,
      kind: kind,
    );
  }

  // ------------------------------------------------------------------ dates

  static const _monthPattern =
      r'(january|february|march|april|may|june|july|august|september|october|november|december|'
      r'jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)';
  static const _monthAfterPreposition = r'\b(?:in|from|during|since|back\s+in|around)\s+'
      r'(january|february|march|april|may|june|july|august|september|october|november|december|sept)\b';
  static const _seasonPattern = r'(spring|summer|autumn|fall|winter)';
  static const _numPattern = r'(\d{1,3}|a couple of|couple of|a few|few|several|an?|one|two|three|four|five|six|'
      r'seven|eight|nine|ten|eleven|twelve)';
  static const _unitPattern = r'(day|week|month|year)s?';

  static final List<_DateRule> _dateRules = [
    // "summer 2024", "winter of 2023"
    _DateRule(r'\b' + _seasonPattern + r'\s+(?:of\s+)?(\d{4})\b', (m, now) {
      final year = int.parse(m[2]!);
      return _season(_seasonIndex(m[1]!), year);
    }),
    // "march 2024", "mar 2024", "march, 2024", "march of 2024"
    _DateRule(r'\b' + _monthPattern + r',?\s+(?:of\s+)?(\d{4})\b', (m, now) {
      return _month(_monthIndex(m[1]!), int.parse(m[2]!));
    }),
    // "the day before yesterday"
    _DateRule(r'\b(?:the\s+)?day\s+before\s+yesterday\b', (m, now) {
      final d = _day(now, -2);
      return DateRange(d, _day(d, 1), label: '2 days ago');
    }),
    _DateRule(r'\b(?:today|tonight|this\s+morning|this\s+afternoon|this\s+evening)\b', (m, now) {
      final d = _day(now, 0);
      return DateRange(d, _day(d, 1), label: 'Today');
    }),
    _DateRule(r'\b(?:yesterday|last\s+night)\b', (m, now) {
      final d = _day(now, -1);
      return DateRange(d, _day(d, 1), label: 'Yesterday');
    }),
    // "3 days ago", "two weeks ago", "a couple of months ago", "a year ago"
    _DateRule(r'\b' + _numPattern + r'\s+' + _unitPattern + r'\s+ago\b', (m, now) {
      final n = _number(m[1]!);
      if (n == null) return null;
      final fuzzy = const {'a couple of', 'couple of', 'a few', 'few', 'several'}.contains(m[1]);
      return _ago(n, m[2]!, now, fuzzy: fuzzy);
    }),
    // "last 7 days", "past two weeks", "the last few months"
    _DateRule(r'\b(?:in\s+)?(?:the\s+)?(?:last|past)\s+' + _numPattern + r'\s+' + _unitPattern + r'\b', (m, now) {
      final n = _number(m[1]!);
      if (n == null || n < 1) return null;
      return _lastN(n, m[2]!, now);
    }),
    _DateRule(r'\b(this|last|past|previous)\s+weekend\b', (m, now) {
      // Saturday 00:00 .. Monday 00:00. Weeks run Monday-Sunday, so the
      // Saturday of the current week is "this weekend" (upcoming, or the
      // current one on Saturday/Sunday) and the one before is "last weekend".
      final today = _day(now, 0);
      final saturday = _day(today, DateTime.saturday - today.weekday);
      if (m[1] == 'this') return DateRange(saturday, _day(saturday, 2), label: 'This weekend');
      final start = _day(saturday, -7);
      return DateRange(start, _day(start, 2), label: 'Last weekend');
    }),
    // "past week/month/year": a rolling window ending today.
    _DateRule(r'\b(?:in\s+)?(?:the\s+)?past\s+(week|month|year)\b', (m, now) => _lastN(1, m[1]!, now)),
    // "this/last week": calendar weeks starting on Monday.
    _DateRule(r'\b(?:(this)|last|previous)\s+week\b', (m, now) {
      final monday = _day(now, 1 - now.weekday);
      if (m[1] != null) return DateRange(monday, _day(monday, 7), label: 'This week');
      return DateRange(_day(monday, -7), monday, label: 'Last week');
    }),
    _DateRule(r'\b(?:(this)|last|previous)\s+month\b', (m, now) {
      final offset = m[1] != null ? 0 : -1;
      return _month(now.month + offset, now.year);
    }),
    _DateRule(r'\b(?:(this)|last|previous)\s+year\b', (m, now) {
      final y = m[1] != null ? now.year : now.year - 1;
      return DateRange(DateTime(y), DateTime(y + 1), label: '$y');
    }),
    // "last summer" = the most recent *completed* one; "this winter".
    _DateRule(r'\b(this|last|past|previous)\s+' + _seasonPattern + r'\b', (m, now) {
      final s = _seasonIndex(m[2]!);
      return m[1] == 'this' ? _currentSeasonOccurrence(s, now) : _lastCompletedSeason(s, now);
    }),
    // "in summer", "during the winter": the most recent one that has started.
    // A bare season word is not a date ("the chat with Summer").
    _DateRule(r'\b(?:in|during|from|over)\s+(?:the\s+)?' + _seasonPattern + r'\b', (m, now) {
      return _mostRecentStartedSeason(_seasonIndex(m[1]!), now);
    }),
    // "last friday"
    _DateRule(r'\b(?:last|this\s+past)\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b', (m, now) {
      final wd = kWeekdayNames.indexOf(m[1]!) + 1;
      var back = (now.weekday - wd) % 7;
      if (back == 0) back = 7;
      final d = _day(now, -back);
      return DateRange(d, _day(d, 1), label: 'Last ${_capitalize(m[1]!)}');
    }),
    // "last march" (most recent March before the current month), "this march"
    _DateRule(r'\b(last|this)\s+' + _monthPattern + r'\b', (m, now) {
      final month = _monthIndex(m[2]!);
      if (m[1] == 'this') return _month(month, now.year);
      return _month(month, month < now.month ? now.year : now.year - 1);
    }),
    // "in march", "from may", "during august": the most recent occurrence
    // (the current month counts). Full names only ("from Jan" is more likely
    // a person). Without a preposition only month names that are not also
    // common first names or words (may, march, april, june, july, august).
    _DateRule(
        '$_monthAfterPreposition|'
        r'\b(january|february|september|october|november|december)\b', (m, now) {
      final month = _monthIndex(m[1] ?? m[2]!);
      return _month(month, month <= now.month ? now.year : now.year - 1);
    }),
    // "in 2023", "from 2021", "back in 2019", "the year 2020"
    _DateRule(r'\b(?:in|from|during|since|of|back\s+in|year|around)\s+(\d{4})\b', (m, now) {
      final y = int.parse(m[1]!);
      if (y < 1990 || y > now.year) return null;
      return DateRange(DateTime(y), DateTime(y + 1), label: '$y');
    }),
    _DateRule(r'\b(?:recently|recent|lately|latest|newest)\b', (m, now) {
      final today = _day(now, 0);
      return DateRange(_day(today, -29), _day(today, 1), label: 'Last 30 days');
    }),
  ];

  static DateTime _day(DateTime t, int offsetDays) => DateTime(t.year, t.month, t.day + offsetDays);

  static int? _number(String s) => int.tryParse(s) ?? kNumberWords[s];

  static int _monthIndex(String s) {
    for (var i = 0; i < kMonthNames.length; i++) {
      if (kMonthNames[i].startsWith(s.substring(0, 3))) return i + 1;
    }
    throw ArgumentError(s);
  }

  /// Month [month] (may be out of 1..12, DateTime normalises) of [year].
  static DateRange _month(int month, int year) {
    final start = DateTime(year, month);
    final end = DateTime(start.year, start.month + 1);
    return DateRange(start, end, label: '${_capitalize(kMonthNames[start.month - 1])} ${start.year}');
  }

  static DateRange _ago(int n, String unit, DateTime now, {required bool fuzzy}) {
    final today = _day(now, 0);
    switch (unit) {
      case 'day':
        if (fuzzy) {
          return DateRange(_day(today, -(n * 2)), today, label: n <= 2 ? 'A couple of days ago' : 'A few days ago');
        }
        final d = _day(today, -n);
        if (n == 1) return DateRange(d, _day(d, 1), label: 'Yesterday');
        return DateRange(_day(d, -1), _day(d, 2), label: 'Around $n days ago');
      case 'week':
        final center = _day(today, -7 * n);
        final half = fuzzy ? 7 : 3;
        return DateRange(_day(center, -half), _day(center, half + 1),
            label: n == 1 ? 'About a week ago' : 'About $n weeks ago');
      case 'month':
        if (fuzzy) {
          return DateRange(DateTime(now.year, now.month - n - 1, now.day), DateTime(now.year, now.month - 1, now.day + 1),
              label: 'A few months ago');
        }
        return _month(now.month - n, now.year);
      default: // year
        final y = now.year - n;
        return DateRange(DateTime(y), DateTime(y + 1), label: '$y');
    }
  }

  static DateRange _lastN(int n, String unit, DateTime now) {
    final today = _day(now, 0);
    final end = _day(today, 1);
    final DateTime start;
    switch (unit) {
      case 'day':
        start = _day(today, -(n - 1));
      case 'week':
        start = _day(today, -(7 * n - 1));
      case 'month':
        start = DateTime(now.year, now.month - n, now.day + 1);
      default:
        start = DateTime(now.year - n, now.month, now.day + 1);
    }
    return DateRange(start, end, label: n == 1 ? 'Past $unit' : 'Last $n ${unit}s');
  }

  // Seasons: 0 spring (Mar), 1 summer (Jun), 2 autumn (Sep), 3 winter (Dec).
  static int _seasonIndex(String s) => switch (s) {
        'spring' => 0,
        'summer' => 1,
        'autumn' || 'fall' => 2,
        _ => 3,
      };

  static const _seasonNames = ['Spring', 'Summer', 'Autumn', 'Winter'];

  /// Season [s] that *starts* in [year] (winter 2024 = Dec 2024 - Feb 2025).
  static DateRange _season(int s, int year) {
    final startMonth = 3 + 3 * s;
    final start = DateTime(year, startMonth);
    final end = DateTime(year, startMonth + 3);
    final label = s == 3
        ? 'Winter $year–${((year + 1) % 100).toString().padLeft(2, '0')}'
        : '${_seasonNames[s]} $year';
    return DateRange(start, end, label: label);
  }

  static DateRange _lastCompletedSeason(int s, DateTime now) {
    for (var y = now.year; ; y--) {
      final r = _season(s, y);
      if (!r.end.isAfter(now)) return r;
    }
  }

  static DateRange _mostRecentStartedSeason(int s, DateTime now) {
    for (var y = now.year; ; y--) {
      final r = _season(s, y);
      if (!r.start.isAfter(now)) return r;
    }
  }

  /// "this winter" in January means the winter that started last December.
  static DateRange _currentSeasonOccurrence(int s, DateTime now) {
    if (s == 3 && now.month <= 2) return _season(3, now.year - 1);
    return _season(s, now.year);
  }

  static String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

class _DateRule {
  _DateRule(String pattern, this.build) : pattern = RegExp(pattern);

  final RegExp pattern;

  /// Returns null to reject the match (the text is left untouched).
  final DateRange? Function(Match m, DateTime now) build;
}
