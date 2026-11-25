/// Compact storage of OCR line layouts: a JSON array of
/// `[text, left, top, right, bottom, block]` with coordinates in 1/10000 of
/// the image size. About 30-40 bytes per line.
library;

import 'dart:convert';

import '../../domain/models.dart';

abstract final class LayoutCodec {
  static const int _scale = 10000;

  static String encode(List<OcrLine> lines) {
    if (lines.isEmpty) return '';
    int q(double v) => (v * _scale).round().clamp(0, _scale);
    return jsonEncode([
      for (final l in lines) [l.text, q(l.left), q(l.top), q(l.right), q(l.bottom), l.block],
    ]);
  }

  /// Malformed input yields an empty layout (the index is a rebuildable cache).
  static List<OcrLine> decode(String? encoded) {
    if (encoded == null || encoded.isEmpty) return const [];
    try {
      final rows = jsonDecode(encoded) as List<dynamic>;
      double d(Object? v) => (v as num).toDouble() / _scale;
      return List.unmodifiable([
        for (final r in rows.cast<List<dynamic>>())
          OcrLine(r[0] as String, d(r[1]), d(r[2]), d(r[3]), d(r[4]), block: r[5] as int),
      ]);
    } catch (_) {
      return const [];
    }
  }
}
