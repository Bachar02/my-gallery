# Search design (version 2)

Version 1 answered every query with the same recipe: OCR text matches
(FTS) plus image-text similarity, summed. On a real phone this failed in
three characteristic ways. Version 2 first decides *what kind of query* it
is, then lets only the right evidence answer it.

## 1. What went wrong in version 1

| Query | What happened | Cause in the v1 code |
|---|---|---|
| "restaurant menu" | Google-Maps-like screenshots with a "Restaurants" chip | `restaurant` and `menu` were equal keywords; one whole-word match ("Restaurant**s**", plural-tolerant) gave a text score of ~0.5, which alone made a result and was weighted above visual evidence (`1.0·text + 0.8·visual`). Nothing knew that *menu* is the thing asked for and that a menu is recognised by how it looks. |
| "picture of a man" | Images containing the word "men" / "man" | Single keyword `man`: any OCR text containing it scored full coverage (1.0) and turned on the "strong text" rule, which raised the bar for visual-only results to 0.27, above what MobileCLIP-S0 gives real photos of people. On the visual side, CLIP-family models *read* text: a shop screen saying MEN is "similar" to *a photo of man*. No photo/screenshot prior, no people signal. |
| "conversation with Jamie" / "screenshot with Jamie" | Any screenshot that mentions Jamie | The person rule only required the name somewhere in the OCR text. OCR positions were thrown away, so the index knew nothing about chat headers, message bodies, the app, or whether a screenshot was a chat at all. |

## 2. Query understanding — `QueryAnalyzer`

Rule-based and deterministic (`lib/features/search/domain/query_analyzer.dart`,
lexicons in `query_lexicon.dart`). Chosen over a small on-device language
model because there is no training data for one, rules cost no APK size or
latency, every decision can be explained in the score breakdown, and the
failing queries become exact unit tests
(`test/features/search/domain/query_analyzer_test.dart`).

1. The existing `RuleBasedQueryParser` extracts dates, "screenshot", quoted
   phrases and keywords.
2. `PersonMentions` finds a person in a conversation context.
3. The content words are split into noun phrases at linking words
   (*of, to, at, over, with …*); the **head noun** is the last known noun of
   the first phrase that has one: "restaurant **menu**", "**map** | to the
   hotel", "**sunset** | over the sea", "notes | on a **whiteboard**".
4. Intent:

| Intent | Trigger | Evidence that may create a result |
|---|---|---|
| conversation | a person in a conversation context | chat screenshot whose **title** is the person |
| text | quoted phrase, text noun head (IBAN, password, number, address, receipt…) or a text-centric concept | recognised text (FTS, verified whole words, curated expansions) |
| visual | visual noun head (people, animals, food, vehicles, places, objects, menu…) | the image model only; text can only add a small bonus |
| hybrid | screen noun head (map, settings, website…), "screenshot of" + visual noun, or unknown nouns | agreement of screen type + text, or text + visual |

The visual phrase sent to the image model keeps the descriptive words and
the small words between them ("a plate of food"), without request filler or
dates.

## 3. Screenshot understanding — schema v2

Indexing (pipeline version 2, full re-index on update) now stores:

| Column | Content |
|---|---|
| `ocr_layout` | every OCR line with its box, normalised to the image (JSON, 1/10000 units) |
| `screen_type` / `screen_conf` | chat, map, web, shop, social, settings, receipt, email, menu, other |
| `chat_title`, `chat_group`, `chat_body` | for chats: header title, group flag, message text (header, status bar and input bar removed) |
| `source_app` | app label when the file name carries it (Samsung: `Screenshot_…_Messages.jpg`); never guessed from pixels |
| `face_count` | photos: number of faces (ML Kit face detection, count only) |

`ScreenAnalyzer` (`lib/features/indexing/screen_analyzer.dart`) scores each
type from interface cues, not content words: a chat has an input bar
("Message", "Aa", "Text message"…), a status line under the title ("online",
"last seen…", "Active now"), left and right aligned bubbles and timestamps; a
map has "Search here" and category chips; a web page has a URL in the top
bar; and so on. Once chat cues are strong, content-type cues are damped, so a
chat *about* restaurants stays a chat. The chat title is the tallest text line
in the header band; groups are recognised from a members line or several
sender names.

