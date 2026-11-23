import 'package:flutter/material.dart';

import '../design/app_colors.dart';

/// Renders [text] with every case-insensitive occurrence of [terms]
/// highlighted (used for OCR snippets in "Why this matched").
class HighlightedText extends StatelessWidget {
  const HighlightedText(this.text, {super.key, required this.terms, this.style, this.maxLines});

  final String text;
  final List<String> terms;
  final TextStyle? style;
  final int? maxLines;

  /// Splits [text] into (segment, isMatch) pieces. Longer terms win when
  /// matches overlap. Exposed for testing.
  static List<(String, bool)> segments(String text, List<String> terms) {
    final cleaned = terms.map((t) => t.trim()).where((t) => t.isNotEmpty).toSet().toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (cleaned.isEmpty || text.isEmpty) return [(text, false)];
    final pattern = RegExp(cleaned.map(RegExp.escape).join('|'), caseSensitive: false, unicode: true);
    final out = <(String, bool)>[];
    var last = 0;
    for (final m in pattern.allMatches(text)) {
      if (m.end == m.start) continue;
      if (m.start > last) out.add((text.substring(last, m.start), false));
      out.add((text.substring(m.start, m.end), true));
      last = m.end;
    }
    if (last < text.length) out.add((text.substring(last), false));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppSemanticColors.of(context);
    final base = style ?? DefaultTextStyle.of(context).style;
    final spans = [
      for (final (segment, match) in segments(text, terms))
        TextSpan(
          text: segment,
          style: match
              ? TextStyle(
                  backgroundColor: colors.highlight,
                  color: colors.onHighlight,
                  fontWeight: FontWeight.w700,
                )
              : null,
        ),
    ];
    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}
