# AI Gallery: QA report

Date: 2026-11-23. Build: `1.0.0+1` release APK (x86_64 target, built from the current tree)
on emulator-5554 (Pixel XL image, Android 16 / API 36, x86_64), plus host tests (Windows,
`flutter test`). Companion documents: `docs/SECURITY_AUDIT.md` and
`docs/RELEASE_CHECKLIST.md`.

## 1. Summary

| | |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` | **340 passed, 1 skipped** (was ~312). 29 new tests: 28 run and pass, 1 is skipped (documents open defect QA-07) |
| On-device E2E (`integration_test/app/search_flow_test.dart`, debug build) | **1/1 passed**: 5/5 product examples exact, negative empty, delete + re-index OK |
| Device flows (release APK) | 24 checks: 22 pass, 2 pass with issues (QA-13, QA-18) |
| Search evaluation (44 items, 50 queries) | mean P@5 **0.835**, mean recall **0.934**, top-1 hit **0.895**, empty-when-should-be-empty **11/12** |
| Search latency, host, end to end | **37 ms** median at 10k images, **40 ms** median at 20k (p95 61 and 65 ms) |
| Indexing throughput, emulator, release build | **206 ms/image** (527 images in 108.5 s; MobileCLIP and ML Kit warm) |
| Defects | 20 found: **5 fixed**, 15 open (2 Medium, 11 Low, 2 Info). No crash, data loss or network path found |
| Release blockers | MobileCLIP-S0 weight licence, for commercial release only (S-7). Licence page attribution (QA-10) should be fixed before any public release |

## 2. What was tested and how

| Area | How | Where |
|---|---|---|
| Privacy/security static audit | manifest and APK inspection (`aapt2`), grep over code and deps, review of every log call, licence scan of `pubspec.lock` | `docs/SECURITY_AUDIT.md` |
| Deletion really deletes | file-backed store in WAL mode, unique tokens planted, raw bytes of `db`/`-wal`/`-shm`/`-journal` scanned after each delete path | `test/qa/privacy_wipe_test.dart` (6 tests, 1 skipped) |
| Indexing robustness | `DefaultIndexingService` with fakes: lifecycle races, delete-while-indexing, app resume, permission loss, vanished images, temp files, error exposure | `test/qa/indexing_robustness_test.dart` (15 tests) |
| UI robustness | stale/rapid searches, blank queries, recent-search logging, delete-index snackbar | `test/qa/ui_robustness_test.dart` (5 tests) |
| Search accuracy | real `HybridSearchEngine` + `SqliteIndexStore` (in-memory FTS5) + `RuleBasedQueryParser`, fake concept-embedding model, 44 OCR-realistic items, 50 queries | `test/eval/search_eval_test.dart` |
| Search latency | same stack, file DB, 512-d vectors, 10k/20k images, adversarial queries | `test/eval/search_perf_test.dart` |
| On-device E2E | real gallery + ML Kit + MobileCLIP + SQLite + engine over the fixture gallery; delete and re-index | `integration_test/app/search_flow_test.dart` |
| Device flows | release APK, `adb input` + `screencap` (captures kept under `/data/local/tmp`), `uiautomator dump`, logcat | §5 |
| Corrupt/huge media | 12000×12000 PNG, truncated JPEG, zero-byte JPEG, random-bytes JPEG, animated GIF, WebP, RGBA PNG, 20000×200 panorama, pushed to the emulator and indexed by the release app | §5.2 |

HEIC was not tested. Pillow in `tool/.venv` cannot encode it, and the emulator has no
camera sample. Add a HEIC file from a real phone to the manual smoke test.

## 3. Defects

Severity: High = crash, data loss or privacy breach; Medium = wrong or unsafe behaviour a
user will hit; Low = edge case, cosmetic or hardening; Info = product decision.

### Fixed (each covered by a new test)

| ID | Sev | Defect | Fix | Test |
|---|---|---|---|---|
| QA-01 | **Medium** | `SqliteException.toString()` includes the failing SQL **and its bound parameters**. Store log lines (corruption, open, vector load) and the indexing error state used `$e`/`e.toString()`, so a disk-full or corruption error during `upsertAll` put the **OCR text and file names of the batch into logcat and onto the Home/Settings status card** ("Preparing photos stopped" details). The recent-search log had the same problem with the query text. | `SqliteIndexStore.describeError` (first line only): `lib/data/db/sqlite_index_store.dart:86`, used at :121, :195, :648, :819. `DefaultIndexingService.userFacingError` (first line, no `path = '…'`): `lib/features/indexing/default_indexing_service.dart:286`, used at :277. The recent-search log prints the type only: `lib/features/home/presentation/recent_searches_controller.dart:26` | privacy_wipe "store error logging…", indexing_robustness "error state never exposes…", ui_robustness "…does not log the query text" |
| QA-02 | Low | A MediaStore image id was logged when an embedding had no model id. | The log line no longer includes the id: `sqlite_index_store.dart:304` | (log text only) |
| QA-03 | Low | Removing a vanished image left its OCR text in the `-wal` file (secure_delete zeroes only the main file). | `_truncateWal` (checkpoint TRUNCATE, best effort) after `delete`: `sqlite_index_store.dart:381`, :814 | privacy_wipe "deleting one image…" |
| QA-04 | Low | *Clear recent searches* left the query text in the `-wal` file. | `_truncateWal` after `clearRecentSearches`: `sqlite_index_store.dart:804` | privacy_wipe "clearRecentSearches…" |
| QA-05 | Low | **Found on device:** after *Delete local index*, the "Local index deleted · Re-index now" snackbar never went away. It was still shown 3 minutes later on top of the viewer. Since Flutter 3.3x a `SnackBar` with an action has `persist = true` by default. | `persist: false`: `lib/features/settings/presentation/settings_screen.dart:347` | ui_robustness "the 'Local index deleted' snackbar goes away on its own" |

### Open

| ID | Sev | Defect, repro, root cause | Suggested fix (owner) |
|---|---|---|---|
| QA-06 | **Medium** | **"Wi-Fi password" (a Home example chip) returns 2 unrelated images** on the fixture gallery, which has no Wi-Fi screenshot: the Sam chat and a plain coloured image, both "Visually similar to 'wifi password'". Repro: release build, fixture gallery, tap the chip. Root cause: no text candidate exists, so the strong-text rule does not apply, and visual-only candidates need only cosine ≥ 0.20 within 0.07 of the best. CLIP scores chat screenshots ~0.2 for text-like concepts. This breaks G3 ("no padding"). | When the query triggers a text-oriented intent concept (password, bank details, receipt, address, phone, ticket) and no candidate has text evidence, require `visualOnlyFloorWithStrongText` (0.27) for visual-only results, or drop them. Re-check with `tool/calibrate_clip.py`. (AI) |
| QA-08 | **Medium** (API 29 only) | On Android 10, photo_manager's `AssetEntity.file` copies every original into `cache/pm_<id>_<name>` (`AndroidQDBUtils.shouldUseScopedCache`) and never deletes it. Indexing calls `originalFile` for every image, which **duplicates the whole gallery into the app cache**. Static finding; cannot be reproduced on API 36. | Add `GalleryRepository.releaseCaches()` → `PhotoManager.clearFileCache()` and call it after each indexing run, or OCR the 2048 px rendition on API 29. Verify on an API 29 emulator. (Android) |
| QA-06b | (see QA-06) | Same mechanism for nonsense queries: "qatrunc" (a word that the truncated JPEG shows but OCR did not read) matched visually. CLIP reads rendered text, so this is arguably a true match. Recorded so the QA-06 fix is checked against it. | (AI) |
| QA-07 | Low | Re-indexing an image whose OCR text changed (e.g. the user cropped an IBAN out) leaves the old text in `-wal` frames until they are overwritten. Test present, skipped. | Inside `upsertAll`, detect changed `ocr_text` and call `_truncateWal` after the commit. (DB) |
| QA-09 | Low | Copies of shared images remain in `cache/share_plus/` (share_plus clears them only at the next share) and in `cache/share_export/`. A process kill during OCR can leave `cache/ocr_*.jpg`. | Sweep these folders on start-up and after *Delete local index*. (Android) |
| QA-10 | Low (release) | **Verified on device:** the "Open-source licenses" page has no entry for MobileCLIP (Apple AMLR / Xenova export), ONNX Runtime native or ML Kit, although the licence texts are bundled. | `LicenseRegistry.addLicense` in `main()` for the two `LICENSE_*.txt` assets, ONNX Runtime (MIT) and the ML Kit terms. (Lead) |
| QA-11 | Low | Glide (inside photo_manager) logs `Load failed for [content://media/external/images/media/<id>]` with stack traces for undecodable files (seen for the zero-byte and garbage JPEGs). Ids only, no content. | Lower Glide's log level, or accept. (Android) |
| QA-12 | Low | **Device:** for stop-word-only ("the of and with"), punctuation-only and filter-only queries ("Screenshots from last week" with nothing that week), the empty state says "**Visual search is unavailable**, so only text in images can be matched". The model is loaded; visual search was simply not used because there was no descriptive text. Cause: `semanticSearchUsed == false` is read as "unavailable" (`lib/features/search/presentation/search_screen.dart:321`, :337). | Add a distinct signal (e.g. `SearchResponse.semanticAvailable`), or omit the tip when `query.semanticText` is empty. For no-content queries say "Try describing what's in the image". (UX + Lead, domain change) |
| QA-13 | Low | **Device:** after *Delete local index*, Settings and Home say "**Your photos are ready to search · Up to date · Updated 1 min ago**" while the stats show 0 images. The service phase stays `completed`, and `indexing.lastCompletedAt` is a setting that `clearAll` deliberately keeps. | After deleting, reset the service progress to `idle` (e.g. `IndexingService.reset()`) and remove the `indexing.lastCompletedAt` setting. (AI / UX) |
| QA-14 | Low | Query length is unbounded. The engine issues one FTS query per keyword (plus expansions): a 1000-word paste takes **1.9 s on the host** (expect ~4–8 s on a phone, UI isolate), 200 words 0.39 s. The search field has no `maxLength`. | Cap keywords at ~12 (by IDF or query order) and set `maxLength: 200` on the field. (AI / UX) |
| QA-15 | Low | Intent expansions dilute precision when a literal match exists: "Boarding pass" also returns a train ticket, a concert ticket and a chat that mentions flights (P@5 0.40); "tracking number" returns a receipt and a bank screen; "concert ticket" ranks the actual concert ticket 4th (its text has neither word, only "Seat"). | When some candidate covers every literal term, require expansion-only candidates to reach a higher bar, like the visual rule. (AI) |
| QA-16 | Low | No typo tolerance: "recipt" returns nothing. ("borading pass" works only because "pass" matches.) | When the result is empty, try a fuzzy fallback (edit distance 1 against the `fts5vocab` vocabulary) and say "Showing results for …". (AI) |
| QA-17 | Info | A multi-word query with no full match keeps the best partial matches by design: "car insurance quote" returns the insurance card and car photos. The evaluation counts this as a failed "should be empty" query. | Product decision: require at least half of the weighted terms, or keep as is. (Lead) |
| QA-18 | Low | **Device, splash:** in dark mode, the splash background `#161D1D` (`values-night/colors.xml`) differs from the first Flutter frame `#0E1415`, which gives a subtle brightness step at hand-off. Light mode matches exactly (`#F5FAFB` both). No colour flash in either mode. | Set the night `splash_background` to `#0E1415`. (Android/UX) |
| QA-19 | Low | **Themed icon (static check):** `<monochrome>` reuses the colour foreground. The launcher uses only its alpha, and the photo card, landscape, sun and lens are all opaque, so the themed icon becomes a plain rounded card with a solid disc; the landscape and lens are lost. I could not enable themed icons on the emulator through adb, so this is from the drawable. The normal icon looks correct in the app drawer. | Add a dedicated monochrome vector with the landscape and lens as cut-outs. (UX) |
| QA-20 | Info | *Delete local index* is not durable: the next app resume (R8) or MediaStore change re-indexes everything without asking. | Product decision. Option: a "Pause indexing" setting, or do not auto-start after a manual delete until *Re-index now* is pressed. (Lead) |

(QA-06b shares QA-06's fix and is not counted separately in the totals.)

## 4. Robustness review (host tests)

All pass unless noted. Fakes come from `test/features/search/data/fakes.dart`.

| Scenario | Result |
|---|---|
| Permission revoked at start / before the first item / mid-run | `permissionDenied`, finished work kept, nothing counted as failed; next sync after re-grant indexes everything ✔ |
| Every image deleted between listing and processing | `completed`, 0 failed, index emptied ✔ |
| Image deleted between indexing and viewing | viewer "no longer available", Share disabled (existing widget test + device) ✔ |
| Empty gallery | `completed`, total 0, no writes ✔ |
| Delete index while indexing runs (stop → clearAll, as `DeleteIndexController` does) | in-flight batch flushed **before** the wipe; index stays empty ✔ |
| Gallery change notification during a run that is then stopped and wiped | no resurrection ✔ |
| Start after stop | fresh full run ✔ |
| Pause + resume inside one item; 30 rapid pause/resume toggles | no hang, every image processed exactly once ✔ |
| Pause during scanning | takes effect at the first item ✔ |
| App resume during indexing / while paused | joins the running sync; a paused run stays paused ✔ |
| dispose while paused | completes ✔ |
| OCR fallback temp files | deleted on success and on failure ✔ |
| Store failure | error phase, **message sanitised** (QA-01) ✔ |
| Rapid repeated searches (20, answered in reverse order) / slow old + fast new | only the newest response is shown ✔ |
| Blank / whitespace query | idle, engine not called ✔ |
| Very long, emoji, RTL, stop-words-only, punctuation-only queries | correct (empty or matching) results, no exceptions; long queries are slow (QA-14) |

## 5. Device testing (release APK on emulator-5554)

### 5.1 Flow results

| # | Flow | Result |
|---|---|---|
| 1 | Fresh install (`pm clear`): splash → loading → onboarding, light mode | **Pass**: splash and Flutter background are both `#F5FAFB`; no flash |
| 2 | Onboarding: *Allow photo access* → **Don't allow** | **Pass**: "Photo access wasn't allowed…" + *Try again* |
| 3 | *Try again* → **Allow all** → Home, indexing starts | **Pass**: "Preparing photos for search · X of 527" with progress bar |
| 4 | Pause → background → resume app | **Pass**: stays "Paused · 107 of 527" |
| 5 | Resume → completes | **Pass**: 527/527, 0 failed |
| 6 | "Find the screenshot of my conversation with Jamie" | **Pass**: exactly the Jamie chat, "Understood as Screenshots", 0.1 s |
| 7 | "Find the conversation where we discussed our trip to Germany" | **Pass**: Sam chat only |
| 8 | "Find the screenshot where someone sent me their bank details" | **Pass**: Alex IBAN chat only |
| 9 | "Show me the picture of the restaurant menu I took last summer" | **Pass**: both menu photos, "Understood as Summer 2026" |
| 10 | "Show me the picture of the red car" | **Pass**: both red-car photos |
| 11 | "zebra crossing in tokyo" | **Pass**: "No matching photos" + tips |
| 12 | Viewer + Why this matched | **Pass**: "Contains the text 'jamie' · Strong match", highlighted snippet, details (date, type, 1080×2400, file name, folder) |
| 13 | Share | **Pass**: system chooser ("Sharing image") opens with a preview |
| 14 | Home chips | Restaurant menu ✔, Receipt from this month ✔, Screenshots from last week ✔ (empty: none that week; misleading tip QA-12), **Wi-Fi password ✘ (QA-06)** |
| 15 | Settings: access, status, stats (527 / 8 screenshots / 386 with text / 527 visual / 1.6 MB), privacy copy, About | **Pass** |
| 16 | Open-source licenses | **Pass with issue**: opens; model and ML Kit licences missing (QA-10) |
| 17 | Delete local index (confirm dialog) → stats reset → Re-scan rebuilds | **Pass with issue**: stats go to 0 and re-index restores 527. Status text is wrong (QA-13), and the snackbar persisted (QA-05, fixed) |
| 18 | New screenshot added while the app is open | **Pass**: indexed 4 s after the media scan ("processed=1 … 634 ms") and found by "parking ticket qapark" |
| 19 | Image deleted, then opened from results | **Pass**: "This photo is no longer available", Share greyed out |
| 20 | Revoke `READ_MEDIA_IMAGES` while backgrounded, then resume | **Pass**: Android kills the process on revoke. On relaunch Android 14+ substitutes "selected photos" access: limited banner, index emptied of now-inaccessible images, no crash. Revoking both permissions → onboarding ✔ |
| 21 | Corrupt / huge / odd images (§5.2) | **Pass**: no crash, no ANR |
| 22 | Dark mode: splash, Home, search, Settings, viewer | **Pass with issue**: all readable; splash/first-frame shade step (QA-18) |
| 23 | Font scale 1.3: Home, search grid, viewer sheet | **Pass**: no clipping or overflow |
| 24 | Launcher icon in the app drawer | **Pass** (themed icon: QA-19, static) |

Emulator settings restored: `font_scale` 1.0, night mode off. Test files removed
(`Pictures/QARobust`, the added screenshot). The release APK was re-installed after the E2E
run, and the photo permission is granted.

### 5.2 Adversarial media (indexed by the release app)

Pushed to `Pictures/QARobust/` and media-scanned. Indexing run: `processed=535 failed=2`.
The two failures are the zero-byte and garbage files, which are retried on the next sync
as designed.

| File | Result |
|---|---|
| 12000×12000 PNG (144 MP) | indexed; OCR found "QAHUGE"; viewer renders it; no OOM |
| truncated JPEG (40 % of file) | indexed; the visible part was decoded; viewer shows the top part; Share works |
| zero-byte `.jpg`, random-bytes `.jpg` | counted as failed (OCR on the original fails, then the rendition fails); no crash |
| animated GIF, WebP, RGBA PNG, 20000×200 panorama | indexed; text found ("QAGIF", "QAWEBP", "QAALPHA", "QAPANO") |

### 5.3 On-device end-to-end test (debug build)

`flutter test integration_test/app/search_flow_test.dart -d emulator-5554`: **1/1 passed** (3 min 16 s).

| Step | Result |
|---|---|
| First index (real gallery, ML Kit, MobileCLIP, SQLite) | 527 images, 0 failed, 102.8 s (**195 ms/image**) |
| Jamie / Germany / bank details | exactly the expected screenshot each (126 / 56 / 32 ms) |
| Menu last summer / red car | both expected photos each (40 / 34 ms) |
| "zebra crossing in tokyo" | empty (33 ms) |
| `clearAll` then re-index | stats 0, then 527 images in 89.5 s (170 ms/image) |

### 5.4 Logs

App logcat after the full pass contains only counts and timings (`Indexing run ended …`,
`MobileClipModel loaded in … ms`, exception types). It has no OCR text, queries, file names
or paths. Glide logs content URIs for undecodable files (QA-11).

## 6. Search accuracy evaluation

`test/eval/search_eval_test.dart` uses 44 items. The text items are 8 chats, 4
receipts/invoices/payslip, 5 tickets/boarding passes, 3 menus, a bank details screen, a
router label, a password-reset email, parcel tracking, a doctor appointment, a recipe, an
error page, 2 news distractors (carpet, bankruptcy), a gym timetable, an insurance card, an
Arabic note and an emoji chat. Distractors include "Jamieson", "Carpet" and "bankruptcy".
The rest are 12 photos with little or no text. Queries: the 5 product examples, the 6 Home
chips, text recall, dates, plurals, typos, visual queries, person queries and 11 negatives.
The fake model is a bag-of-concepts embedding, so these numbers mainly measure the text
side.

| Metric | Value |
|---|---|
| Positive queries | 38 |
| Mean precision@5 (k = min(5, results)) | **0.835** |
| Mean recall | **0.934** |
| Top-1 hit rate | **0.895** |
| Should-be-empty queries returning nothing | **11 / 12** |
| Product examples | 5/5 found (red car: 1 of 2 visual images, see below) |

Notable results:
* All product examples, quoted phrases, accents (`crème brûlée` = `creme brulee`), plurals
  (`boarding passes`, `receipts`), date phrases (`summer 2025`, `3 weeks ago`, `last
  summer`, `this month`, `last week`), person rules (`message from Mom`, `chat with Jami` →
  empty, `conversation with Jamal` → empty) and every stop-word, punctuation and emoji
  negative behave correctly.
* Misses that are defects: precision from expansions (QA-15), typo "recipt" (QA-16),
  "car insurance quote" not empty (QA-17).
* Misses that come from the fake model: "red car" and "sunset over the sea" each return 1 of
  2 visual images. The fake model gives the extra concept a cosine of 0.82 against a best of
  1.0, which falls outside the 0.07 margin. Real CLIP similarities are compressed into
  0.2–0.33. These are not counted as defects; the device run found both red-car photos.
* Content-dependent misses (not defects): "doctor appointment" ranks the plumber's
  appointment first because the doctor's text says "Dr.", and "train ticket to Munich" ranks
  the Sam chat first because the ticket says "München".

The test asserts regression floors (P@5 ≥ 0.80, recall ≥ 0.90, negatives ≥ 11). Raise them
as search improves.

## 7. Performance

**Search, host (Windows, JIT), `test/eval/search_perf_test.dart`.** Full
`HybridSearchEngine.search` on a file DB with 512-d vectors and sparse OCR text (4000-word
vocabulary + common words), 8 realistic queries × 5 rounds:

| Images | median | p95 | max |
|---|---|---|---|
| 10,000 | 37.0 ms | 61.2 ms | 62.6 ms |
| 20,000 | 40.4 ms | 64.7 ms | 64.9 ms |

Adversarial queries at 20k: 200 rare words 389 ms, **1000 words 1912 ms** (QA-14), 60 common
words 338 ms, emoji 4 ms, RTL 10 ms, 10k punctuation characters 2 ms. Expect a mid-range
phone to be 2–4× slower, so realistic queries take ~80–160 ms, which is within G5 (< 1 s).

**Search on the emulator (release):** the UI shows 0.0–0.4 s per query over ~530 images,
including the first query after model load.

**Indexing on the emulator (release APK, from "Indexing run ended"):**

| Run | Images | Elapsed | Per image |
|---|---|---|---|
| First run after install (includes a manual pause of ~40 s and the model load) | 527 | 142.3 s | — |
| Re-index after *Delete local index* (model warm) | 527 | 108.5 s | **206 ms** |
| Run with the 8 adversarial files (fresh index) | 535 | 123.8 s | 231 ms |
| Incremental: 1 new screenshot | 1 | 0.63 s | 634 ms |

These are emulator figures (x86_64 host CPU). Measure on a mid-range arm64 phone before
quoting them publicly.

## 8. Not covered / follow-ups

* HEIC/AVIF originals, an Android 10 (API 29) device (QA-08) and a real arm64 phone.
* Android 14 "selected photos" → *Change selection* flow with the system picker (only the
  revoke path was exercised).
* Accessibility with TalkBack, and font scale 2.0 (1.3 tested).
* Very large galleries (> 5,000 real images) on a device: memory use of the vector index
  (~20 MB at 10k).
