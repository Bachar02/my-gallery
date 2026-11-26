# AI Gallery: security and privacy audit

Scope: release build `1.0.0+1` (`flutter build apk --release --target-platform android-x64`,
built 2026-11-23 15:02 from the current tree), source under `lib/` and `android/`, and the
resolved dependencies in `pubspec.lock`. Method: static review, inspection of the merged
release manifest and the APK, host tests that inspect database bytes, and a device pass on
emulator-5554 (Pixel XL, API 36, x86_64). Claims in the other docs were checked, not assumed.

Summary: the privacy model holds. The release APK requests no network permission, and the
app contains no networking code. It stores its data only in app-private storage and keeps it
out of backups. Six issues were found. Three are fixed: log and status-card leaks of OCR text
through `SqliteException`, and deleted text remaining in the SQLite WAL. Three are open and
low severity (S-4 to S-6). The one release blocker is licensing: the MobileCLIP-S0 weights
cannot be used in a commercial release (S-7).

## 1. Permissions (merged release manifest)

`aapt2 dump permissions build/app/outputs/flutter-apk/app-release.apk`:

| Permission | Why | Verdict |
|---|---|---|
| `READ_MEDIA_IMAGES` | read gallery images (API 33+) | required |
| `READ_MEDIA_VISUAL_USER_SELECTED` | Android 14+ "limited access" | required |
| `READ_EXTERNAL_STORAGE` (maxSdk 32) | gallery on API 26–32 | required |
| `com.bachar02.ai_gallery.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | AndroidX signature permission for runtime receivers | harmless |

**No `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, camera, location, video/audio,
`MANAGE_EXTERNAL_STORAGE` or `AD_ID`.** These are removed by `src/main` and `src/release`
manifests with `tools:node="remove"`. The ML Kit / Google data transport libraries merge in
`INTERNET` and `ACCESS_NETWORK_STATE`, so that removal is required. Do not delete
`android/app/src/release/AndroidManifest.xml`. `application`: `allowBackup="false"`, no
`usesCleartextTraffic`, and release builds are not debuggable (`dumpsys package` flags
`[ HAS_CODE ALLOW_CLEAR_USER_DATA ]`).

## 2. Exported and declared components

| Component | Exported | Notes |
|---|---|---|
| `.MainActivity` | yes | launcher only (MAIN/LAUNCHER), no data intent filters, no deep links |
| `androidx.profileinstaller.ProfileInstallReceiver` | yes | guarded by `android.permission.DUMP` (shell/system only) |
| `share_plus` `ShareFileProvider` | no | `grantUriPermissions`, paths limited to `cache/share_plus/` |
| `share_plus` `SharePlusPendingIntent` receiver | no | |
| ML Kit `MlKitComponentDiscoveryService`, `MlKitInitProvider` | no | |
| `GoogleApiActivity` (play-services-base) | no | unused |
| `androidx.startup.InitializationProvider` | no | |
| datatransport `TransportBackendDiscovery`, `JobInfoSchedulerService`, `AlarmManagerSchedulerBroadcastReceiver` | no | ML Kit telemetry pipeline, see section 3 |

No attack surface is reachable by other apps beyond launching the main activity.

## 3. Network code paths

* `grep -i` over `lib/`, `pubspec.yaml` and `android/app/src` for `http`, `HttpClient`,
  `Uri.parse`, `url_launcher`, `socket`, `firebase`, `analytics`, `google_fonts`,
  `crashlytics` and `sentry` found only XML namespace URLs and one Settings string
  ("No account, no analytics"). The app has no networking code.
* Dependencies: no HTTP client package is in the runtime graph. `url_launcher_*` appears in
  `pubspec.lock` only as linux/web/windows federated implementations; there is no Android
  implementation. Fonts are bundled (no `google_fonts`).
* **ML Kit telemetry.** `com.google.android.datatransport` (pulled in by ML Kit) logs ML Kit
  usage events to a local queue database and normally uploads them to Google. The release
  build has no `INTERNET` permission, so the upload always fails. The events contain usage
  statistics (latency, image size, model), never image content or text. They stay queued in
  app-private storage, bounded by datatransport's own size and TTL limits. Note for the store
  listing: no data is transmitted.
* **Offline behaviour verified on device.** With the release APK (no `INTERNET`), ML Kit OCR
  read all fixture texts (bundled Latin model, no download). MobileCLIP loaded from bundled
  assets in 1.4–3.0 s and embedded 527/527 images.
* `sqlite3` downloads its native binary at **build time** through its build hook. This is a
  build-machine concern, not a runtime path (see the release checklist).

## 4. Logging (release builds)

`debugPrint` is not stripped in release builds. Its output goes to logcat under the
`flutter` tag. Every call in `lib/` was reviewed:

