/// Per-model thresholds and prompts for visual (image-text) matching.
///
/// Cosine similarities are not comparable across models, so every bundled
/// model has its own calibration, measured with tool/eval/eval_models.py on
/// the evaluation corpus (docs/AI_PIPELINE.md, "Thresholds and calibration").
library;

class VisualCalibration {
  const VisualCalibration({
    required this.floor,
    required this.margin,
    required this.full,
    required this.strictFloor,
    required this.screenshotPenalty,
    required this.typographicPenalty,
    this._peopleFloor,
    this.photoPrompts = defaultPhotoPrompts,
    this.screenPrompts = defaultScreenPrompts,
  });

  /// Absolute cosine below which an image does not depict the query.
  final double floor;

  /// A visual match must be within this margin of the best match.
  final double margin;

  /// Cosine at which visual evidence counts as full strength.
  final double full;

  /// Floor for visual-only results of text and unknown-noun queries (the
  /// answer is normally written text; only a clear visual match may stand).
  final double strictFloor;

  /// Subtracted from the cosine of a UI screenshot for a query about a
  /// photographed thing ("a man", "pizza"): screens that merely show the word
  /// or a small picture rank below real photos.
  final double screenshotPenalty;

  /// Subtracted when the head noun is printed in the image ("MEN" on a shop
  /// screen for "a man"): CLIP-family models read text, so a printed word
  /// raises similarity without the thing being shown.
  final double typographicPenalty;
  final double? _peopleFloor;

  /// Captions for the text encoder; `{}` is replaced by the visual phrase
  /// and the embeddings are averaged. A single plain caption measured best
  /// for every model on the evaluation corpus (ensembles of 3-5 phrasings
  /// lowered mAP by 0.01-0.07).
  final List<String> photoPrompts;
  final List<String> screenPrompts;

  static const defaultPhotoPrompts = ['a photo of {}.'];
  static const defaultScreenPrompts = ['a screenshot of {}.'];

  /// Floor for people queries ("a man", "kids"): image-text similarity of
  /// people photos is lower than for objects, and these queries have a
  /// second, independent filter (a detected face, no UI screenshots).
  double get peopleFloor => _peopleFloor ?? floor;

  /// Rescaled visual strength 0..1 for an (adjusted) cosine.
  double strength(double cos) => ((cos - floor) / (full - floor)).clamp(0.0, 1.0);

  static const Map<String, VisualCalibration> byModel = {
    // SigLIP B/16 int8 (tool/eval/eval_models.py, 713 images, 29 visual
    // queries): relevant pairs median 0.048, non-relevant p99 0.044, max 0.104.
    'siglip_b16': VisualCalibration(
      floor: 0.06,
      margin: 0.07,
      full: 0.12,
      strictFloor: 0.10,
      screenshotPenalty: 0.015,
      typographicPenalty: 0.015,
      // "a photo of a man.": relevant median 0.033; the top 30 hits down to
      // 0.053 are 80% relevant (tool/eval).
      peopleFloor: 0.045,
    ),
  };

  /// Used for unknown model ids (tests with synthetic embeddings); the
  /// values of the first app version, calibrated for MobileCLIP-S0.
  static const fallback = VisualCalibration(
    floor: 0.20,
    margin: 0.07,
    full: 0.28,
    strictFloor: 0.27,
    screenshotPenalty: 0.04,
    typographicPenalty: 0.03,
  );

  static VisualCalibration forModel(String modelId) => byModel[modelId] ?? fallback;
}
