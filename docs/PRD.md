# AI Gallery — Product Requirements

**Your personal visual search assistant.** Find any photo or screenshot by describing it in
plain language. Everything runs on the phone; the release app has no internet permission.

## Problem
People keep thousands of photos and screenshots — receipts, chats, menus, tickets, addresses —
and cannot find the one they need. Scrolling by date and folder is slow; cloud search means
handing over private images.

## Goals
| # | Goal | Measure |
|---|------|---------|
| G1 | Find a remembered image from a short description | Target image in the first screen of results for most realistic queries |
| G2 | Privacy that users can verify | No INTERNET permission; privacy stated on onboarding and in Settings |
| G3 | Trustworthy results | Every result explains *why* it matched; no-match queries return "nothing found", never padding |
| G4 | Usable without instructions | First search possible within 1 minute of install, no tutorial |
| G5 | Fast | Results typically < 1 s on a mid-range phone once indexed |

**Non-goals (v1):** face/person recognition, editing or deleting photos, albums, cloud sync,
accounts, analytics, video search.

## Users and key journeys
**Primary user:** an everyday Android user with a large, messy camera roll and many screenshots.

1. **First run.** Open app → read 3-point value + privacy explanation → *Allow photo access* →
   Home. Indexing starts automatically and the status card shows progress. User can search right
   away; results cover what is indexed so far.
   - *Denied:* explanation + *Try again*. *Permanently denied:* explanation + *Open Settings*;
     returning to the app re-checks access.
   - *Android 14 "selected photos":* Home shows a banner; *Change selection* opens the system
     picker, then the index re-syncs.
2. **Find a screenshot.** Home → tap search or an example chip → type "screenshot of my chat with
   Jamie" → grid of matches, with "Understood as Screenshots" → open one → see "Contains the text
   'Jamie'" with the snippet highlighted → Share.
3. **Narrow down.** Add a date filter (This month / custom range) or type filter (Screenshots /
   Photos) → results update in place.
4. **Nothing found.** Honest empty state with tips (simpler words, words that appear in the
   image, clear filters, indexing still running).
5. **Manage privacy.** Settings → see what is stored and where → *Delete local index* (confirm)
   → optionally *Re-index now*.

## Functional requirements
**Onboarding / permission**
- R1 Show value prop, on-device processing, no uploads, no internet permission, no face recognition.
- R2 Handle granted, limited, denied and permanently denied (system settings deep link).
- R3 Re-check permission whenever the app returns to the foreground.

**Home**
- R4 Greeting, prominent search entry, privacy line.
- R5 Example query chips (queries only, never fake results).
- R6 Recent searches (from the local store), tappable, clearable.
- R7 Indexing status card: scanning, indexing (X of Y + bar, Pause), paused (Resume), completed
  (count, last updated, unreadable count), error (Try again), permission denied (Allow access).
- R8 Start indexing after permission is granted and on every app resume (incremental, no-op if running).

**Search**
- R9 Free-text query; date filter (Any time, Today, This week, This month, This year, Custom
  range); type filter (All, Screenshots, Photos). Filters combine with what the parser infers.
- R10 Show the parser's interpretation subtly ("Understood as Screenshots · Summer 2025").
- R11 Quiet notice when visual search was not used (text-only results).
- R12 Responsive grid (2–6 columns by width), thumbnail + date; results in relevance order;
  never padded with weak matches.
- R13 Loading skeleton on first search; thin progress bar while refining; friendly error + retry.
- R14 Record each submitted query in recent searches.

**Viewer**
- R15 Full image with pinch/double-tap zoom; swipe between results.
- R16 "Why this matched": every `MatchReason`, OCR snippet with matched terms highlighted,
  plain-language strength.
- R17 Metadata: date/time, type, dimensions, file name, folder. Share via system sheet.
- R18 If the image no longer exists, explain and disable Share.

**Settings**
- R19 Photo access status with the right action (allow / change selection / open settings).
- R20 Indexing status, pause/resume, *Re-scan now*.
- R21 Stats: searchable images, screenshots, images with text, visual-search-ready, index size, last update.
- R22 Privacy: processed on device, nothing leaves the device, what is stored, where, no face recognition.
- R23 Clear recent searches; *Delete local index* with confirmation, then offer re-index.
- R24 About: name, version, licenses.

## Non-functional requirements
- **Privacy:** no network calls, no analytics; index lives in app-private storage.
- **Honesty:** copy never implies identifying people; names match only as text in images.
- **Accessibility:** semantic labels, ≥ 48 dp targets, text scaling to 200 % without overflow,
  WCAG AA contrast in light and dark.
- **Reliability:** every provider error maps to a friendly state with retry; no crash on denied
  access, missing files or failed share.
- **Performance:** thumbnails 256 px, cached by the repository; lists/grids are lazy.

## Release criteria (UI)
`flutter analyze` clean; widget tests cover onboarding permission states, home status card states,
search results/empty/error/filters, viewer reasons + missing image, settings delete confirmation.

## Open questions
- Should indexing also re-run when MediaStore reports changes while the app is open
  (`GalleryRepository.changes`)? Currently owned by the indexing service.
- Per-reason strength thresholds (Strong ≥ 0.75, Good ≥ 0.5) to be tuned with the search engine.