| Finding | Status |
|---|---|
| **S-1** `SqliteException.toString()` appends the failing SQL **and its bound parameters**. Four store log lines interpolated `$e`, so after a corruption or disk-full error during `upsertAll` the log would contain the recognised text, file names or search queries of a whole batch. The same text went into `IndexingProgress.errorMessage`, **which the Home/Settings status card displays** ("Preparing photos stopped" details). | **Fixed.** `SqliteIndexStore.describeError` keeps the first line only (`lib/data/db/sqlite_index_store.dart:86`, used at :121, :195, :648, :819). `DefaultIndexingService.userFacingError` keeps the first line without `path = '…'` (`lib/features/indexing/default_indexing_service.dart:286`, used at :277). `RecentSearchesController.add` logs the exception type only (`lib/features/home/presentation/recent_searches_controller.dart:26`). Tests: `test/qa/privacy_wipe_test.dart` ("store error logging…"), `test/qa/indexing_robustness_test.dart` ("error state never exposes…"), `test/qa/ui_robustness_test.dart` ("…does not log the query text"). |
| A MediaStore image id was logged when an embedding had no model id. | **Fixed** (`sqlite_index_store.dart:304`). |
| Indexing logs: counts, exception *types* and stack traces only. "Indexing run ended" has counts and timings. | OK |
| `IndexStore: could not delete $path…` logs the app-private DB path, which holds no user data. | OK |
| **S-4 (open, Low).** Glide, inside photo_manager, logs `Load failed for [content://media/external/images/media/<id>]` with stack traces for undecodable images. These are MediaStore ids, not content. Seen on device for the zero-byte and garbage JPEGs. Since Android 4.1, only the system and adb can read logcat. | Open. Possible fix: lower Glide's log level in `MainActivity`, or accept it. |
| photo_manager native logging (`LogUtils`) is off unless `PhotoManager.setLog(true)` is called. The app never calls it. | OK |

Device check: after the full device pass (onboarding, indexing of 535 images, 20+ searches,
viewer, share, delete and re-index), the app's logcat contained no OCR text, query text,
file names or paths (`grep -i "jamie|iban|DE89|password|Screenshot_|/storage/"` on the app
pid found nothing).

## 5. Storage locations, file modes and clean-up

| Data | Location | Notes |
|---|---|---|
| Index DB, `-wal` and `-shm` | `files/index/ai_gallery_index.db` (`getApplicationSupportDirectory`) | app-private: inside the app's data directory (`/data/user/0/<pkg>`, 0700, per-app UID), so other apps cannot read it, whatever SQLite's own file mode is; never on shared storage |
| MobileCLIP models (66 MB) | `files/` (copied from APK assets on first load) | no user data. A second copy of the APK assets costs storage; documented |
| OCR fallback renditions | `cache/ocr_<µs>_<n>.jpg` | deleted in `finally` after each use. Verified by test "OCR fallback temp files are deleted, on success and on failure". A process kill mid-OCR can leave one file (no start-up sweep), **S-5** |
| Share fallback JPEG | `cache/share_export/` | folder emptied at the next export only. **S-5** |
| share_plus copies | `cache/share_plus/` | share_plus copies each shared file here and clears the folder at the **next** share. The last shared image stays in the app cache. **S-5** |
| photo_manager scoped cache | `cache/pm_<id>_<name>` | **S-6**: on **Android 10 (API 29) only** (`AndroidQDBUtils.shouldUseScopedCache`), `AssetEntity.file` copies every original into the cache and never deletes it. Indexing calls `originalFile` for every image, so on API 29 the whole gallery is duplicated into app cache. Not reproducible on the API 36 emulator |

* **S-5 (open, Low)**: copies of shared images and OCR renditions can stay in the app's
  private cache. Suggested fix: on start-up (and after "Delete local index"), delete
  `cache/share_plus`, `cache/share_export` and `cache/ocr_*`.
* **S-6 (open, Medium, API 29 only)**: suggested fix: add `GalleryRepository.releaseCaches()`
  (implementation: `PhotoManager.clearFileCache()`) and call it at the end of each indexing
  run. Alternatively, on API 29 run OCR on `displayImage(2048)` instead of the original.

## 6. Backup exclusion

`android:allowBackup="false"`, `fullBackupContent=@xml/backup_rules` (excludes every
domain), and `dataExtractionRules=@xml/data_extraction_rules` (cloud-backup and
device-transfer exclude every domain, including device-protected ones). This exceeds the
`index/` exclusion that `docs/DATABASE.md` asks for.

## 7. Deletion: secure_delete, clearAll, WAL

Verified with `test/qa/privacy_wipe_test.dart`, which plants unique tokens (OCR text, file
name, query) in a file-backed store in WAL mode and scans the raw bytes of `db`, `-wal`,
`-shm` and `-journal`:

