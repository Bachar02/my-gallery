# AI pipeline

How AI Gallery turns a gallery into a searchable index and a sentence into
results, entirely on the device. Contract types live in `lib/domain/`; this
document covers the AI/ML implementations (`lib/ml/`, `lib/features/indexing/`,
`lib/features/search/{domain,data}/`) and the scripts in `tool/`.

## 1. Overview

```
Indexing (DefaultIndexingService)
  GalleryRepository.listAllImages ─► diff vs IndexStore.indexedVersions()
     new / modified / old pipeline ─► per image, newest first:
        originalFile ──► MlKitOcrEngine (Latin) ──────────────► ocrText
          └ fallback: displayImage(2048 px) → temp file → OCR
        thumbnail(256 px) ─► dHash (background isolate) ──────► perceptualHash
                          └► MobileClipModel.embedImage ──────► embedding (512-d)
     deleted ─► IndexStore.delete           batches of 20 ─► IndexStore.upsertAll

Search (HybridSearchEngine)
  query ─► RuleBasedQueryParser ─► keywords, "phrases", date range, kind, semantic text
        ─► merge UI filters (UI wins)
        ─► no content? ─► IndexStore.browse (filters only)
        ─► per keyword / phrase / intent expansion: IndexStore.searchText
        ─► MobileClipModel.embedText("a photo of …") ─► IndexStore.searchVector
        ─► verify top 150 against stored records ─► score, thresholds
        ─► collapse near-duplicates ─► results + MatchReasons
```

## 2. Components

### OCR — `lib/ml/ocr/mlkit_ocr_engine.dart`
* Google ML Kit Text Recognition v2, **Latin script, bundled model**
  (`com.google.mlkit:text-recognition:16.0.1` via `google_mlkit_text_recognition`),
  so no model download at runtime and no Play Services dependency.
* One `TextRecognizer` is created lazily and reused (creating one loads the model).
  Recognition runs on ML Kit's worker thread; the file is decoded natively with
  EXIF orientation.
* Output: lines in ML Kit block order, trimmed, blank lines dropped, joined with `\n`.
  Failures are wrapped in `OcrException`.

### Query parsing — `lib/features/search/data/rule_based_query_parser.dart`
Deterministic, English, with an injectable clock (`now`). Extracts:

| Part | Rules |
|---|---|
| Phrases | `"…"`, `“…”`, `„…“`, `«…»` → lower-case phrases that must appear verbatim |
| Kind | `screenshot(s)`, `screen shot`, `screengrab`, `screencap` → `ImageKind.screenshot`. `photo`/`picture`/`pic`/`image` do **not** set a kind (people call screenshots pictures) |
| Date | first matching rule wins (local time, weeks start Monday): `today`, `yesterday`, `the day before yesterday`, `this/last week` (calendar), `past week` / `last N days|weeks|months` (rolling, ending today), `this/last month|year`, `N days/weeks/months/years ago` (days ±1 day, weeks ±3 days, months/years = calendar), `a few / a couple of … ago`, `this/last weekend` (Sat–Mon), `last friday`, `last/this summer|winter|spring|autumn|fall` (meteorological, northern hemisphere; *last* = most recent **completed** season), `in summer` (most recent started), `summer 2024`, `winter 2024` (= Dec 2024–Feb 2025), `March 2024`, `in March` (most recent occurrence, current month included), `last March`, `in 2023`, `recently` (last 30 days). Bare month names that are also names/verbs (May, March, April, June, July, August) and abbreviations (`Jan`) need a preposition or a year; a bare season word is not a date (“chat with Summer”). |
| Keywords | lower-case words minus stop words and request filler (“find”, “show me”, “picture of”, “I took”, “someone sent me”, “my”…); names and numbers kept (`with Jamie` → `jamie`, `#4521` → `4521`), possessive `'s` removed |
| Semantic text | keywords plus context nouns (“conversation”, “chat”, “messages”) in query order, e.g. `red car`, `restaurant menu`, `conversation jamie` |

### Intent expansion — `lib/features/search/domain/intent_expansion.dart`
A small curated map from what people ask for to what such screenshots contain,
e.g. *bank details* → iban, bic, swift, “sort code”, “routing number”,
“account number”, rib, beneficiary. Concepts: bank details, address, phone number,
password/wifi, receipt/invoice, ticket/boarding pass/flight, menu, appointment,
order/tracking, trip. Terms are ≥ 3 letters (the store matches prefixes).

