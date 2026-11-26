# AI Gallery: release checklist

Work through it top to bottom for every store release. Items marked **BLOCKER** must be
resolved first. Background is in `docs/SECURITY_AUDIT.md` and `docs/QA_REPORT.md`.

## 0. Blockers for this release

- [x] ~~Commercial-release blocker: MobileCLIP-S0 research-only weights~~. Resolved in 2.0:
      the visual model is SigLIP B/16 (Apache-2.0); see `docs/SEARCH_DESIGN.md` §4.
- [x] Model, ONNX Runtime and ML Kit licences are registered on the in-app licence page.

## 1. Version

- [ ] Bump `version:` in `pubspec.yaml` (`x.y.z+build`; the build number must increase for
      every Play upload).
- [ ] Update `appVersion` in `lib/features/settings/presentation/settings_controller.dart` to
      match. It is shown in Settings › About and is not derived automatically.
- [ ] If OCR, text joining, dHash, the embedding model or preprocessing changed, bump
      `kPipelineVersion` in `lib/features/indexing/pipeline_version.dart`, so existing
      indexes are rebuilt.
- [ ] If the DB schema changed, add a migration (never edit a released one) and test the
      upgrade from the previous release's file.

## 2. Model assets (generated, not in git)

`assets/models/**/*.onnx` is gitignored. A clean checkout builds an APK **without the
visual model**, and the app then silently runs text-only.

```
py -3.13 -m venv tool/.venv
tool/.venv/Scripts/python -m pip install -r tool/requirements.txt
tool/.venv/Scripts/python -I tool/fetch_models.py siglip_b16   # fp32 export, ~815 MB, sha256-verified
tool/.venv/Scripts/python -I tool/quantize_siglip.py           # int8 encoders
tool/.venv/Scripts/python -I tool/install_assets.py            # -> assets/models/siglip_b16/
```

- [ ] `assets/models/siglip_b16/` contains `siglip_b16_vision_int8.onnx` (115,852,766 B),
      `siglip_b16_text_int8.onnx` (111,622,590 B), `spiece_vocab.tsv`,
      `preprocessor_config.json`, `LICENSE_APACHE_2.0.txt` and `NOTICE.txt`.
- [ ] `flutter test test/ml/siglip_assets_test.dart` passes (checks the sizes in
      `SiglipAssets`).
- [ ] Check the APK: `unzip -l <apk> | grep onnx` lists both models.

## 3. Signing

- [ ] Create the upload keystore once (`keytool -genkey -v -keystore upload-keystore.jks
      -keyalg RSA -keysize 2048 -validity 10000 -alias upload`). Store it and its passwords in
      the team password manager, **never in git** (`*.jks` and `android/key.properties` are
      gitignored).
- [ ] Create `android/key.properties` with `storePassword`, `keyPassword`, `keyAlias` and
      `storeFile` (relative to `android/app/`).
- [ ] **Without `key.properties` the release build silently falls back to the debug key**
      (`android/app/build.gradle.kts`). Verify the signer before uploading:
      `apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk`, or
      `keytool -printcert -jarfile <aab>`. It must not say `CN=Android Debug`.
- [ ] Enrol in Play App Signing (Google holds the app-signing key; you upload with the upload
      key).

## 4. Build

- [ ] `flutter clean` (optional), `flutter pub get`, `flutter analyze` (no issues),
      `flutter test` (all pass; the current baseline is 340 passed, 1 skipped).
- [ ] The first build on a new machine needs network access: the `sqlite3` build hook
      downloads its prebuilt native library for each ABI.
- [ ] **Play Store:** `flutter build appbundle --release`. The AAB lets Play deliver one ABI
      per device.
- [ ] **Side-loaded APKs:** `flutter build apk --release --split-per-abi`. Flutter adds
      `1000 × ABI` to versionCode. Do **not** set `ndk.abiFilters` (it conflicts with
      split-per-abi). A universal APK is ~190 MB because the ONNX Runtime and ML Kit native
      libraries ship for every ABI. `--target-platform` alone does not remove them.
- [ ] R8 is on (`isMinifyEnabled`, `isShrinkResources`). Smoke-test OCR and visual search on
      the release build, because the keep rules in `proguard-rules.pro` cover ML Kit and
      ONNX Runtime reflection/JNI.
- [ ] Archive `build/app/outputs/mapping/release/mapping.txt` and upload it to Play (for
      deobfuscated crash stacks).

## 5. Manifest and permission check (on the built artefact)

```
aapt2 dump permissions build/app/outputs/flutter-apk/app-release.apk
aapt2 dump badging    build/app/outputs/flutter-apk/app-release.apk | head
```

