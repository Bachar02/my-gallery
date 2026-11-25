import 'dart:io';

import 'package:ai_gallery/ml/siglip/siglip_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bundled model files exist with the sizes the loader expects', () {
    expect(File(SiglipAssets.vision).lengthSync(), SiglipAssets.visionBytes);
    expect(File(SiglipAssets.text).lengthSync(), SiglipAssets.textBytes);
    expect(File(SiglipAssets.vocab).existsSync(), isTrue);
  });

  test('the research-only MobileCLIP weights are no longer bundled', () {
    expect(Directory('assets/models/mobileclip_s0').existsSync(), isFalse);
    expect(File('pubspec.yaml').readAsStringSync(), isNot(contains('mobileclip')));
  });

  test('model files are registered as Flutter assets', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- ${SiglipAssets.dir}'));
  });

  test('load() returns false instead of throwing when the runtime is unavailable', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = Directory.systemTemp.createTempSync('siglip');
    addTearDown(() => dir.deleteSync(recursive: true));
    final model = SiglipModel(modelDirectory: () async => dir);
    // Assets are bundled in unit tests, but there is no ONNX Runtime plugin
    // on the host: session creation fails and the loader must fail softly.
    expect(await model.load(), isFalse);
    expect(model.isLoaded, isFalse);
    expect(model.lastLoadError, isNotNull);
    expect(() => model.embedText('a red car'), throwsStateError);
  });
}
