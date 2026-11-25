import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../../domain/interfaces.dart';

/// Counts faces with ML Kit Face Detection (bundled model,
/// `com.google.mlkit:face-detection`, nothing downloaded at runtime).
///
/// Only the fast detector runs: landmarks, contours, classification (smile /
/// eyes open) and tracking are all disabled, and only the number of faces
/// leaves this class. Nothing about who a person is, or what they look like,
/// is computed or stored.
///
/// Faces smaller than [minFaceSize] (fraction of the image width) are not
/// detected: a "photo of a man" shows a person clearly, a face in the
/// background of a street scene does not make one.
class MlKitFaceCounter implements FaceCounter {
  MlKitFaceCounter({this.minFaceSize = 0.08});

  final double minFaceSize;
  FaceDetector? _detector;
  bool _disposed = false;

  FaceDetector get _instance => _detector ??= FaceDetector(
        options: FaceDetectorOptions(
          performanceMode: FaceDetectorMode.fast,
          minFaceSize: minFaceSize,
        ),
      );

  @override
  Future<int?> countFaces(File imageFile) async {
    if (_disposed || !await imageFile.exists()) return null;
    try {
      final faces = await _instance.processImage(InputImage.fromFile(imageFile));
      return faces.length;
    } catch (e) {
      debugPrint('Face count failed: ${e.runtimeType}');
      return null;
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    final d = _detector;
    _detector = null;
    await d?.close();
  }
}
