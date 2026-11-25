import 'dart:typed_data';

/// SigLIP text tokenizer: SentencePiece Unigram (32 000 pieces), a pure-Dart
/// port of the Hugging Face `tokenizers` pipeline of `google/siglip-base-patch16-224`:
///
///  1. normalise: whitespace characters become spaces, runs of two or more
///     spaces become one (the export's `Replace(" {2,}", " ")`; its
///     precompiled NFKC map leaves the text the app produces, lower-case
///     Latin captions, unchanged);
///  2. Metaspace: spaces become `▁`, a `▁` is prepended (unless already
///     there; empty text stays empty), and the text is split
///     before every `▁`;
///  3. Unigram Viterbi segmentation of each word: highest total log-probability,
///     ties resolved like `tokenizers` (first best found, shorter pieces
///     first); a character no piece covers becomes `<unk>` with score
///     `min score - 10`, consecutive unknowns fused;
///  4. `</s>` appended, truncated to [contextLength] (keeping `</s>`), padded
///     with `</s>` (the pad token of the export).
///
/// Verified against the reference ids of the Hugging Face tokenizer
/// (test/ml/siglip_tokenizer_test.dart).
class SiglipTokenizer {
  SiglipTokenizer._(this._pieces, this._unkScore, this._maxLen);

  /// [vocab]: one piece per line as `score<TAB>piece`, in id order (the
  /// format written by tool/install_assets.py).
  factory SiglipTokenizer.fromVocab(String vocab) {
    final pieces = <String, (int, double)>{};
    var minScore = double.infinity;
    var maxLen = 1;
    var id = 0;
    for (final line in vocab.split('\n')) {
      if (line.isEmpty) continue;
      final tab = line.indexOf('\t');
      final score = double.parse(line.substring(0, tab));
      final piece = line.substring(tab + 1);
      // Special/byte pieces are never produced by segmentation.
      if (id >= _firstNormalId) {
        pieces[piece] = (id, score);
        if (score < minScore) minScore = score;
        final len = piece.runes.length;
        if (len > maxLen) maxLen = len;
      }
      id++;
    }
    return SiglipTokenizer._(pieces, minScore - _unkPenalty, maxLen);
  }

  static const int contextLength = 64;
  static const int padId = 1;
  static const int eosId = 1;
  static const int unkId = 2;
  static const double _unkPenalty = 10.0;

  /// Ids 0..258 are `<pad>`, `</s>`, `<unk>` and the 256 byte pieces.
  static const int _firstNormalId = 259;

  final Map<String, (int, double)> _pieces;
  final double _unkScore;
  final int _maxLen;

  static final RegExp _whitespace = RegExp(r'[\t\n\r\f\v   -     　]');
  static final RegExp _multiSpace = RegExp(r' {2,}');

  /// Token ids without padding (ends with `</s>`), at most [contextLength].
  List<int> tokenize(String text) {
    final normalized = text.replaceAll(_whitespace, ' ').replaceAll(_multiSpace, ' ');
    var meta = normalized.replaceAll(' ', '▁');
    // Metaspace "always": prepend ▁ unless the text already starts with one;
    // empty text stays empty.
    if (meta.isNotEmpty && !meta.startsWith('▁')) meta = '▁$meta';
    final ids = <int>[];
    // Split before every ▁ (each word keeps its leading ▁).
    var start = 0;
    for (var i = 1; i <= meta.length; i++) {
      if (i == meta.length || meta.codeUnitAt(i) == 0x2581) {
        ids.addAll(_segment(meta.substring(start, i)));
        start = i;
      }
    }
    if (ids.length > contextLength - 1) ids.length = contextLength - 1;
    ids.add(eosId);
    return ids;
  }

  /// Padded to [contextLength], as the text encoder expects.
  Int64List encode(String text) {
    final ids = tokenize(text);
    final out = Int64List(contextLength)..fillRange(0, contextLength, padId);
    for (var i = 0; i < ids.length; i++) {
      out[i] = ids[i];
    }
    return out;
  }

  List<int> _segment(String word) {
    if (word.isEmpty) return const [];
    final chars = word.runes.map(String.fromCharCode).toList();
    final n = chars.length;
    final bestScore = List<double>.filled(n + 1, double.negativeInfinity);
    final bestId = List<int>.filled(n + 1, -1);
    final bestStart = List<int>.filled(n + 1, -1);
    bestScore[0] = 0;
    for (var s = 0; s < n; s++) {
      if (bestScore[s] == double.negativeInfinity) continue;
      var single = false;
      final buf = StringBuffer();
      for (var len = 1; len <= _maxLen && s + len <= n; len++) {
        buf.write(chars[s + len - 1]);
        final hit = _pieces[buf.toString()];
        if (hit == null) continue;
        if (len == 1) single = true;
        final score = bestScore[s] + hit.$2;
        final end = s + len;
        if (bestId[end] == -1 || score > bestScore[end]) {
          bestScore[end] = score;
          bestId[end] = hit.$1;
          bestStart[end] = s;
        }
      }
      if (!single) {
        final score = bestScore[s] + _unkScore;
        final end = s + 1;
        if (bestId[end] == -1 || score > bestScore[end]) {
          bestScore[end] = score;
          bestId[end] = unkId;
          bestStart[end] = s;
        }
      }
    }
    final out = <int>[];
    for (var end = n; end > 0; end = bestStart[end]) {
      out.add(bestId[end]);
    }
    final ids = out.reversed.toList();
    // Fuse consecutive unknowns.
    final fused = <int>[];
    for (final id in ids) {
      if (id == unkId && fused.isNotEmpty && fused.last == unkId) continue;
      fused.add(id);
    }
    return fused;
  }
}