## 4. Visual model

Compared on the evaluation corpus (section 6) with the same thumbnails the
app embeds (`tool/eval/eval_models.py`):

| Model | Licence | mAP | P@10 | screenshots in top 10 of photo queries | recall at ~0.85 precision, all negatives empty | bundled size |
|---|---|---|---|---|---|---|
| MobileCLIP-S0 (v1) | Apple ML Research, **research only** | 0.717 | 0.765 | 0.85 | 0.44 | 66 MB |
| OpenAI CLIP ViT-B/16 | MIT | 0.712 | 0.746 | 0.96 | 0.39 | (~150 MB) |
| SigLIP B/16 fp32 | Apache-2.0 | 0.786 | 0.831 | 0.27 | 0.66 | (~800 MB) |
| **SigLIP B/16 int8 (shipped)** | **Apache-2.0** | **0.785** | **0.842** | 0.31 | 0.55 | **229 MB** |

SigLIP is clearly better and reads text in images far less (one screenshot
in the top 10 of a photo query every three queries instead of almost one per
query). SigLIP 2 was rejected: its 256k-token text tower is 283 MB even in
int8. DataComp CLIP B/32 (MIT) has no ONNX export; converting it needs a
Colab/Kaggle session and it scored below SigLIP in published benchmarks.

Prompt ensembles ("a photo of…", "a picture of…", "a close-up photo of…")
were *worse* than a single caption for every model (mAP −0.01 to −0.07), so
the app uses one caption: `a photo of {phrase}.` (photos) or
`a screenshot of {phrase}.` (screenshot queries).

Quantisation (`tool/quantize_siglip.py`): only the transformer blocks' weight
matrices are int8 (dynamic quantisation, per channel); attention products,
the pooling head and embeddings stay fp32. Quantising every MatMul dropped the
median image cosine to fp32 from 0.986 to 0.958 (worst 0.85).

## 5. Scoring per intent

Constants: `lib/features/search/domain/visual_calibration.dart` (per model)
and `search_tuning.dart`.

**Visual.** Candidates come only from the vector index. Adjusted cosine =
cosine − screenshot penalty (UI screenshot for a query that did not ask for
screenshots) − typographic penalty (head noun printed in the image of a
people query or a screenshot). People queries never return UI screenshots
unless asked to, and need at least one detected face when faces were counted.
Kept: adjusted ≥ floor and ≥ best adjusted − margin. A photo that matches
visually *and* contains the head noun as text (a menu that says MENU) gets a
small bonus.

**Conversation.** Chat screenshots whose title contains the person as an
exact word ("Jamie Fox" and "Jamie 🌻" yes, "Jamieson" and "Benjamin" no),
newest first. Topic words ("about the wifi") must appear in the messages.
A separate **Mentions** group lists screenshots where the name only appears in
the text, and group chats named after the person; the UI shows it under its
own header. A person is never matched from how anyone looks.

**Text.** Version 1's text path (per-term FTS, IDF coverage, whole-word
verification, curated expansions, decisive terms, quoted phrases required);
visual-only results need the strict visual floor.

**Hybrid.** With a screen-type hint: screenshots of that type whose text
contains the query terms (or related terms), ranked by coverage then visual
similarity. Without one: text evidence for the head noun *and* a visual
match, or a clear visual match alone.

## 6. Evaluation

See docs/QA_REPORT.md ("Search quality v2") for the corpus, the procedure and
the before/after numbers per query class.

## 7. Developer score breakdown

Settings → About: tap the version row 7 times. Every results page then has a
**Score breakdown** button: the query plan (intent, head noun, visual phrase,
text terms, screen type, person, model) and, per result, the route, cosines,
penalties, face count, screen type, chat title and final score. **Copy report**
puts it on the clipboard (no file names or ids). Nothing is logged or sent.
