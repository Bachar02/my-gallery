# AI Gallery — Design System

Calm, assistant-like, privacy-first. Material 3, light + dark, built-in Material Icons, system
font (Roboto on Android — nothing downloaded or bundled). Code: `lib/core/design/`,
components: `lib/core/widgets/`.

## Color
Generated with `ColorScheme.fromSeed` (tonal spot) so every on/container pair meets contrast in
both themes; a test asserts ≥ 4.5:1 for `onSurface`, `onSurfaceVariant` and `onPrimary`.

| Token | Value | Use |
|---|---|---|
| Seed / primary | `#1B6B73` lagoon teal | Brand, primary actions, icons in content |
| Tertiary (accent) | from `#B4652A` warm amber | Secondary emphasis (sparingly) |
| Surface roles | M3 `surface`, `surfaceContainerLow…Highest` | Backgrounds, cards (Low), inputs (High), skeletons (Highest) |
| Error roles | M3 `error`, `errorContainer` | Error cards, destructive actions |

Semantic extension `AppSemanticColors` (light / dark):

| Role | Light | Dark | Use |
|---|---|---|---|
| success | `#2E7D4F` | `#8BD6A6` | "Ready to search" icon |
| warningContainer / on | `#FFE4B5` / `#3D2800` | `#5A3D00` / `#FFE4B5` | Limited access, permission needed |
| highlight / on | `#FFE28A` / `#231B00` | `#5C4A00` / `#FFF1C2` | Matched terms in OCR snippets |

The viewer always uses the dark theme (photos read best on a dark canvas).

## Typography
Material 2021 scale with tuned weights (`AppTypography.tune`):
headlineMedium 28/600 (screen titles), titleLarge 22/600 (app bar, empty states),
titleMedium 16/600 (card titles), titleSmall 14/600 (section headers, onSurfaceVariant),
bodyLarge 16 / 1.5 line height (primary copy), bodyMedium 14 / 1.45, bodySmall 12 (meta, notices),
labelLarge 14/600 (buttons, chips), labelMedium 12 (tile dates).
All text scales with the system setting; layouts are verified at 200 %.

## Spacing, radii, elevation, motion
- **Spacing (`AppSpace`, 4-pt):** xxs 4 · xs 8 · sm 12 · md 16 · lg 24 · xl 32 · xxl 48.
  Page gutter 16. Section header: 24 above, 8 below.
- **Radii (`AppRadius`):** sm 8 (chips, snippets) · md 12 (buttons, tiles, list items) ·
  lg 16 (cards) · xl 28 (search field, sheets, dialogs) · pill.
- **Elevation (`AppElevation`):** 0 / 1 / 3 / 6. Prefer tonal surfaces; cards are flat (0),
  app bar shows 3 only when content scrolls under.
- **Motion (`AppMotion`):** 150 ms short, 250 ms medium, easeOutCubic. Used only for the
  onboarding→home cross-fade, route transitions and sheet snapping. No decorative animation;
  skeletons are static.
- **Layout (`AppLayout`):** compact < 600, medium < 840. Single-column content max 720 dp
  (560 on onboarding). Result grid columns: < 360 → 2, < 600 → 3, < 840 → 4, < 1200 → 5, else 6.
  Minimum touch target 48 dp (`MaterialTapTargetSize.padded`).

## Components (`lib/core/widgets`)
| Component | Purpose / rules |
|---|---|
| `AppSearchField` | Pill input, search icon, clear button. `readOnly` mode acts as a button on Home. Hint: "Describe the photo you're looking for". |
| `QueryChip` | Example query (ActionChip). Text only — never represents a result. |
| `SectionHeader` | titleSmall header with optional trailing action (e.g. "Clear"); marked as a semantic header. |
| `IndexingStatusCard` + `IndexingStatusView` | One card, one contextual action. View model maps `IndexingProgress` + `IndexStats` → title, message, tone, progress, action. Tones: neutral, working, success, warning (warningContainer), error (errorContainer). |
| `SearchFilterBar` | Horizontal scroll: date FilterChip (opens preset sheet) · divider · All/Screenshots/Photos ChoiceChips. |
| `ResultTile` / `GalleryThumbnail` | Square thumbnail (radius md) + date caption with screenshot icon. Caption height derived from text scale so tiles never overflow. Semantics: "Screenshot from 3 Jun 2025, Contains the text 'Jamie'". |
| `MessageView` / `ErrorView` / `TipLine` | Centered icon-in-circle, title, message, optional tips and actions. Used for idle, empty, missing and error states. |
| `HighlightedText` | Case-insensitive term highlighting with the highlight role. |
| `SkeletonBox`, `IndexingStatusCardSkeleton` | Static placeholders matching final layout. |
| `PrivacyBadge` | Lock icon + "Searches run on this phone. Nothing is uploaded." |
| `ContentWidth` | Centers and caps content width on tablets. |

## Voice and copy
- Second person, short, warm, specific. Sentence case. Curly quotes/apostrophes.
- Honest: "No matching photos… AI Gallery only shows images it's confident about."
  Never "we found something similar".
- People: never imply recognition of faces or identities — "a name is found only when it
  appears as text".
- Errors: what happened + that the user's photos are fine + what to do ("Try again").
- Privacy claims are concrete and verifiable ("no internet permission").

## Accessibility checklist
Semantic labels on icon buttons (tooltips), images and tiles; live regions on status and result
counts; headers marked; 48 dp targets; 200 % text without overflow (tested); contrast AA (tested);
no information conveyed by color alone (icons + text accompany every tone).
