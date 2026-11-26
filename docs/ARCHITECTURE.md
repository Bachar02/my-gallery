# AI Gallery — Architecture

AI Gallery finds images in the user's Android gallery from a natural-language
description. Everything runs on the device. The release build declares **no
INTERNET permission**, so images, extracted text and embeddings cannot leave the phone.

## Pipeline

```
MediaStore ──► GalleryRepository ──► IndexingService ──► IndexStore (SQLite)
                 (photo_manager)       │   ├─ OcrEngine (ML Kit, Latin; lines + boxes) -> ScreenAnalyzer, FaceCounter
                                       │   ├─ SemanticModel.embedImage (SigLIP B/16 int8, ONNX)
                                       │   └─ dHash (near-duplicates)
User query ──► QueryParser ──► SearchEngine ──► IndexStore.searchText (FTS5, bm25)
               (dates, type,      (hybrid)     IndexStore.searchVector (cosine, in-memory)
                keywords)                      IndexStore.browse (filters only)
                                    └─► fused, thresholded results + MatchReasons
```

### Retrieval rules (reliability)
* Each query is classified first (visual, text in image, conversation, hybrid; see
  docs/SEARCH_DESIGN.md) and only the evidence that fits the intent may create a result:
  the image model for visual queries, recognised text for text queries, the chat title
  for conversations. Each result carries `MatchReason`s that state *exactly* what matched.
* Visual matches must pass an absolute similarity floor **and** a margin relative to
  the best hit, so a query with no real match returns "nothing found" rather than
  the least-bad images.
* Names are only "matched" from text: the chat title for a conversation, or the text
  of the screenshot (shown separately as a mention). Faces are only counted; the app never
  identifies a person or infers attributes from appearance.

## Layout

```
lib/
  main.dart, app/          app shell, theme hookup, providers
  domain/                  shared models + interfaces
  core/design/             design tokens, theme
  core/widgets/            reusable components
  features/onboarding|home|search|viewer|settings/presentation
  features/gallery/        PhotoManagerGalleryRepository, AndroidImageActions,
                           permissions
  features/indexing/       DefaultIndexingService, ScreenAnalyzer
  features/search/domain|data  RuleBasedQueryParser, QueryAnalyzer, HybridSearchEngine
  ml/                      MlKitOcrEngine, MlKitFaceCounter, SiglipModel, SigLIP tokenizer
  data/db/                 SqliteIndexStore, vector index
android/                   manifest, permissions, Gradle
assets/models/             SigLIP ONNX + vocabulary (generated, not in git)
test/                      unit/widget tests mirror lib/ paths     (each owner; QA audits)
integration_test/          on-device flows
```

## Rules
* Features depend on `lib/domain` interfaces and `lib/app/providers.dart`, never on
  each other's concrete classes.
* Dependencies are added with `flutter pub add`.
* No hard-coded demo data in `lib/`. Fakes live in `test/`.
* No network calls at runtime. No analytics.
