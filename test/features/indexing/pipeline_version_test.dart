import 'package:ai_gallery/features/indexing/pipeline_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stamp encodes pipeline version and embedding presence', () {
    expect(pipelineStamp(withEmbedding: true), kPipelineVersion * 10 + 1);
    expect(pipelineStamp(withEmbedding: false), kPipelineVersion * 10);
  });

  test('currency rules', () {
    final withEmb = pipelineStamp(withEmbedding: true);
    final textOnly = pipelineStamp(withEmbedding: false);
    expect(isStampCurrent(withEmb, modelAvailable: true), isTrue);
    expect(isStampCurrent(withEmb, modelAvailable: false), isTrue);
    expect(isStampCurrent(textOnly, modelAvailable: false), isTrue);
    expect(isStampCurrent(textOnly, modelAvailable: true), isFalse, reason: 'backfill embeddings');
    expect(isStampCurrent((kPipelineVersion - 1) * 10 + 1, modelAvailable: true), isFalse);
    expect(isStampCurrent(0, modelAvailable: false), isFalse);
  });
}
