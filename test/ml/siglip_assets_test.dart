import 'dart:io';

import 'package:ai_gallery/ml/clip/mobile_clip_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bundled model files exist with the sizes the loader expects', () {
    expect(File(MobileClipAssets.vision).lengthSync(), MobileClipAssets.visionBytes);
    expect(File(MobileClipAssets.text).lengthSync(), MobileClipAssets.textBytes);
    expect(File(MobileClipAssets.merges).existsSync(), isTrue);
  });

  test('model files are registered as Flutter assets', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- ${MobileClipAssets.dir}'));
  });

  test('load() returns false instead of throwing when the runtime is unavailable', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = Directory.systemTemp.createTempSync('clip');
    addTearDown(() => dir.deleteSync(recursive: true));
    final model = MobileClipModel(modelDirectory: () async => dir);
    // Assets are bundled in unit tests, but there is no ONNX Runtime plugin
    // on the host: session creation fails and the loader must fail softly.
    expect(await model.load(), isFalse);
    expect(model.isLoaded, isFalse);
    expect(model.lastLoadError, isNotNull);
    expect(() => model.embedText('a red car'), throwsStateError);
  });
}
