import 'dart:io';

import 'package:ai_gallery/domain/interfaces.dart';
import 'package:ai_gallery/ml/ocr/mlkit_ocr_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lines are trimmed, blank lines dropped, joined with newlines in block order', () {
    final text = MlKitOcrEngine.joinRecognizedLines([
      ['  Jamie ', ''],
      ['Hey! Are we still on?', '   ', 'See you at 10:40'],
    ]);
    expect(text, 'Jamie\nHey! Are we still on?\nSee you at 10:40');
    expect(MlKitOcrEngine.joinRecognizedLines(const []), '');
  });

  test('missing file and disposed engine raise OcrException', () async {
    final engine = MlKitOcrEngine();
    await expectLater(engine.recognize(File('does/not/exist.jpg')), throwsA(isA<OcrException>()));
    await engine.dispose();
    await expectLater(engine.recognize(File('does/not/exist.jpg')), throwsA(isA<OcrException>()));
  });
}
