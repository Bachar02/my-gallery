/// Retrieval thresholds and weights for `HybridSearchEngine`.
///
/// All values are dimensionless. Calibration data and the procedure that
/// produced the visual thresholds are in docs/AI_PIPELINE.md
/// ("Thresholds and calibration"), reproducible with tool/calibrate_clip.py.
library;

abstract final class SearchTuning {
  // ------------------------------------------------------------ text (OCR)

  /// Hits requested from the store per query term.
  static const int textLimitPerTerm = 300;

  /// A text match is kept when its text score is at least this fraction of
  /// the best text score for the query. If some screenshot contains every
  /// query word, images that only contain one common word ("details") are
  /// dropped; if nothing contains every word, the best partial matches stay.
  static const double textRelativeCut = 0.4;

  /// Per-term strength = floor + (1 - floor) * bm25 / best bm25 for that term:
  /// containing the word matters most, bm25 only orders within that.
  static const double termStrengthFloor = 0.6;

  /// Strength multiplier when a term only matched as a prefix of a longer
  /// word ("car" in "cardigan"), verified against the OCR text.
  static const double prefixOnlyPenalty = 0.5;

  /// Weight of expansion matches relative to literal ones ("IBAN" found for
  /// "bank details" is good but indirect evidence).
  static const double expansionWeight = 0.55;

  // ------------------------------------------------------- visual (CLIP)

  /// Hits requested from the vector store.
  static const int vectorLimit = 200;

  /// Absolute cosine floor for a visual match (MobileCLIP-S0 text-image
  /// cosine, prompt `a photo of <query>`). Below this an image is not
  /// considered to depict the query, whatever the ranking says.
  /// Calibration (tool/calibrate_clip.py, 92 images x 36 queries): non-matching
  /// pairs p95 = 0.143, p99 = 0.188, synthetic screenshots p95 = 0.168; matching
  /// pairs median 0.223. At 0.20 none of the 5 queries without a matching image
  /// returned anything (0.19 let "purple elephant" match a bicycle at 0.190).
  static const double visualFloor = 0.20;

  /// A visual match must also be within this margin of the best visual
  /// match for the same query, so one strong match suppresses the long tail
  /// of weak ones. With floor 0.20: margin 0.05 -> recall 0.60 / precision 0.96,
  /// 0.07 -> 0.66 / 0.94, 0.10 -> 0.66 / 0.88 on the calibration set.
  static const double visualMargin = 0.07;

  /// Floor for visual-only results when another image already has strong
  /// text evidence (covers every query term). Chat screenshots all look
  /// alike to CLIP: for "bank details" on the test gallery the IBAN chat scored
  /// 0.264, but an unrelated chat 0.221 and a receipt 0.230 also passed the
  /// 0.20 floor and margin. 0.27 is above every non-matching screenshot in
  /// calibration except one outlier photo pair (max 0.279) and keeps the
  /// strongest true visual matches (0.27-0.33).
  static const double visualOnlyFloorWithStrongText = 0.27;

  /// Cosine at which visual evidence counts as full strength (score 1.0);
  /// strong matches in calibration were 0.25-0.33.
  static const double visualFull = 0.28;

  /// Visual evidence is weighted slightly below literal text evidence: text
  /// matches are exact, visual similarity is approximate.
  static const double visualWeight = 0.8;
  static const double textWeight = 1.0;

  // ------------------------------------------------------------- results

  /// Candidates verified against their stored record (exact-word check,
  /// snippet, near-duplicate hash).
  static const int verifyTopK = 150;

  static const int maxResults = 100;

  /// Near-duplicates: dHash distance (of 64 bits) at or below which two
  /// images look the same...
  static const int nearDuplicateBits = 5;

  /// ...and they were taken within this window (bursts), or have identical
  /// recognised text (the same screenshot saved twice). Two different chat
  /// screenshots of the same app can have close hashes, so hash alone is
  /// not enough.
  static const Duration burstWindow = Duration(minutes: 10);

  static const int snippetRadius = 48;
}
