# AI Gallery — Architecture

AI Gallery finds images in the user's Android gallery from a natural-language
description. Everything runs on the device. The release build declares **no
INTERNET permission**, so images, extracted text and embeddings cannot leave the phone.

## Pipeline

```
MediaStore ──► GalleryRepository ──► IndexingService ──► IndexStore (SQLite)
                 (photo_manager)       │   ├─ OcrEngine (ML Kit, bundled Latin model)
                                       │   ├─ SemanticModel.embedImage (MobileCLIP-S0, ONNX)
                                       │   └─ dHash (near-duplicates)
User query ──► QueryParser ──► SearchEngine ──► IndexStore.searchText (FTS5, bm25)
               (dates, type,      (hybrid)     IndexStore.searchVector (cosine, in-memory)
                keywords)                      IndexStore.browse (filters only)
                                    └─► fused, thresholded results + MatchReasons
```

### Retrieval rules (reliability)
* Text evidence (OCR / filename) and visual evidence (CLIP) are scored separately,
  then fused. Each result carries `MatchReason`s that state *exactly* what matched.
* Visual matches must pass an absolute similarity floor **and** a margin relative to
  the best hit, so a query with no real match returns "nothing found" rather than
  the least-bad images.
* Names are only "matched" when the name literally appears in recognised text. The
  app never claims to identify a person from their face or appearance.

## Layout

```
lib/
  main.dart, app/          app shell, theme hookup, providers      (Team Lead / UX)
  domain/                  shared models + interfaces              (Team Lead only)
  core/design/             design tokens, theme                    (Agent 1 UX)
  core/widgets/            reusable components                     (Agent 1 UX)
  features/onboarding|home|search|viewer|settings/presentation     (Agent 1 UX)
  features/gallery/        PhotoManagerGalleryRepository, AndroidImageActions,
                           permissions                             (Agent 2 Android)
  features/indexing/       DefaultIndexingService                  (Agent 3 AI)
  features/search/domain|data  RuleBasedQueryParser, HybridSearchEngine (Agent 3 AI)
  ml/                      MlKitOcrEngine, MobileClipModel, CLIP tokenizer (Agent 3 AI)
  data/db/                 SqliteIndexStore, vector index           (Agent 4 DB)
android/                   manifest, permissions, Gradle           (Agent 2 Android)
assets/models/             MobileCLIP ONNX + tokenizer             (Agent 3 AI)
test/                      unit/widget tests mirror lib/ paths     (each owner; QA audits)
integration_test/          on-device flows                         (Agent 5 QA)
```

## Rules
* Features depend on `lib/domain` interfaces and `lib/app/providers.dart`, never on
  each other's concrete classes.
* Only the owner edits a directory. Dependencies are added with `flutter pub add`.
* No hard-coded demo data in `lib/`. Fakes live in `test/`.
* No network calls at runtime. No analytics.