| Operation | Result |
|---|---|
| `clearAll()` ("Delete local index"), main path (file delete + recreate) | no token in any file ✔ |
| `clearAll()` fallback (file cannot be deleted, so DELETE + VACUUM + `wal_checkpoint(TRUNCATE)`; forced on Windows with an open reader) | no token in any file ✔ |
| `delete([id])` (image vanished from the gallery) | **S-2: the OCR text survived in `-wal`** (main file was zeroed by secure_delete). **Fixed**: `_truncateWal` after the delete (`sqlite_index_store.dart:381`, :814) ✔ |
| `clearRecentSearches()` | **S-3: the query text survived in `-wal`. Fixed** (`sqlite_index_store.dart:804`) ✔ |
| re-index of an image whose text changed (e.g. the user cropped an IBAN out) | **Open (QA-07, Low)**: the old text stays in `-wal` frames until they are overwritten. Test present but skipped. Suggested fix: in `upsertAll`, detect rows whose `ocr_text` changed (compare with the stored value inside the transaction) and run `_truncateWal` after the commit when any did |

Device: after "Delete local index" the Settings stats went to 0 and "Re-scan now" rebuilt
the index (527 images, 108.5 s). Release builds are not debuggable, so the files could not
be inspected on the device (`run-as` is unavailable). The byte-level checks above are
host-only.

## 8. FTS query injection

`buildFtsQuery` reduces every term to `\p{L}\p{N}\p{M}\p{Co}` runs and emits each part as a
quoted FTS5 string. All values are bound parameters. The existing test "malicious input never
throws and never alters results" covers `" * NEAR( OR AND NOT - : ^ ( ) { } +`, column
filters, and `'; DROP TABLE images; --`. The QA evaluation adds punctuation-only, emoji-only,
RTL and 10k-character punctuation queries through the full engine: none throw, and all
return empty or correct results. No injection path was found.

## 9. Dependency licences (`pubspec.lock`, runtime graph)

All Dart and Flutter packages are permissive: MIT (riverpod, flutter_riverpod,
sqlite3, image, archive, flutter_onnxruntime, google_mlkit_*, uuid, posix, state_notifier,
cupertino_icons), BSD-3-Clause (Dart/Flutter team packages: path, intl, crypto, collection,
share_plus, cross_file, path_provider*, jni*, mime, ffi, logging, …) and Apache-2.0
(photo_manager, material_color_utilities). **No copyleft (GPL/LGPL/MPL) packages.**

Native or bundled components:

| Component | Licence | Note |
|---|---|---|
| SQLite (bundled by `sqlite3` hooks) | public domain | |
| ONNX Runtime 1.28 (AAR) | MIT | |
| Glide (via photo_manager) | BSD/MIT/Apache | |
| Google ML Kit Text Recognition (bundled Latin model) | Google ML Kit Terms of Service / Google APIs ToS | proprietary, free. The ToS require that the use be disclosed in the privacy policy |
| **MobileCLIP-S0 weights** | **Apple Machine Learning Research Model License: research use only, excludes commercial products.** The Xenova ONNX export ships an earlier permissive Apple licence, and both texts are bundled | **S-7, release blocker for any commercial release.** Not a blocker for a non-commercial/research build. Replacement path in `docs/AI_PIPELINE.md` §8 |

**S-8 (open, Low)**: the in-app "Open-source licenses" page lists only Dart packages and
engine components. On device, MobileCLIP (Apple AMLR / Xenova export), ONNX Runtime native
and the ML Kit terms are absent, although `assets/models/mobileclip_s0/LICENSE_*.txt` are
bundled. Fix: register them with `LicenseRegistry.addLicense` in `main()`.

## 10. Other observations

* The release APK has **no network permission, and the onboarding and Settings copy says so**.
  Both statements are true.
* The APK is 190 MB because plugin AARs bundle native libraries for all ABIs (ONNX Runtime and
  ML Kit for arm64, armv7, x86_64) and `--target-platform` only filters Flutter's own
  libraries. Not a security issue. Ship an AAB or `--split-per-abi` (release checklist).
* On Android 14+, revoking full photo access in system settings makes Android grant
  `READ_MEDIA_VISUAL_USER_SELECTED` with nothing selected. The app then lists 0 images,
  **removes every record from the index** (correct for privacy) and shows the
  limited-access banner. Revoking both permissions returns the app to onboarding.

## Update for version 2.0 (2026-11-25)

* **S-7 resolved.** The bundled visual model is now SigLIP B/16 under the Apache
  License 2.0 (int8 copies; `assets/models/siglip_b16/NOTICE.txt`); the MobileCLIP-S0
  weights are no longer shipped. **S-8 resolved:** the licence page lists SigLIP,
  ONNX Runtime and ML Kit.
* New on-device processing: ML Kit face detection counts faces in photos (fast mode, no
  landmarks, classification or tracking; only the number is stored). No identity, no
  attribute inference.
* New stored data (schema v2): OCR line boxes, screen type, chat title and message text,
  app label from the file name, face count. Same sensitivity as the OCR text already
  stored; deleted by *Delete local index* (rows removed with `secure_delete`, WAL
  truncated after re-indexing changes text).
* The developer score breakdown is off by default, local only; "Copy report" puts it on
  the clipboard on the user's request and contains no file names or ids.
* The release manifest still has no INTERNET permission (checked on the 2.0 APK).