`ParsedQuery` has no field for weaker, derived terms, so the parser keeps
keywords literal and `HybridSearchEngine` applies the expander itself; expansion
matches are weighted at 0.55 of a literal match and reported as
*Mentions “iban” (related to “bank details”)*.

### Hybrid search — `lib/features/search/data/hybrid_search_engine.dart`
1. Parse; UI `SearchFilters` override the parsed date range / kind.
2. Filter-only query (“screenshots from last week”) → `IndexStore.browse`,
   newest first. No content and no filters → empty.
3. One `searchText` call per keyword, per quoted phrase and per expansion
   (so the engine knows exactly which term matched which image, independent of
   how the store combines terms). Visual search in parallel when the model is
   loaded, the store has embeddings and the query has semantic text.
4. Scoring:
   * term strength = 0.6 + 0.4 · bm25 / best bm25 for that term;
   * **text score** = IDF-weighted coverage of literal terms and phrases
     (IDF from the number of hits per term), a term also being covered at 0.55 ×
     strength by a matched expansion of a concept containing it;
   * **visual score** = (cos − floor) / (0.28 − floor), clamped to 0..1;
   * **final** = 1.0 · text + 0.8 · visual.
5. Verification of the top 150 candidates against `IndexStore.get`: whole-word
   (or plural, accent-insensitive) matches keep their strength, prefix-only
   matches (“car” in “cardigan”) are halved and are never sufficient evidence.
6. Reliability rules — a result needs at least one of:
   * text evidence: an exact word/phrase match **and** text score ≥ 0.4 × the
     best text score of the query;
   * visual evidence: cosine ≥ **0.20** (absolute floor) **and** ≥ best visual
     cosine − **0.07** (margin).

   * **people:** a name in a person context (“conversation with Jamie”,
     “message from alex”, “Jamie's address”, “what Sam said”, detected by
     `lib/features/search/domain/person_mentions.dart`) is required text: only
     images whose OCR text contains the whole word are returned, visual-only
     candidates are excluded, and the name is removed from the CLIP text. No such
     image → empty result. Places/things (“trip to Germany”, “sent me their bank
     details”) are not treated as names.
   * **strong text present:** if any image covers every query term in its text
     (literally or via an expansion such as IBAN for “bank details”), visual-only
     candidates need cosine ≥ 0.27 instead of 0.20 (chat screenshots look alike
     to CLIP: on the test gallery an unrelated chat scored 0.221 and a receipt
     0.230 for “bank details”, the IBAN chat 0.264).

   * **text-centric intents without text:** if the query triggers a text-centric
     concept (password/Wi-Fi, bank details, address, phone, receipt, tickets,
     appointment, order/tracking; not menu or trip) and no image has text
     evidence, visual-only results also need cosine ≥ 0.27 (QA-06).
   * **expansion-only matches:** when some image contains every query word, an
     image matched only through expansions needs two different expansion terms
     or one decisive term (IBAN, SWIFT, sort code, password, SSID, postcode,
     receipt, invoice, order number, …). Ticket concepts are split (boarding
     pass / train / concert / generic), the most specific trigger wins (QA-15).
   * Verification also credits whole-word singular/plural matches the prefix
     index misses (“passes” ↔ “PASS”).

   Query input is capped at 256 characters, 32 keywords and 8 phrases (QA-14).
   `SearchResponse.semanticSearchUsed` means visual search is *available* (model
   loaded and images embedded), for every query type (QA-12).

   Quoted phrases are required for every result. With no evidence the response
   is empty — never the least-bad images.
7. Near-duplicate collapse: two images are duplicates if their dHash differs in
   ≤ 5 of 64 bits **and** they were taken within 10 minutes (bursts) or have the
   same recognised text (same screenshot saved twice). Hash alone is not enough:
   two different chat screenshots of the same app can hash alike.
8. Match reasons: `Contains the text “jamie”` (with OCR snippet),
   `File name contains “…”`, `Mentions “iban” (related to “bank details”)`,
   `Visually similar to “red car”` (strength), `Taken in Summer 2026` /
   `Taken last week`, `Screenshot`. A name is only ever reported as text found in
   the image; nothing claims to recognise a person.

### Indexing — `lib/features/indexing/default_indexing_service.dart`
* `start()`: permission check → `scanning` → list all images → diff →
  `indexing` with processed/total/failed → `completed` (`lastCompletedAt`, also
  persisted in the store settings as `indexing.lastCompletedAt`).
* Diff: new ids, changed `modifiedAt`, and stale pipeline stamps are processed;
  ids no longer listed are deleted from the index.
