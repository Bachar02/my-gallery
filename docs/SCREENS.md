# AI Gallery — Screen Specifications

Navigation: `AppGate` (root) → `HomeScreen` ⇄ `SearchScreen` → `ViewerScreen`; Home → `SettingsScreen`.
Routes are plain `MaterialPageRoute`s exposed as `Screen.route(...)`.

## 0. App gate (`lib/app/app.dart`)
Watches `galleryPermissionProvider` (wraps `GalleryRepository.permissionStatus()`):

| Permission state | Shows |
|---|---|
| loading (first check) | Centered progress indicator |
| error | `ErrorView` "Couldn't check photo access" + Try again |
| granted / limited | Home |
| denied / permanentlyDenied | Onboarding |

Cross-fades (250 ms) between them. Side effects: when access becomes available → `IndexingService.start()`;
on app resume → re-check permission, then `start()` if access is available (incremental, no-op
when running); when indexing leaves a running phase → invalidate `indexStatsProvider`.

## 1. Onboarding (`features/onboarding/presentation`)
Scrollable single column (max 560 dp): brand icon, headline "Find any photo by describing it",
example-led subtitle, three points (Just describe it · Reads text in your images — no face
recognition · Private by design — on-device, no uploads, no internet permission), primary button,
footnote "You can allow all photos or only some…".

| State | Content |
|---|---|
| Not asked (denied) | **Allow photo access** → system dialog |
| Requesting | Button disabled with inline spinner |
| Denied after asking | Info note "Photo access wasn't allowed…", button **Try again** |
| Permanently denied | Info note with Settings path, button **Open Settings** (`openAppSettings`) |
| Limited / granted | Gate moves to Home |
| Request threw | Snackbar, state unchanged |

## 2. Home (`features/home/presentation`)
Top row: app mark + "AI Gallery", Settings icon button. Greeting (time of day) + headline
"What are you looking for?". Read-only `AppSearchField` → Search. Privacy badge.
Limited-access banner (warning container, **Change selection** → `manageLimitedSelection()` then re-sync).
Indexing status card. "Try asking" example chips → Search with that query.
"Recent searches" (hidden when empty) with **Clear**; rows → Search.

Status card states (from `indexingProgressProvider` + `indexStatsProvider`):

| Phase | Title | Message | Progress | Action |
|---|---|---|---|---|
| loading | skeleton | | | |
| stream error | Couldn't read indexing status | Search still works… | | Try again (re-subscribe) |
| idle, empty index | Get your photos ready | explains on-device prep | | Check for new photos |
| idle, has index | N photos ready to search | Last updated … | | Check for new photos |
| scanning | Looking for new photos… | | indeterminate | |
| indexing | Preparing photos for search | X of Y · You can search while this runs | determinate | Pause |
| paused | Paused | X of Y prepared… | determinate | Resume |
| completed | N photos ready to search | Up to date · Updated … (+ unreadable count) | | |
| error | Preparing photos stopped | photos so far still searchable (+ error detail) | | Try again |
| permissionDenied | Photo access needed | can't see your photos | | Allow access |

## 3. Search (`features/search/presentation`)
Header: back + `AppSearchField` (autofocus unless opened with a query). Filter bar: date chip
(sheet: Any time, Today, This week, This month, This year, Custom range… → date range picker)
and All / Screenshots / Photos. Changing filters re-runs the current query (not re-recorded).
State lives in `searchControllerProvider` (auto-disposed; stale responses ignored).

| State | Content |
|---|---|
| Idle (no text, no filters) | "Describe what you remember" + tips + example chips |
| First load | Static skeleton grid |
| Refining (has previous results) | Previous results + 2 dp progress bar |
| Results | Text-only notice (if `semanticSearchUsed == false`), "Understood as …" (parser kind/date not already set as filters), "N matches · 0.1 s", grid |
| No results | "No matching photos" + honest message + tips (indexing in progress, simpler words, words in the image, text-only, remove filters) + **Clear filters** when filters set |
| Error | "Search didn't work" + Try again |

Grid: columns by width (2–6), 8 dp gaps, tile = square thumbnail + date caption. Tap → Viewer
with the full result list.

## 4. Viewer (`features/viewer/presentation`)
Dark theme. Transparent app bar: back, "i of N", **Share** (`ImageActions.share`; disabled when
missing/loading; failure → snackbar). Horizontal `PageView` across results (locked while zoomed).
Image: `displayImage` in `InteractiveViewer` (1–5×, double-tap 2.5× toggle).
Draggable details sheet (14 % / 30 % / 90 %): **Why this matched** — per reason: signal icon,
description, strength label (Strong ≥ .75 / Good ≥ .5 / Possible), OCR snippet with matched terms
highlighted; **Details** — date & time, type, dimensions, file name, folder (selectable).

| State | Content |
|---|---|
| Loading | Centered spinner |
| `getImage` or `displayImage` returns null | "This photo is no longer available" + explanation + Back to results |
| Load error | "Couldn't open this photo" + Try again |
| Decode failure | "Couldn't display this image" in the image area |

## 5. Settings (`features/settings/presentation`)
Sections (cards, max 720 dp):
1. **Photo access** — Full access / Selected photos only (Change selection, Allow all photos →
   system settings) / Not allowed (Allow access) / Turned off (Open Settings) / error (Retry).
2. **Indexing** — status card (same as Home, with Pause/Resume) + **Re-scan now** (disabled while running).
3. **Your index** — searchable images, screenshots, images with text, ready for visual search,
   index size, last updated; loading spinner; error with Retry.
4. **Privacy** — processed on this phone; nothing leaves your device (no internet permission, no
   account, no analytics); what's stored (text, numeric visual description, file details, recent
   searches — no photo copies); where (app-private storage); no face recognition.
5. **Your data** — Clear recent searches; **Delete local index** → dialog "Delete local index?"
   (Cancel / Delete). On confirm: stop indexing → `IndexStore.clearAll()` → invalidate stats and
   recent searches → snackbar "Local index deleted" with **Re-index now**. Failure → snackbar.
6. **About** — AI Gallery, version, "Works fully offline", open-source licenses.
