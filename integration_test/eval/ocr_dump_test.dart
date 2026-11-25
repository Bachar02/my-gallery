// Extracts real on-device features for the offline search evaluation:
// ML Kit OCR lines with positions and face counts for every image of the
// evaluation corpus (tool/eval/), written as JSON for tool/eval/pull_features.py.
//
// Run through tool/eval/device_features.py, which installs the app, pushes the
// corpus into the app's external files directory (eval/in/), runs this test
// and pulls eval/out/features.json. The test waits for eval/in/READY so the
// files can be pushed after installation.
import 'dart:convert';
import 'dart:io';

import 'package:ai_gallery/ml/face/mlkit_face_counter.dart';
import 'package:ai_gallery/ml/ocr/mlkit_ocr_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('dump OCR layout and face counts of the evaluation corpus', () async {
    final base = (await getExternalStorageDirectory())!;
    final input = Directory(p.join(base.path, 'eval', 'in'));
    final out = Directory(p.join(base.path, 'eval', 'out'))..createSync(recursive: true);
    debugPrint('[eval] waiting for ${input.path}/READY');
    final ready = File(p.join(input.path, 'READY'));
    final deadline = DateTime.now().add(const Duration(minutes: 20));
    while (!ready.existsSync()) {
      if (DateTime.now().isAfter(deadline)) fail('corpus was not pushed');
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    final files = input
        .listSync()
        .whereType<File>()
        .where((f) => RegExp(r'\.(png|jpe?g)$', caseSensitive: false).hasMatch(f.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final ocr = MlKitOcrEngine();
    final faces = MlKitFaceCounter();
    final result = <String, Object?>{};
    final sw = Stopwatch()..start();
    var ocrMs = 0, faceMs = 0;
    for (final (i, f) in files.indexed) {
      final id = p.basenameWithoutExtension(f.path);
      final t0 = sw.elapsedMilliseconds;
      final r = await ocr.recognize(f);
      final t1 = sw.elapsedMilliseconds;
      final n = await faces.countFaces(f);
      final t2 = sw.elapsedMilliseconds;
      ocrMs += t1 - t0;
      faceMs += t2 - t1;
      result[id] = {
        'faces': n,
        'lines': [
          for (final l in r.lines)
            [l.text, _r(l.left), _r(l.top), _r(l.right), _r(l.bottom), l.block],
        ],
      };
      if (i % 50 == 0) debugPrint('[eval] $i/${files.length}');
    }
    File(p.join(out.path, 'features.json')).writeAsStringSync(jsonEncode(result));
    File(p.join(out.path, 'DONE')).writeAsStringSync('${files.length}');
    debugPrint('[eval] done ${files.length} images; avg OCR ${ocrMs ~/ files.length} ms, '
        'avg face count ${faceMs ~/ files.length} ms');
    await ocr.dispose();
    await faces.dispose();
  }, timeout: const Timeout(Duration(minutes: 60)));
}

double _r(double v) => (v * 10000).round() / 10000;
