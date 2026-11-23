/// Safe construction of FTS5 MATCH expressions from user text.
///
/// User input never reaches FTS5 as syntax. Every term or phrase is reduced
/// to its word characters (letters, digits, marks), and each part becomes one
/// double-quoted FTS5 string, so operators (`AND`, `OR`, `NOT`, `NEAR`),
/// column filters (`:`), prefix stars, `^`, `-`, parentheses and quotes are
/// all neutralised. Inner double quotes are doubled anyway as a second line
/// of defence.
library;

/// One searchable part: a prefix term or a verbatim phrase.
class FtsPart {
  const FtsPart({required this.label, required this.expression});

  /// The caller's term/phrase (trimmed); reported in `TextHit.matchedTerms`.
  final String label;

  /// FTS5 expression matching just this part, e.g. `"invoice"*`.
  final String expression;
}

class FtsQuery {
  const FtsQuery(this.parts);
  final List<FtsPart> parts;

  bool get isEmpty => parts.isEmpty;

  /// All parts OR-ed together, so partial coverage still matches.
  String get expression => parts.map((p) => p.expression).join(' OR ');
}

final RegExp _wordRe = RegExp(r'[\p{L}\p{N}\p{M}\p{Co}]+', unicode: true);

/// FTS5 keywords. They are inert inside a quoted string, but a bare
/// operator typed as a *term* carries no content, so it is dropped.
const Set<String> _operators = {'AND', 'OR', 'NOT', 'NEAR'};

List<String> _words(String s) => [for (final m in _wordRe.allMatches(s)) m[0]!];

String _quote(List<String> words) => '"${words.join(' ').replaceAll('"', '""')}"';

/// Builds the query. [terms] match as prefixes (`"term"*`); a term with
/// punctuation inside (`e-mail`) becomes a prefix phrase (`"e mail"*`).
/// [phrases] match verbatim as consecutive tokens. Empty / punctuation-only
/// inputs are ignored; duplicates (case-insensitive) are merged.
FtsQuery buildFtsQuery(List<String> terms, List<String> phrases) {
  final parts = <FtsPart>[];
  final seen = <String>{};

  for (final raw in terms) {
    final label = raw.trim();
    final words = _words(label).where((w) => !_operators.contains(w)).toList();
    if (words.isEmpty) continue;
    final expr = '${_quote(words)}*';
    if (seen.add(expr.toLowerCase())) parts.add(FtsPart(label: label, expression: expr));
  }
  for (final raw in phrases) {
    final label = raw.trim();
    final words = _words(label);
    if (words.isEmpty) continue;
    final expr = _quote(words);
    if (seen.add(expr.toLowerCase())) parts.add(FtsPart(label: label, expression: expr));
  }
  return FtsQuery(parts);
}