- [ ] Permissions are exactly `READ_MEDIA_IMAGES`, `READ_MEDIA_VISUAL_USER_SELECTED`,
      `READ_EXTERNAL_STORAGE (maxSdkVersion=32)` and the AndroidX
      `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`.
- [ ] **No `android.permission.INTERNET`** and no `ACCESS_NETWORK_STATE`. The app's privacy
      copy depends on this. ML Kit merges both in; `src/release/AndroidManifest.xml` removes
      them.
- [ ] In `build/app/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml`:
      `allowBackup="false"`, no `debuggable`, and the only `exported="true"` entries are
      `MainActivity` and `ProfileInstallReceiver` (DUMP-protected).
- [ ] `targetSdkVersion` meets the current Play requirement (36 now). `minSdkVersion` 26.

## 6. Store listing and privacy declarations

**Data safety form**
- [ ] Data collected: **None**. Data shared: **None**. The app has no network permission, no
      accounts and no analytics. All processing happens on the device.
- [ ] "Is data encrypted in transit": not applicable (nothing transmitted).
- [ ] "Can users request deletion": yes. Settings › *Delete local index* and *Clear recent
      searches*; uninstalling also removes all data.
- [ ] Photos and videos access: declare it as core functionality (searching the user's own
      gallery). Images only; no video or audio permission.
- [ ] **Photo and video permissions policy:** Play limits `READ_MEDIA_IMAGES` to apps whose
      core purpose needs broad photo access. Prepare the declaration (gallery search is the
      core feature) and a short video. Point out that limited access (Android 14 picker) is
      supported.

**Privacy policy** (required because of the photo permission)
- [ ] Says that images, recognised text and visual descriptors (embeddings) are processed and
      stored only on the device, are never uploaded, are excluded from backups, and are
      deleted by *Delete local index* or uninstall.
- [ ] Discloses that text recognition uses Google ML Kit's on-device model (required by the
      ML Kit terms), and that the app does not identify people or faces.

**Listing**
- [ ] Do not claim face or person recognition. Names are matched only as text in images.
- [ ] 512 × 512 icon: `tool/branding/play_store_icon_512.png`. Feature graphic and
      screenshots in light and dark mode.
- [ ] Content rating questionnaire, target audience, and the "contains ads: no" declaration.

## 7. Licences and attributions

- [ ] In-app "Open-source licenses" shows the Dart/Flutter packages, plus SigLIP (notice and
      Apache-2.0 text), ONNX Runtime (MIT) and the ML Kit terms (text recognition and face
      detection).
- [ ] No GPL/LGPL/MPL dependencies were added since the last audit (check the `pubspec.lock`
      diff).

## 8. Manual smoke test (release build on a real arm64 phone and the emulator)

Push the fixture gallery first: `tool/.venv/Scripts/python -I tool/fixtures/make_fixtures.py --push`.
Save screen captures under `/data/local/tmp`, not `/sdcard`, because the app indexes
anything under `/sdcard`.

- [ ] Fresh install: splash screen, then onboarding; no colour flash in light or dark mode.
      The launcher icon looks right (including the themed/monochrome icon on Android 13+).
- [ ] *Allow photo access*: **Don't allow** shows the explanation and *Try again*. *Allow all*
      goes to Home, and indexing starts with an X of Y progress bar.
- [ ] Pause and Resume work. Backgrounding and resuming the app while paused keeps it paused.
- [ ] Each product example returns the right image (see `tool/fixtures/out/expected.json`):
      Jamie chat, Germany trip, bank details, restaurant menu last summer, red car; "zebra
      crossing in tokyo" shows the "No matching photos" empty state.
- [ ] Viewer: zoom, swipe, "Why this matched" with the highlighted snippet, Share opens the
      system sheet.
- [ ] Delete an image in the system gallery, then open it from the results: "This photo is no
      longer available", and Share is disabled.
- [ ] Settings: the stats are plausible. *Delete local index* sets the stats to 0; *Re-scan
      now* rebuilds them. Recent searches are cleared.
- [ ] Add a new screenshot while the app is open: it can be found within ~5 s.
- [ ] Revoke the photo permission in system settings, then return to the app: no crash; the
      limited-access banner or onboarding appears.
- [ ] Dark mode (`adb shell cmd uimode night yes`) and font scale 1.3 and 2.0
      (`adb shell settings put system font_scale 1.3`): no clipped or overflowing text.
      Restore both afterwards.
- [ ] Airplane mode: everything above still works (it must, with no INTERNET permission).
- [ ] `adb logcat --pid=$(adb shell pidof com.bachar02.ai_gallery)` contains no recognised
      text, queries, file names or paths.
- [ ] Throughput sanity check: the "Indexing run ended" log line shows elapsedMs / processed.
      The emulator baseline is ~206 ms per image.
