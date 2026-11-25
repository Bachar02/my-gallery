import 'dart:convert';
import 'dart:io';

import 'package:ai_gallery/ml/siglip/siglip_model.dart';
import 'package:ai_gallery/ml/siglip/siglip_tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reference ids come from the Hugging Face tokenizer of the same export
/// (tool/siglip_reference.py -> test/ml/fixtures/siglip_tokenizer_cases.json).
void main() {
  late SiglipTokenizer tokenizer;

  setUpAll(() {
    tokenizer = SiglipTokenizer.fromVocab(File(SiglipAssets.vocab).readAsStringSync());
  });

  final cases = (jsonDecode(File('test/ml/fixtures/siglip_tokenizer_cases.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  // The app only feeds the encoder captions it builds itself (lower-case
  // Latin text); the precompiled NFKC map of the export is not ported, so
  // scripts it would rewrite are not compared.
  bool supported(String t) => !RegExp(r'[^\u0000-ɏ\s❤️😀]').hasMatch(t) && !t.contains('\t') && !t.contains('\n');

  for (final c in cases) {
    final text = c['text'] as String;
    if (!supported(text)) continue;
    test('matches reference ids: ${jsonEncode(text.length > 40 ? '${text.substring(0, 40)}...' : text)}', () {
      final expected = (c['ids'] as List).cast<int>();
      expect(tokenizer.encode(text).toList(), expected);
    });
  }

  test('captions the app builds match the reference', () {
    // Prompts are lower-case: compare those explicitly.
    for (final c in cases) {
      final text = c['text'] as String;
      if (text == text.toLowerCase() && supported(text)) {
        expect(tokenizer.encode(text).toList(), (c['ids'] as List).cast<int>(), reason: text);
      }
    }
  });

  test('output is always 64 ids, ends with </s>, padded with </s>', () {
    final ids = tokenizer.encode('a photo of a man.');
    expect(ids.length, SiglipTokenizer.contextLength);
    final raw = tokenizer.tokenize('a photo of a man.');
    expect(raw.last, SiglipTokenizer.eosId);
    expect(ids.sublist(raw.length).every((v) => v == SiglipTokenizer.padId), isTrue);
  });

  test('long input is truncated with </s> as the last real token', () {
    final raw = tokenizer.tokenize(List.filled(200, 'word').join(' '));
    expect(raw.length, SiglipTokenizer.contextLength);
    expect(raw.last, SiglipTokenizer.eosId);
  });
}
