import 'dart:convert';
import 'dart:typed_data';

/// Byte-level BPE tokenizer used by CLIP / MobileCLIP text encoders.
///
/// Mirrors the Hugging Face `CLIPTokenizerFast` configuration shipped with
/// the MobileCLIP-S0 export:
///  * normalise: collapse whitespace runs to one space, lower-case
///    (Unicode NFC normalisation is not applied; precomposed input, which is
///    what Android keyboards produce, is unaffected),
///  * pre-tokenise with CLIP's pattern (contractions, letter runs, single
///    digits, punctuation runs),
///  * byte-level BPE with the `</w>` end-of-word suffix,
///  * `<|startoftext|>` ... `<|endoftext|>`, truncated and padded with id 0
///    to [contextLength] tokens.
///
/// The vocabulary is derived from the merge list: 256 byte symbols, the same
/// symbols with `</w>`, one token per merge, then the two special tokens.
/// `tool/install_assets.py` checks that this reproduces the exported vocab.
class ClipTokenizer {
  ClipTokenizer._(this._encoder, this._ranks);

  /// Builds a tokenizer from the text of `bpe_merges.txt` (one "a b" merge per
  /// line, in priority order).
  factory ClipTokenizer.fromMerges(String mergesText) {
    final merges = const LineSplitter()
        .convert(mergesText)
        .where((l) => l.isNotEmpty && !l.startsWith('#version'))
        .toList(growable: false);
    final symbols = _byteTable.vocabOrder;
    final vocab = <String>[
      ...symbols,
      for (final s in symbols) '$s</w>',
      for (final m in merges) m.replaceFirst(' ', ''),
      startOfText,
      endOfText,
    ];
    final encoder = <String, int>{};
    for (var i = 0; i < vocab.length; i++) {
      encoder[vocab[i]] = i;
    }
    final ranks = <String, int>{};
    for (var i = 0; i < merges.length; i++) {
      ranks[merges[i]] = i;
    }
    return ClipTokenizer._(encoder, ranks);
  }

  static const int contextLength = 77;
  static const String startOfText = '<|startoftext|>';
  static const String endOfText = '<|endoftext|>';
  static const int padId = 0;

  final Map<String, int> _encoder;
  final Map<String, int> _ranks;
  final Map<String, List<int>> _cache = {};

  int get vocabSize => _encoder.length;
  int get startOfTextId => _encoder[startOfText]!;
  int get endOfTextId => _encoder[endOfText]!;

  static final RegExp _whitespace = RegExp(r'\s+', unicode: true);
  static final RegExp _pattern = RegExp(
    r"'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+",
    unicode: true,
  );

  /// Token ids for [text] without special tokens and without truncation.
  List<int> tokenize(String text) {
    final normalized = text.replaceAll(_whitespace, ' ').toLowerCase();
    final ids = <int>[];
    for (final m in _pattern.allMatches(normalized)) {
      final piece = m[0]!;
      final cached = _cache[piece];
      if (cached != null) {
        ids.addAll(cached);
        continue;
      }
      final bytes = utf8.encode(piece);
      final symbols = _byteTable.byByte;
      final word = [for (final b in bytes) symbols[b]];
      final tokens = _bpe(word);
      final pieceIds = [for (final t in tokens) _encoder[t] ?? endOfTextId];
      if (_cache.length < 4096) _cache[piece] = pieceIds;
      ids.addAll(pieceIds);
    }
    return ids;
  }

  /// Model input: `[SOT, tokens..., EOT, 0, 0, ...]`, length [contextLength].
  /// Long inputs are truncated so that EOT is always present.
  Int64List encode(String text) {
    final tokens = tokenize(text);
    final maxTokens = contextLength - 2;
    final out = Int64List(contextLength); // zero-filled = padId
    out[0] = startOfTextId;
    final n = tokens.length < maxTokens ? tokens.length : maxTokens;
    for (var i = 0; i < n; i++) {
      out[i + 1] = tokens[i];
    }
    out[n + 1] = endOfTextId;
    return out;
  }

  List<String> _bpe(List<String> chars) {
    if (chars.isEmpty) return const [];
    var word = List<String>.of(chars);
    word[word.length - 1] = '${word.last}</w>';
    while (word.length > 1) {
      var bestRank = -1;
      var bestIndex = -1;
      for (var i = 0; i < word.length - 1; i++) {
        final r = _ranks['${word[i]} ${word[i + 1]}'];
        if (r != null && (bestRank < 0 || r < bestRank)) {
          bestRank = r;
          bestIndex = i;
        }
      }
      if (bestIndex < 0) break;
      final first = word[bestIndex];
      final second = word[bestIndex + 1];
      final merged = <String>[];
      var i = 0;
      while (i < word.length) {
        if (i < word.length - 1 && word[i] == first && word[i + 1] == second) {
          merged.add(first + second);
          i += 2;
        } else {
          merged.add(word[i]);
          i += 1;
        }
      }
      word = merged;
    }
    return word;
  }

  /// GPT-2 / CLIP reversible byte -> printable unicode mapping. `byByte` is
  /// indexed by byte value; `vocabOrder` is the order the symbols take in the
  /// vocabulary (printable bytes first).
  static final ({List<String> byByte, List<String> vocabOrder}) _byteTable = () {
    final bs = <int>[
      for (var b = 0x21; b <= 0x7E; b++) b,
      for (var b = 0xA1; b <= 0xAC; b++) b,
      for (var b = 0xAE; b <= 0xFF; b++) b,
    ];
    final cs = List<int>.of(bs);
    var n = 0;
    for (var b = 0; b < 256; b++) {
      if (!bs.contains(b)) {
        bs.add(b);
        cs.add(256 + n);
        n++;
      }
    }
    final byByte = List<String>.filled(256, '');
    for (var i = 0; i < bs.length; i++) {
      byByte[bs[i]] = String.fromCharCode(cs[i]);
    }
    return (byByte: byByte, vocabOrder: [for (final c in cs) String.fromCharCode(c)]);
  }();
}
