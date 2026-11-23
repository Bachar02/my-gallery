import 'dart:convert';
import 'dart:io';

import 'package:ai_gallery/ml/clip/clip_tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reference ids come from the Hugging Face tokenizer of the same export
/// (tool/clip_reference.py -> test/ml/fixtures/clip_tokenizer_cases.json).
void main() {
  late ClipTokenizer tokenizer;

  setUpAll(() {
    tokenizer = ClipTokenizer.fromMerges(File('assets/models/mobileclip_s0/bpe_merges.txt').readAsStringSync());
  });

  test('vocabulary derived from merges has the CLIP size and special ids', () {
    expect(tokenizer.vocabSize, 49408);
    expect(tokenizer.startOfTextId, 49406);
    expect(tokenizer.endOfTextId, 49407);
  });

  final cases = (jsonDecode(File('test/ml/fixtures/clip_tokenizer_cases.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  for (final c in cases) {
    final text = c['text'] as String;
    test('matches reference ids: ${jsonEncode(text.length > 40 ? '${text.substring(0, 40)}...' : text)}', () {
      final expected = (c['ids'] as List).cast<int>();
      expect(tokenizer.encode(text).toList(), expected);
    });
  }

  test('output is always 77 ids, SOT first, EOT present, zero padded', () {
    final ids = tokenizer.encode('a red car');
    expect(ids.length, ClipTokenizer.contextLength);
    expect(ids.first, 49406);
    final eot = ids.indexOf(49407);
    expect(eot, greaterThan(0));
    expect(ids.sublist(eot + 1).every((v) => v == 0), isTrue);
  });

  test('long input is truncated with EOT as the last token', () {
    final ids = tokenizer.encode(List.filled(200, 'word').join(' '));
    expect(ids.length, 77);
    expect(ids.last, 49407);
  });
}
