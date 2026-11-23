import 'dart:io';

import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../domain/interfaces.dart';

/// On-device OCR with Google ML Kit Text Recognition v2, Latin script.
///
/// The Latin model is bundled in the APK (`com.google.mlkit:text-recognition`,
/// pulled in by `google_mlkit_text_recognition`), so nothing is downloaded at
/// runtime. Non-Latin scripts (Chinese, Devanagari, Japanese, Korean, Arabic,
/// Cyrillic beyond Latin look-alikes) are not recognised.
///
/// One native recognizer is created lazily and reused for every image, because
/// creating a recognizer loads the model. Recognition runs on ML Kit's own
/// worker thread, not the UI thread (timings: docs/AI_PIPELINE.md). The file is
/// decoded natively by ML Kit (EXIF orientation is honoured).
class MlKitOcrEngine implements OcrEngine {
  MlKitOcrEngine();

  TextRecognizer? _recognizer;
  bool _disposed = false;

  TextRecognizer get _instance => _recognizer ??= TextRecognizer(script: TextRecognitionScript.latin);

  @override
  Future<String> recognize(File imageFile) async {
    if (_disposed) throw OcrException('OCR engine has been disposed');
    if (!await imageFile.exists()) {
      throw OcrException('File not found: ${imageFile.path}');
    }
    try {
      final result = await _instance.processImage(InputImage.fromFile(imageFile));
      return joinRecognizedLines(result.blocks.map((b) => b.lines.map((l) => l.text)));
    } on PlatformException catch (e) {
      throw OcrException('Text recognition failed: ${e.code} ${e.message ?? ''}'.trim());
    } on OcrException {
      rethrow;
    } catch (e) {
      throw OcrException('Text recognition failed: $e');
    }
  }

  /// Lines in reading order (blocks as ML Kit returns them, top-to-bottom
  /// lines within a block), trimmed, joined with '\n'.
  static String joinRecognizedLines(Iterable<Iterable<String>> blocks) => [
        for (final block in blocks)
          for (final line in block)
            if (line.trim().isNotEmpty) line.trim(),
      ].join('\n');

  @override
  Future<void> dispose() async {
    _disposed = true;
    final r = _recognizer;
    _recognizer = null;
    await r?.close();
  }
}
