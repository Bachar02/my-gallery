// On-device checks for the ML stack: MobileCLIP via ONNX Runtime must
// reproduce the desktop reference embeddings (tool/clip_reference.py), and
// ML Kit OCR must read rendered text. Also prints latencies.
//
// Run: flutter test integration_test/ml/clip_test.dart -d <device>
import 'dart:convert';
import 'dart:io';

import 'package:ai_gallery/ml/clip/mobile_clip_model.dart';
import 'package:ai_gallery/ml/clip/vector_ops.dart';
import 'package:ai_gallery/ml/ocr/mlkit_ocr_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'clip_fixtures.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final model = MobileClipModel();

  setUpAll(() async {
    final sw = Stopwatch()..start();
    final ok = await model.load();
    debugPrint('[ml-bench] model load: ${sw.elapsedMilliseconds} ms');
    expect(ok, isTrue, reason: 'MobileClipModel.load failed: ${model.lastLoadError}');
  });

  tearDownAll(() => model.dispose());

  test('image embeddings match the desktop reference (cosine > 0.99)', () async {
    for (final entry in kFixtureImagesBase64.entries) {
      final emb = await model.embedImage(base64Decode(entry.value));
      expect(emb.length, 512);
      final cos = cosine(emb, kExpectedImageEmbeddings[entry.key]!);
      debugPrint('[ml-bench] image ${entry.key}: cosine to reference ${cos.toStringAsFixed(5)}');
      expect(cos, greaterThan(0.99), reason: entry.key);
    }
  });

  test('text embeddings match the desktop reference (cosine > 0.99)', () async {
    for (final entry in kExpectedTextEmbeddings.entries) {
      final emb = await model.embedText(entry.key);
      final cos = cosine(emb, entry.value);
      debugPrint('[ml-bench] text "${entry.key}": cosine to reference ${cos.toStringAsFixed(5)}');
      expect(cos, greaterThan(0.99), reason: entry.key);
    }
  });

  test('each test image is closest to its own description', () async {
    const pairs = {
      'red_car': 'a red car',
      'cat': 'a cat sleeping on a keyboard',
      'menu': 'a restaurant menu',
      'chat_screenshot': 'a screenshot of a chat conversation',
    };
    final texts = {for (final t in kExpectedTextEmbeddings.keys) t: await model.embedText(t)};
    for (final p in pairs.entries) {
      final image = await model.embedImage(base64Decode(kFixtureImagesBase64[p.key]!));
      final sims = {for (final t in texts.entries) t.key: dot(image, t.value)};
      final best = sims.entries.reduce((a, b) => a.value >= b.value ? a : b);
      expect(best.key, p.value, reason: '${p.key}: $sims');
    }
  });

  test('latency', () async {
    final bytes = base64Decode(kFixtureImagesBase64['menu']!);
    await model.embedImage(bytes); // warm-up
    await model.embedText('warm up');
    const n = 10;
    var sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      await model.embedImage(bytes);
    }
    final imageMs = sw.elapsedMilliseconds / n;
    sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      await model.embedText('a restaurant menu $i');
    }
    final textMs = sw.elapsedMilliseconds / n;
    debugPrint('[ml-bench] embedImage avg ${imageMs.toStringAsFixed(1)} ms (decode+preprocess+inference), '
        'embedText avg ${textMs.toStringAsFixed(1)} ms');
    expect(imageMs, lessThan(5000));
  });

  test('ML Kit OCR reads rendered text', () async {
    final canvas = img.Image(width: 900, height: 360);
    img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
    img.drawString(canvas, 'Jamie', font: img.arial48, x: 40, y: 40, color: img.ColorRgb8(0, 0, 0));
    img.drawString(canvas, 'IBAN DE89 3704 0044', font: img.arial48, x: 40, y: 140, color: img.ColorRgb8(0, 0, 0));
    img.drawString(canvas, 'Flight lands 10:40', font: img.arial48, x: 40, y: 240, color: img.ColorRgb8(0, 0, 0));
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/ocr_check.png')..writeAsBytesSync(Uint8List.fromList(img.encodePng(canvas)));

    final ocr = MlKitOcrEngine();
    try {
      await ocr.recognize(file); // warm-up (model load)
      final sw = Stopwatch()..start();
      final text = await ocr.recognize(file);
      debugPrint('[ml-bench] OCR 900x360: ${sw.elapsedMilliseconds} ms -> ${jsonEncode(text)}');
      expect(text, contains('Jamie'));
      expect(text.toUpperCase(), contains('IBAN'));
      expect(text.split('\n').length, greaterThanOrEqualTo(3));
    } finally {
      await ocr.dispose();
      file.deleteSync();
    }
  });
}
