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
        originalFile ──► MlKitOcrEngine (Latin) ─► ocrText + lines with boxes
                         └► ScreenAnalyzer ─► screen type, chat title / messages
        originalFile ──► MlKitFaceCounter (photos) ─► face count
          └ fallback: displayImage(2048 px) → temp file → OCR
        thumbnail(256 px) ─► dHash (background isolate) ──────► perceptualHash
                          └► SiglipModel.embedImage ──────────► embedding (768-d)
     deleted ─► IndexStore.delete           batches of 20 ─► IndexStore.upsertAll

Search (HybridSearchEngine; intents and routing: docs/SEARCH_DESIGN.md)
  query ─► RuleBasedQueryParser ─► keywords, "phrases", date range, kind
        ─► QueryAnalyzer ─► intent (visual / text / conversation / hybrid), head noun,
                            visual phrase, person, screen type
        ─► merge UI filters (UI wins)
        ─► no content? ─► IndexStore.browse (filters only)
        ─► per keyword / phrase / intent expansion: IndexStore.searchText
        ─► SiglipModel.embedText("a photo of ….") ─► IndexStore.searchVector
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
* Output: lines in ML Kit block order, trimmed, blank lines dropped, joined with `\n`,
  plus every line's box normalised to the image size (the header size is read
  without decoding; boxes are in the EXIF-rotated frame, so width and height are
  swapped when only that fits). Failures are wrapped in `OcrException`.

### Screen analysis — `lib/features/indexing/screen_analyzer.dart`
Rule-based, from the OCR layout (details in docs/SEARCH_DESIGN.md §3): screen
type with a confidence, and for chats the header title, a group flag and the
message text. Measured on 141 screenshots with real ML Kit output: 138 types
and 54/54 chat titles right.

### Face count — `lib/ml/face/mlkit_face_counter.dart`
ML Kit face detection (bundled `com.google.mlkit:face-detection`), fast mode,
faces of at least 8% of the image width, photos only. Only the count is kept:
no landmarks, contours, classification or tracking. 103 ms per image on the
emulator.

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

Version 2 classifies the query first and routes it (docs/SEARCH_DESIGN.md):
visual queries are answered by the image model, conversations by chat titles,
screen-type queries by screen type + text. The text route is the version 1
pipeline below, with one change: a visual-only result always needs the strict
visual floor.
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
  prep in a background isolate inside `SiglipModel`; inference on the ONNX
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

### Semantic model — `lib/ml/siglip/`
* `SiglipModel`: SigLIP B/16 image and text encoders on ONNX Runtime (CPU), 768-d
  L2-normalised embeddings, `modelId = siglip_b16`. `load()` never throws: it
  returns `false` (app runs text-only) when assets are missing, the copy fails, or
  session creation fails (`lastLoadError` says why). Models are copied once from the
  APK assets to the app-support directory (verified by byte size, written
  atomically); copies of earlier models are deleted. Inference calls are serialised.
* `SiglipTokenizer`: pure-Dart SentencePiece Unigram (Viterbi, `tokenizers`
  tie-breaking, unknown penalty −10, Metaspace pre-tokenisation), `</s>` appended,
  padded to 64 with `</s>`. Unit-tested against the Hugging Face tokenizer ids. The
  export's precompiled NFKC map is not ported: the app only encodes captions it
  builds itself (lower-case Latin text).
* `SiglipImagePreprocessor`: exactly `preprocessor_config.json`: RGB, resize to
  224×224 (Pillow bicubic, antialiased, aspect ratio not kept), ×1/255, (x−0.5)/0.5,
  NCHW. Bit-identical to Pillow 13 on the fixtures, including Pillow's choice of
  pass order (vertical first when it removes more than twice as many rows as the
  horizontal pass removes columns).

## 3. Model and runtime choice

**Model: SigLIP base patch16-224** (Google, Apache-2.0), ONNX export
`Xenova/siglip-base-patch16-224` (separate `vision_model.onnx` / `text_model.onnx`,
`tokenizer.json`, `preprocessor_config.json`); outputs `pooler_output` (768-d).
Chosen on the evaluation corpus over MobileCLIP-S0 (version 1, research-only
weights) and OpenAI CLIP ViT-B/16 (MIT); comparison table in docs/SEARCH_DESIGN.md §4.

