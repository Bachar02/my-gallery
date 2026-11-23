/// Version of the indexing pipeline (OCR settings, text joining, dHash,
/// embedding model and preprocessing). Bump it whenever any of these change
/// so existing records are re-processed on the next sync.
const int kPipelineVersion = 1;

/// The value stored in [IndexRecord.pipelineVersion]:
/// `kPipelineVersion * 10 + 1` when the record has an image embedding,
/// `kPipelineVersion * 10` when it was indexed text-only (the semantic model
/// was unavailable or failed for that image). A text-only record is
/// re-processed once the model becomes available, so embeddings are
/// backfilled without a pipeline bump.
int pipelineStamp({required bool withEmbedding}) => kPipelineVersion * 10 + (withEmbedding ? 1 : 0);

/// Whether a record stored with [stamp] is current for this pipeline when the
/// semantic model is ([modelAvailable]) or is not available.
bool isStampCurrent(int stamp, {required bool modelAvailable}) {
  if (stamp ~/ 10 != kPipelineVersion) return false;
  final hasEmbedding = stamp % 10 == 1;
  return hasEmbedding || !modelAvailable;
}
