import 'dart:math';
import 'dart:typed_data';

import 'package:ai_gallery/domain/models.dart';

final DateTime baseTime = DateTime(2025, 6, 1, 12);

GalleryImage image(
  String id, {
  String? filename,
  DateTime? createdAt,
  DateTime? modifiedAt,
  ImageKind kind = ImageKind.photo,
}) {
  final created = createdAt ?? baseTime;
  return GalleryImage(
    id: id,
    filename: filename ?? 'IMG_$id.jpg',
    relativePath: kind == ImageKind.screenshot ? 'Pictures/Screenshots/' : 'DCIM/Camera/',
    mimeType: 'image/jpeg',
    width: 1080,
    height: 1920,
    createdAt: created,
    modifiedAt: modifiedAt ?? created,
    kind: kind,
  );
}

IndexRecord record(
  String id, {
  String ocr = '',
  String? filename,
  DateTime? createdAt,
  ImageKind kind = ImageKind.photo,
  Float32List? embedding,
  String? model = 'mobileclip_s0',
  int? phash,
  int pipelineVersion = 1,
  DateTime? indexedAt,
}) =>
    IndexRecord(
      image: image(id, filename: filename, createdAt: createdAt, kind: kind),
      ocrText: ocr,
      embedding: embedding,
      embeddingModel: embedding == null ? null : model,
      perceptualHash: phash,
      indexedAt: indexedAt ?? baseTime.add(const Duration(days: 1)),
      pipelineVersion: pipelineVersion,
    );

/// Random L2-normalised vector.
Float32List unitVector(Random rnd, int dim) {
  final v = Float32List(dim);
  var norm = 0.0;
  for (var i = 0; i < dim; i++) {
    final x = rnd.nextDouble() * 2 - 1;
    v[i] = x;
    norm += x * x;
  }
  norm = sqrt(norm);
  for (var i = 0; i < dim; i++) {
    v[i] = v[i] / norm;
  }
  return v;
}

double dot(Float32List a, Float32List b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    s += a[i] * b[i];
  }
  return s;
}
