/// Word-level text matching used to verify store hits against OCR text,
/// build snippets and compare recognised text. Accent-insensitive for Latin
/// script ("cafe" matches "Café"), case-insensitive, plural-tolerant.
library;

abstract final class TextMatching {
  static final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

  /// Lower-case, accents folded, every run of non-alphanumerics -> one space.
  static String normalize(String text) =>
      fold(text.toLowerCase()).replaceAll(_nonWord, ' ').trim();

  static Set<String> words(String text) {
    final n = normalize(text);
    return n.isEmpty ? <String>{} : n.split(' ').toSet();
  }

  /// Whole-word match, tolerating a plural "s"/"es" on either side.
  static bool hasWord(Set<String> words, String term) {
    final t = normalize(term);
    if (t.isEmpty) return false;
    if (t.contains(' ')) return false;
    if (words.contains(t) || words.contains('${t}s') || words.contains('${t}es')) return true;
    if (t.length > 3 && t.endsWith('es') && words.contains(t.substring(0, t.length - 2))) return true;
    if (t.length > 2 && t.endsWith('s') && words.contains(t.substring(0, t.length - 1))) return true;
    return false;
  }

  /// [normalizedText] must come from [normalize].
  static bool containsPhrase(String normalizedText, String phrase) {
    final p = normalize(phrase);
    if (p.isEmpty) return false;
    return ' $normalizedText '.contains(' $p ');
  }

  /// Excerpt of [text] around the first whole-word occurrence of any of
  /// [terms], about [radius] characters each side, on one line.
  static String? snippet(String text, List<String> terms, {int radius = 48}) {
    if (text.isEmpty) return null;
    final folded = fold(text.toLowerCase());
    // fold() maps each character to exactly one character, so indices in
    // [folded] are valid in [text].
    for (final term in terms) {
      final t = fold(term.toLowerCase());
      if (t.isEmpty) continue;
      final re = RegExp('(?<![\\p{L}\\p{N}])${RegExp.escape(t)}', unicode: true);
      final m = re.firstMatch(folded);
      if (m == null) continue;
      var start = (m.start - radius).clamp(0, text.length);
      var end = (m.end + radius).clamp(0, text.length);
      // Do not cut words in half.
      while (start > 0 && !_isBoundary(text.codeUnitAt(start - 1))) {
        start--;
      }
      while (end < text.length && !_isBoundary(text.codeUnitAt(end))) {
        end++;
      }
      final body = text.substring(start, end).replaceAll(RegExp(r'\s*\n\s*'), ' · ').trim();
      return '${start > 0 ? '…' : ''}$body${end < text.length ? '…' : ''}';
    }
    return null;
  }

  static bool _isBoundary(int c) => c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D;

  /// Folds common Latin diacritics to their base letter, one character in,
  /// one character out (so string indices are preserved).
  static String fold(String s) {
    var changed = false;
    final out = StringBuffer();
    for (final rune in s.runes) {
      final r = _fold[rune];
      if (r != null) {
        out.writeCharCode(r);
        changed = true;
      } else {
        out.writeCharCode(rune);
      }
    }
    return changed ? out.toString() : s;
  }

  static final Map<int, int> _fold = () {
    const groups = {
      'a': 'àáâãäåāăą',
      'c': 'çćĉċč',
      'd': 'ďđ',
      'e': 'èéêëēĕėęě',
      'g': 'ĝğġģ',
      'h': 'ĥħ',
      'i': 'ìíîïĩīĭįı',
      'j': 'ĵ',
      'k': 'ķ',
      'l': 'ĺļľŀł',
      'n': 'ñńņňŉ',
      'o': 'òóôõöøōŏő',
      'r': 'ŕŗř',
      's': 'śŝşšș',
      't': 'ţťŧț',
      'u': 'ùúûüũūŭůűų',
      'w': 'ŵ',
      'y': 'ýÿŷ',
      'z': 'źżž',
    };
    final m = <int, int>{};
    groups.forEach((base, chars) {
      for (final r in chars.runes) {
        m[r] = base.codeUnitAt(0);
      }
    });
    return m;
  }();
}