* **Pipeline stamp** (`pipeline_version.dart`): `pipelineVersion` is stored as
  `kPipelineVersion * 10 + (has embedding ? 1 : 0)`. Bumping `kPipelineVersion`
  re-processes everything; text-only records (model unavailable or failed for that
  image) are re-processed when the model becomes available, **re-using the stored
  OCR text and hash** so only the embedding is computed.
* Per image: OCR on `originalFile`, falling back to `displayImage(maxSide: 2048)`
  written to a temp file (deleted afterwards); `thumbnail(size: 256)` → dHash in a
  background isolate (`Isolate.run`) and the image embedding (decode/resize/tensor
  prep in a background isolate inside `MobileClipModel`; inference on the ONNX
  Runtime plugin's background thread). The UI isolate only orchestrates.
* Records are written with `upsertAll` every 20 items and before pausing.
* An item whose OCR fails is counted in `failed`, not stored, and retried on the
  next sync. An embedding/thumbnail failure keeps the record text-only.
  If an item fails and the permission is gone → `permissionDenied` (finished work
  is kept). If the image vanished meanwhile, it is deleted, not counted as failed.
* `pause()`/`resume()` act at item boundaries; `stop()` cancels (phase `idle`).
  `start()` while running returns the running sync.
* OCR fallback renditions are written to `<cache>/ocr_tmp/`, deleted in a
  `finally` block, and the folder (plus legacy `ocr_<n>_<n>.jpg` files) is swept
  at the start of every run.
* No automatic re-sync while the store setting `indexing.disabled` is `'1'`
  (written by *Delete local index*); an explicit `start()` still runs.
* One `debugPrint` per run with counts, elapsed time and embedding count (no ids,
  file names or text).
* After the first `start()`, `GalleryRepository.changes` triggers a debounced
  (3 s) re-sync while idle, or one re-sync right after the current run.
* dHash: luma (ITU-R 601), 9×8 antialiased bilinear resize, bit = pixel brighter
  than its right neighbour. Pure Dart (`lib/ml/image/`), using `package:image`
  for decoding (pure Dart, so it runs in background isolates; JPEG/PNG/WebP/GIF/BMP).

### Semantic model — `lib/ml/clip/`
* `MobileClipModel`: MobileCLIP-S0 image and text encoders on ONNX Runtime (CPU),
  512-d L2-normalised embeddings, `modelId = mobileclip_s0`.
  `load()` never throws: it returns `false` (app runs text-only) when assets are
  missing, the copy fails, or session creation fails (`lastLoadError` says why).
  Models are copied once from the APK assets to the app-support directory
  (ONNX Runtime needs a file path; app-support is not cleared like the cache),
  verified by byte size, written atomically. Inference calls are serialised.
* `ClipTokenizer`: pure-Dart CLIP byte-level BPE (normalise whitespace, lower-case,
  CLIP pre-tokeniser regex, `</w>` suffix), SOT/EOT, truncation and zero padding
  to 77. The vocabulary is derived from the bundled merge list (verified identical
  to the export's `tokenizer.json` by `tool/install_assets.py`). Unit-tested
  against 23 reference id sequences from the Hugging Face tokenizer, including
  accents, emoji, CJK/Cyrillic, punctuation, numbers and truncation.
  Not applied: Unicode NFC normalisation (precomposed input is unaffected).
* `ClipImagePreprocessor`: exactly `preprocessor_config.json`: RGB, resize the
  shortest edge to 256 (port of Pillow's antialiased bilinear filter, fixed-point
  included), center crop 256×256, ×1/255, **no mean/std**, NCHW. Unit tests check
  the result is **bit-identical** to Pillow (SHA-256 of the uint8 tensor) on all
  five fixtures.

## 3. Model and runtime choice

**Model: MobileCLIP-S0** (Apple), ONNX export `Xenova/mobileclip_s0` on Hugging Face
(separate `vision_model*.onnx` / `text_model*.onnx`, `tokenizer.json`,
`preprocessor_config.json`). Inputs `pixel_values [N,3,256,256]` float and
`input_ids [N,77]` int64; outputs `image_embeds` / `text_embeds` `[N,512]`.

**Why not the published `*_int8.onnx` files** (measured with desktop onnxruntime
1.32 against the fp32 export, `tool/clip_reference.py` images/texts):

| Variant | Size | Cosine vs fp32 | Desktop latency |
|---|---|---|---|
| vision fp32 | 45.5 MB | 1 | 30–77 ms |
| vision `int8` (published, dynamic quant) | 11.8 MB | **0.10–0.18 (broken)** | 1570 ms |
| vision weight-only int8 (ours) | 11.7 MB | 0.965–0.983 | 22 ms |
| **vision fp16 weights (ours, shipped)** | **22.9 MB** | **0.99998–0.99999** | 21–46 ms |
| text fp32 | 169.8 MB | 1 | 9 ms |
| text `int8` (published) | 42.8 MB | 0.86–0.97 | 41–100 ms |
| **text weight-only int8 (ours, shipped)** | **42.9 MB** | **0.99986–0.9999** | 10–11 ms |

`tool/compress_weights.py` stores weights compactly while keeping every operation
in fp32: fp16 initializers + `Cast`, or int8 per-output-channel weights + `Cast` +
`Mul` (per-row for the token-embedding `Gather`, which stays int8 in memory).
ONNX Runtime constant-folds the casts when the session is created, so inference
runs the plain fp32 graph. **Bundled model assets: 66.3 MB** (22.9 + 42.9 MB +
0.5 MB BPE merges). Estimated runtime memory after folding (fp32 weights): ~45 MB (vision) +
~95 MB (text).

**Runtime: `flutter_onnxruntime` 1.9.0** (MIT): actively maintained (monthly
releases in 2026), wraps the official `com.microsoft.onnxruntime:onnxruntime-android:1.28.0`
AAR (16 KB page-size compliant), runs inference on a Flutter background
`TaskQueue` (not the UI thread), and builds with this Flutter/AGP. Rejected:
`onnxruntime` (FFI; last release March 2024, old ORT), TFLite (no ready-made
MobileCLIP conversion; local conversion is heavy and lossy).

## 4. Licenses

| Component | License | Notes |
|---|---|---|
| MobileCLIP code (`apple/ml-mobileclip`) | MIT | not shipped |
| **MobileCLIP-S0 weights** | **Apple Machine Learning Research Model License** (`apple/MobileCLIP-S0` on Hugging Face, `LICENSE_APPLE_AMLR.txt`) | **Research purposes only; excludes commercial products.** The Xenova export ships an earlier, permissive Apple sample-code license (`LICENSE_XENOVA_EXPORT.txt`). Our compressed files are model derivatives. **Needs legal review before any commercial release**; the model is swappable (see Limitations). |
| ML Kit Text Recognition | Google ML Kit Terms of Service (free, on-device, bundled model) | Flutter plugin MIT |
| ONNX Runtime | MIT | via `flutter_onnxruntime` (MIT) |
| `package:image` | MIT | |
| Test images | CC0 / public domain / generated | `test/ml/fixtures/clip_images/SOURCES.md` |

Both license texts are bundled under `assets/models/mobileclip_s0/` so an
“Open-source licenses” screen can show them.

## 5. Thresholds and calibration

Constants live in `lib/features/search/domain/search_tuning.dart`, each with its
rationale. Visual thresholds were calibrated with `tool/calibrate_clip.py`:
92 images (16 categories × 5 Wikimedia Commons photos, labels from search results
so somewhat noisy, plus 12 synthetic phone screenshots), 36 queries (31 with a
matching category, 5 without: “purple elephant”, “a giraffe”, “fireworks”,
“a wedding dress”, “a chess board”), prompt `a photo of <query>`, images embedded
exactly as the app does (256 px thumbnail → preprocessing).

| | n | mean | percentiles |
|---|---|---|---|
| matching pairs | 155 | 0.217 | p5 0.117, p25 0.180, median 0.223 |
| non-matching photo pairs | 2725 | 0.085 | p95 0.143, p99 0.188, max 0.279 |
| screenshots vs photo queries | 432 | 0.092 | p95 0.168, max 0.260 |

| floor | margin | recall | precision | unmatched queries returning nothing |
|---|---|---|---|---|
| 0.17 | 0.07 | 0.74 | 0.92 | 4/5 |
| 0.19 | 0.07 | 0.70 | 0.93 | 4/5 |
| **0.20** | **0.07** | **0.66** | **0.94** | **5/5** |
| 0.20 | 0.05 | 0.60 | 0.96 | 5/5 |
| 0.20 | 0.10 | 0.66 | 0.88 | 5/5 |
| 0.22 | 0.07 | 0.51 | 0.93 | 5/5 |

Chosen: floor 0.20, margin 0.07 — the lowest floor at which no query without a
matching image returned anything (at 0.19 “purple elephant” matched a bicycle at
0.190). Recall is bounded by label noise and by weak categories (best “dog” match
0.171: such queries return nothing rather than wrong images). Strong matches
scored 0.25–0.33, hence full visual strength at 0.28.

Text-side constants (relative cut 0.4, expansion weight 0.55, prefix penalty 0.5,
term strength floor 0.6) are set by reasoning and covered by unit tests
(`test/features/search/data/hybrid_search_engine_test.dart`); they should be
revisited with real user galleries.

## 6. Performance

Desktop (Windows, onnxruntime 1.32 CPU, 4 threads; Dart JIT in `flutter test`):

| Step | Time |
|---|---|
| Image preprocessing (JPEG 256 px decode + resize + tensor) | 5.3 ms |
| dHash (decode + 9×8) | 2.5 ms |
| Vision encoder | 21–46 ms |
| Text encoder | 10 ms |
| Tokenizer build (once) / encode | 45 ms / 0.05 ms |

On-device numbers: section 9 (`integration_test/ml/clip_test.dart` prints `[ml-bench]` lines).

## 7. Privacy

No network access at runtime: models are bundled assets, OCR uses the bundled ML
Kit model, and all processing happens in the app process. Extracted text,
embeddings and hashes are stored only in the local SQLite index.

## 8. Limitations

* OCR is Latin-script only; Chinese, Japanese, Korean, Devanagari, Arabic,
  Cyrillic text is not indexed (each would add ~10–20 MB of ML Kit models).
* Query parsing is English-only; intent expansions are English and do not map
  across languages (“Germany” does not match “Deutschland”).
* CLIP similarity is coarse: small objects, text-heavy screenshots and fine
  distinctions (“my dog” vs any dog) are unreliable; thresholds favour precision,
  so some valid visual matches are not returned.
* Dates are DATE_TAKEN in device local time; seasons are northern-hemisphere.
* Indexing is sequential (OCR then embedding per image); very large galleries take
  a while on first run (newest images first). OCR and embedding could be pipelined.
* Tokenizer does not apply NFC normalisation.
* Weights license (section 4): for a commercial release, replace MobileCLIP-S0 by a
  permissively licensed model of the same family (e.g. an OpenCLIP/LAION model
  exported to ONNX); `MobileClipAssets`, the preprocessing constants and
  `SearchTuning.visual*` must then be re-derived with the same tools.

## 9. On-device results

Run on the Android emulator with
`flutter test integration_test/ml/clip_test.dart -d <device>`:
the test asserts cosine > 0.99 between on-device and desktop embeddings for
5 images and 6 texts, checks that each image is closest to its own description,
checks ML Kit OCR on rendered text, and prints latencies.

Latest run (2026-11-23, emulator Pixel_XL_API_36, Android 16 / API 36, x86_64,
debug build, ONNX Runtime 1.28 CPU, 2 intra-op threads): **5/5 tests passed**.

| Measurement | Result |
|---|---|
| Embedding agreement with desktop reference | cosine 1.00000 for all 5 images and 6 texts |
| Image closest to its own description | red car, cat, menu, chat screenshot: all correct |
| `load()` first launch (copy 66 MB of assets to app support + create both sessions) | 4.3 s |
| `embedImage` (JPEG/PNG decode + preprocessing in an isolate + inference), avg of 10 | 96.7 ms |
| `embedText` (tokenise + inference), avg of 10 | 33.3 ms |
| ML Kit OCR, 900×360 rendered text, after warm-up | 447 ms, text read exactly: `Jamie / IBAN DE89 3704 0044 / Flight lands 10:40` |

Emulator figures are an indication only (x86_64 host CPU, debug mode); measure on
a mid-range arm64 phone in profile mode before quoting indexing throughput. At these
numbers one image costs roughly 0.1 s embedding + 0.2–0.5 s OCR.

## 10. Reproducing the assets and fixtures

```
py -3.13 -m venv tool/.venv
tool/.venv/Scripts/python -m pip install onnxruntime numpy pillow tokenizers onnx
tool/.venv/Scripts/python -I tool/fetch_models.py      # fp32 export, ~215 MB, sha256-verified
tool/.venv/Scripts/python -I tool/install_assets.py    # -> assets/models/mobileclip_s0/
tool/.venv/Scripts/python -I tool/clip_reference.py    # fixtures for unit + integration tests
tool/.venv/Scripts/python -I tool/calibrate_clip.py    # threshold calibration report
```
`tool/.venv` and `tool/.cache` are gitignored.
