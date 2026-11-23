import 'dart:convert';

import 'package:ai_gallery/app/licenses.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bundle extends CachingAssetBundle {
  _Bundle(this.files);
  final Map<String, String> files;

  @override
  Future<ByteData> load(String key) async {
    final text = files[key];
    if (text == null) throw StateError('missing $key');
    return ByteData.sublistView(utf8.encode(text));
  }
}

void main() {
  test('includes MobileCLIP texts, ONNX Runtime and ML Kit', () async {
    final entries = await appLicenses(_Bundle({
      'assets/models/mobileclip_s0/LICENSE_APPLE_AMLR.txt': 'Apple AMLR text',
      'assets/models/mobileclip_s0/LICENSE_XENOVA_EXPORT.txt': 'Xenova export text',
    })).toList();
    final byName = {for (final e in entries) e.packages.single: e.paragraphs.map((p) => p.text).join('\n')};
    expect(byName['MobileCLIP'], allOf(contains('Apple AMLR text'), contains('Xenova export text')));
    expect(byName['ONNX Runtime'], contains('MIT License'));
    expect(byName['Google ML Kit'], contains('https://developers.google.com/ml-kit/terms'));
  });

  test('missing assets do not throw', () async {
    final entries = await appLicenses(_Bundle({})).toList();
    expect(entries.map((e) => e.packages.single), ['ONNX Runtime', 'Google ML Kit']);
  });
}
