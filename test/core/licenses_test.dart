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
  test('includes SigLIP notice and licence, ONNX Runtime and ML Kit', () async {
    final entries = await appLicenses(_Bundle({
      'assets/models/siglip_b16/NOTICE.txt': 'SigLIP notice',
      'assets/models/siglip_b16/LICENSE_APACHE_2.0.txt': 'Apache licence text',
    })).toList();
    final byName = {for (final e in entries) e.packages.single: e.paragraphs.map((p) => p.text).join('\n')};
    expect(byName['SigLIP (Google)'], allOf(contains('SigLIP notice'), contains('Apache licence text')));
    expect(byName['ONNX Runtime'], contains('MIT License'));
    expect(byName['Google ML Kit'], contains('https://developers.google.com/ml-kit/terms'));
  });

  test('missing assets do not throw', () async {
    final entries = await appLicenses(_Bundle({})).toList();
    expect(entries.map((e) => e.packages.single), ['ONNX Runtime', 'Google ML Kit']);
  });
}
