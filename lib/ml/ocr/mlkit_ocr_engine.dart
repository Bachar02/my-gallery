import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../domain/interfaces.dart';
import '../../domain/models.dart';

/// A recognised line in image pixels, before normalisation.
typedef RawOcrLine = ({String text, double left, double top, double right, double bottom});

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
///
/// Every line keeps its bounding box, normalised to the image size, so the
/// layout (chat header, message bubbles, input bar) can be analysed later.
class MlKitOcrEngine implements OcrEngine {
  MlKitOcrEngine();

  TextRecognizer? _recognizer;
  bool _disposed = false;

  TextRecognizer get _instance => _recognizer ??= TextRecognizer(script: TextRecognitionScript.latin);

  @override
  Future<OcrResult> recognize(File imageFile) async {
    if (_disposed) throw OcrException('OCR engine has been disposed');
    if (!await imageFile.exists()) {
      throw OcrException('File not found: ${imageFile.path}');
    }
    try {
      final result = await _instance.processImage(InputImage.fromFile(imageFile));
      final blocks = [
        for (final b in result.blocks)
          [
            for (final l in b.lines)
              (
                text: l.text,
                left: l.boundingBox.left,
                top: l.boundingBox.top,
                right: l.boundingBox.right,
                bottom: l.boundingBox.bottom,
              ),
          ],
      ];
      final size = await _imageSize(imageFile);
      return buildResult(blocks, width: size?.$1, height: size?.$2);
    } on PlatformException catch (e) {
      throw OcrException('Text recognition failed: ${e.code} ${e.message ?? ''}'.trim());
    } on OcrException {
      rethrow;
    } catch (e) {
      throw OcrException('Text recognition failed: $e');
    }
  }

  /// Encoded width/height read from the image header (no full decode).
  static Future<(double, double)?> _imageSize(File f) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(f.path);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = (descriptor.width.toDouble(), descriptor.height.toDouble());
      descriptor.dispose();
      buffer.dispose();
      return size;
    } catch (_) {
      return null;
    }
  }

  /// Joins lines (blocks in ML Kit order, lines top to bottom within a block,
  /// trimmed, blank lines dropped) and normalises their boxes to 0..1 of the
  /// image. ML Kit reports boxes in the EXIF-rotated frame while the header
  /// gives the stored size, so width and height are swapped when the boxes
  /// only fit that way. Without a size the extent of the boxes is used.
  @visibleForTesting
  static OcrResult buildResult(List<List<RawOcrLine>> blocks, {double? width, double? height}) {
    final kept = <(int, RawOcrLine)>[
      for (final (i, block) in blocks.indexed)
        for (final l in block)
          if (l.text.trim().isNotEmpty) (i, l),
    ];
    if (kept.isEmpty) return OcrResult.empty;
    final maxX = kept.map((e) => e.$2.right).reduce(math.max);
    final maxY = kept.map((e) => e.$2.bottom).reduce(math.max);
    var w = width ?? 0, h = height ?? 0;
    bool fits(double w, double h) => w > 0 && h > 0 && maxX <= w * 1.02 && maxY <= h * 1.02;
    if (!fits(w, h)) {
      if (fits(h, w)) {
        (w, h) = (h, w);
      } else {
        w = math.max(w, maxX);
        h = math.max(h, maxY);
      }
    }
    double nx(double v) => (v / w).clamp(0.0, 1.0);
    double ny(double v) => (v / h).clamp(0.0, 1.0);
    final lines = [
      for (final (block, l) in kept)
        OcrLine(l.text.trim(), nx(l.left), ny(l.top), nx(l.right), ny(l.bottom), block: block),
    ];
    return OcrResult(text: lines.map((l) => l.text).join('\n'), lines: lines);
  }

  /// Lines in reading order (blocks as ML Kit returns them, top-to-bottom
  /// lines within a block), trimmed, blank lines dropped, joined with '\n'.
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