**int8, not fp32/fp16** (`tool/quantize_siglip.py`): fp32 weights would need about
800 MB of memory for both towers. Dynamic quantisation runs the transformer blocks'
weight matrices as int8 MatMulInteger; attention products, the pooling head,
layer norms and embeddings stay fp32. Image embeddings vs fp32: cosine median 0.986
(min 0.929) on 713 images; retrieval mAP 0.785 vs 0.786. Quantising every MatMul
(as the published `*_quantized.onnx` files do) gave median 0.958, min 0.845.
**Bundled model assets: 229 MB** (vision 115.9 MB, text 111.6 MB, vocabulary 0.9 MB).

**Runtime: `flutter_onnxruntime` 1.9.0** (MIT), unchanged: wraps the official ONNX
Runtime Android AAR and runs inference on a background thread.

## 4. Licenses

| Component | License | Notes |
|---|---|---|
| **SigLIP base patch16-224 weights** | **Apache License 2.0** (`google/siglip-base-patch16-224`) | int8 copies are a derivative; `assets/models/siglip_b16/NOTICE.txt` states the modifications. Licence text bundled and shown on the licence page. |
| ML Kit Text Recognition, Face Detection | Google ML Kit Terms of Service (free, on-device, bundled models) | Flutter plugins MIT |
| ONNX Runtime | MIT | via `flutter_onnxruntime` (MIT) |
| `package:image` | MIT | |
| Evaluation photos | CC BY 2.0 (Open Images V7), attribution in `tool/eval/photos_manifest.json` | not shipped, not in git |
| Test images | CC0 / public domain / generated | `test/ml/fixtures/reference_images/SOURCES.md` |

## 5. Thresholds and calibration

Per-model constants: `lib/features/search/domain/visual_calibration.dart`. SigLIP
cosines are small (relevant pairs median 0.048, non-relevant p99 0.044, max 0.104
on the corpus), so the values differ from version 1:

| Constant | SigLIP | Meaning |
|---|---|---|
| floor | 0.06 | a visual match needs at least this cosine |
| peopleFloor | 0.045 | people queries (with the face and no-screenshot filters) |
| margin | 0.07 | and at least best − margin |
| full | 0.12 | cosine counted as full visual strength |
| strictFloor | 0.10 | visual-only results of text and unknown-noun queries |
| screenshotPenalty | 0.015 | UI screenshot for a photo query |
| typographicPenalty | 0.015 | head noun printed in the image |

Measured with `test/eval/real_corpus_eval_test.dart` (real features, the app's
engine): per-class results in docs/QA_REPORT.md §9. Prompts: one caption
(`a photo of {phrase}.` / `a screenshot of {phrase}.`); ensembles scored lower.

## 6. Performance

Desktop (Windows, onnxruntime 1.32 CPU, 4 threads; Dart JIT in `flutter test`):

| Step | Time |
|---|---|
| Image preprocessing (JPEG 256 px decode + resize + tensor) | 5.3 ms |
| dHash (decode + 9×8) | 2.5 ms |
| Vision encoder | 21–46 ms |
| Text encoder | 10 ms |
| Tokenizer build (once) / encode | 45 ms / 0.05 ms |

On-device numbers: section 9 (`integration_test/ml/siglip_test.dart` prints `[ml-bench]` lines).

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
* The tokenizer does not port the export's precompiled NFKC map (only app-built,
  lower-case Latin captions are encoded).
* Screen analysis is rule-based and tuned on synthetic look-alike layouts read by
  real ML Kit; unusual apps (custom chat UIs, right-to-left text) may be classified
  as `other`, which only disables the conversation route for them.
* People queries match by appearance through the image model only; the face
  filter needs a face of at least 8% of the image width.
* The visual model is 229 MB and slower than version 1 (see §9); indexing a large
  gallery the first time takes correspondingly longer.

## 9. On-device results

Run on the Android emulator with
`flutter test integration_test/ml/siglip_test.dart -d <device>`:
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
tool/.venv/Scripts/python -I tool/fetch_models.py siglip_b16     # fp32 export, ~815 MB, sha256-verified
tool/.venv/Scripts/python -I tool/quantize_siglip.py             # int8 encoders
tool/.venv/Scripts/python -I tool/install_assets.py              # -> assets/models/siglip_b16/
tool/.venv/Scripts/python -I tool/siglip_reference.py            # fixtures for unit + integration tests
```
Evaluation corpus and model comparison (tool/eval/): see docs/QA_REPORT.md §9.
`tool/.venv`, `tool/.cache` and `tool/eval/.data` are gitignored.
