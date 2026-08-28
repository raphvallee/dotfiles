# ForUI Migration Plan — Tracker

## Context

The app is migrating from Material Design widgets to [ForUI](https://forui.dev) (0.26.0, shadcn/ui-inspired) while keeping full feature parity. Work already started: commit a5ae746 added the dependency and the root theme wiring; a batch of uncommitted changes converted the bottom nav, many cards, and several buttons to Forui widgets. Roughly 14 pages still use Material widgets, `Theme.of(context)` is read in ~40 places, and one file (`new_split_page.dart`) is currently syntactically broken.

Goal of this plan: finish the migration incrementally, each phase compiling and passing tests, with no feature or behavior regressions.

## Current state (verified by exploration)

**Already Forui-wired** (root, keep as-is):
- `lib/main.dart`: `MaterialApp` root + `builder:` injecting `FTheme` (light/dark selected via `Theme.brightnessOf`, touch/desktop variant via `defaultTargetPlatform`) → `FToaster` → `FTooltipGroup`; `home: FScaffold(child: HomePage())`; `FLocalizations` delegates + supported locales.
- Already converted (uncommitted): `home_page.dart` (`FBottomNavigationBar` + `FBottomNavigationBarItem`), `FCard` in feed/history/exercises/session-detail pages, `FButton` in `editor_page`, `split_day_page`, `progression_page`, `custom_app_bar` action, `showFSheet` in `gym_picker.dart`.

**Blocker**: `lib/pages/workout/new_split_page.dart` line 3 is corrupted (`readonly=false} ) 银雀} mbilu= noimport ...`) — parse error; nothing analyzes until fixed.

**Still Material**: `settings_page.dart`, `settings/gyms_page.dart`, `workout/workout_page.dart`, `workout/split_day_editor_page.dart`, `workout/new_split_page.dart`, `workout/exercise_picker_page.dart`, `exercises/exercise_detail_page.dart`, `exercises/new_exercise_page.dart`, `analytics/graph_editor.dart`, plus Material widgets interleaved in already-touched pages (dialogs, text fields, tiles, `Theme.of` reads), and `custom/line_chart.dart`, `custom/custom_route.dart`, `custom/custom_app_bar.dart` internals.

**Inventory of remaining Material widgets**: `Card` ×14, `ListTile` ×12, `TextField`/`TextFormField` ×15, `DropdownButton(FormField)` ×5, `showDialog`+`AlertDialog` ×6, `SnackBar` ×5, `SegmentedButton` ×2, `FilterChip` ×4, `SwitchListTile` ×2, `PopupMenuButton` ×2, `ExpansionTile` ×1, `showModalBottomSheet` ×1, `ReorderableListView` ×1, `CircularProgressIndicator` ×6, `Icons.*` ×16 files, `Theme.of(context)` ×~40.

**Tests**: `test/integration/app_test.dart` is already Forui-aware. `settings_test.dart`, `workout_test.dart`, `history_test.dart`, `analytics_test.dart` pump raw `MaterialApp` and assert on Material widget types (`SwitchListTile`, `TextField`, …) — they will break and must be updated alongside the widget migrations.

## Decisions (confirmed with user)

1. **Keep `MaterialApp` as root** — this is Forui's documented integration pattern (FTheme via builder + `toApproximateMaterialTheme()`), zero risk.
2. **Keep `SliverAppBar` (CustomAppBar), restyle only** — FHeader is not a sliver and would change pinned-scroll behavior on all 15 pages.
3. **Migrate icons to `FLucideIcons`** — full visual consistency with Forui; Material icon font can remain in `pubspec` for any leftovers.

## Target architecture

- Root: `MaterialApp` with `theme`/`darkTheme` = `FThemeData.toApproximateMaterialTheme()` (bridges Material widgets like `SliverAppBar`, `ExpansionTile`, `CircularProgressIndicator` to the Forui palette), `builder:` FTheme wrapper unchanged.
- Pages read **`context.theme`** (`FTheme.of`, from `package:forui/forui.dart`) instead of `Theme.of`. Mapping: `colorScheme.primary` → `context.theme.colors.primary`; `onSurfaceVariant` → `colors.mutedForeground`; `surface` → `colors.background`/`colors.card`; Material `textTheme.*` → `context.theme.typography.*`.
- Hardcoded colors become theme tokens: `Colors.orange` (warm-up chip, `session_detail_page.dart:205`) and `Colors.blueAccent`/`Colors.white` (`editor_page.dart:203`) map to theme colors (e.g. `colors.primary`/`colors.destructive` or a custom `FColors` extension if an orange token is wanted).

## Widget mapping (Material → Forui)

| Material | Forui | Notes |
|---|---|---|
| `Card`, tile rows (`Material`+`InkWell`) | `FCard`, `FItemGroup`/`FItem` | Pattern already used in uncommitted work |
| `ListTile` | `FItem` (title/details/prefix/suffix) or `FCard`+row | 12 sites |
| `TextField`/`TextFormField` | `FTextField` | Keep controllers, `Form`/validators; map `InputDecoration` → `label`/`hint` params |
| `DropdownButton(FormField)` | `FSelect<T>` | Settings unit, movement pattern, rest targets, graph editor ×3 |
| `showDialog`/`AlertDialog` | `showFDialog` / `FDialog` | Preserve `Navigator.pop(context, value)` contracts |
| `SnackBar`+`ScaffoldMessenger` | `FToaster` toast | FToaster already installed at root |
| `showModalBottomSheet` | `showFSheet(side: .btt)` | Existing pattern: `gym_picker.dart` |
| `PopupMenuButton` | `FPopoverMenu` | `feed_page_graph_card.dart`, `gyms_page.dart` |
| `SegmentedButton` | `FTabs` | History list/calendar, Exercises browse mode |
| `SwitchListTile` | `FSwitch` inside a tile row | Settings; test expects exactly 2 toggles |
| `FilterChip` | `FCheckbox`/`FSelectGroup` | Warm-up toggle, muscle multi-select sections |
| `ExpansionTile` | `FAccordion` (verify availability in 0.26; fallback: hand-rolled expandable `FCard`) | `exercises_page.dart` muscle groups |
| `Icons.*` | `FLucideIcons.*` | 16 files |
| `CircularProgressIndicator`, `ReorderableListView`, `MaterialPageRoute`/`pushTo` | **keep** | Flutter core, no Forui equivalent / out of scope |

Caveat: verify each Forui widget's exact 0.26 API against the installed package during implementation (docs fetch via Context7 already done for `FSelect`, `FItemGroup`, `FDialog`, `FSheet`); adjust the fallback if a widget doesn't exist in 0.26.

## Phases

Each phase ends with: `cd tracker && flutter analyze && flutter test` green, then a separate commit (pre-commit hook runs `dart fix --apply` + `dart format .`).

### Phase 0 — Unblock (parse error)
Repair the corrupted line 3 of `lib/pages/workout/new_split_page.dart` (reconstruct the broken import statement — `import 'package:tracker/data/repository_scope.dart';` per surrounding imports). Gate: `flutter analyze` passes.

### Phase 1 — Theme bridge (biggest visual win, 1 file)
`lib/main.dart`: set `theme:` / `darkTheme:` to `theme.toApproximateMaterialTheme()` (the Forui-selected `FThemeData`), replacing the bare `ThemeData(brightness: …)`. All remaining Material widgets instantly inherit the Forui palette. Keep the FTheme builder, `themeMode: ThemeMode.system`.

### Phase 2 — Custom widgets on FTheme
- `custom/line_chart.dart`: colors/typography from `context.theme` (`colors.primary`, `colors.mutedForeground`, `typography.bodySmall`); painter logic untouched.
- `custom/custom_route.dart`: push background from `context.theme.colors.background`.
- `custom/custom_app_bar.dart`: keep pinned `SliverAppBar`; swap remaining `Theme.of` reads to `context.theme`; explicit `leading: FButton(.ghost)` back button with `FLucideIcons.arrowLeft` once icons migrate (SliverAppBar's automatic leading is Material-styled).

### Phase 3 — Form controls (leaf pages first)
Order: `exercise_picker_page` → `new_exercise_page` → `split_day_editor_page` → `new_split_page` → `gyms_page` → `graph_editor.dart` → `workout_page.dart` (heaviest, 12× `Theme.of`, 2 dialogs, dropdown, chip).
Replace text fields with `FTextField`, dropdowns with `FSelect`, `FilterChip` with `FCheckbox`/`FSelectGroup`. Preserve all validation logic (`form_validators.dart` reused as-is), controllers, and `Form`/`GlobalKey` flow.

### Phase 4 — Overlays
- All 6 `showDialog`/`AlertDialog` sites → `showFDialog` with `FButton` actions (feed delete-confirm, gyms edit dialog ×2, workout end-dialog ×2, new-split delete-confirm; `graph_editor` body moves into `FDialog` builder).
- 5 `SnackBar` sites → FToaster toasts (new_exercise ×2, gyms ×3).
- `showModalBottomSheet` in `new_split_page` → `showFSheet` (mirror `gym_picker.dart`).
- `PopupMenuButton` ×2 → `FPopoverMenu`.
Keep every `Navigator.pop(context, result)` contract so awaited return values (`pushTo`, dialogs) still work.

### Phase 5 — Structure widgets
- Remaining `Card`/`ListTile`/InkWell rows → `FCard`/`FItemGroup`/`FItem` (session_detail, history_calendar, settings, gyms list, split_day_editor, exercise_picker, gym_picker sheet items, editor_page, feed remnants, exercise_detail + `Divider` → item dividers).
- `SegmentedButton` ×2 → `FTabs` (history list/calendar toggle; exercises browse mode).
- `ExpansionTile` → `FAccordion` (or fallback).
- `SwitchListTile` ×2 → tile + `FSwitch` (settings page).
- Hardcoded colors → theme tokens.

### Phase 6 — Icons
`Icons.*` → `FLucideIcons.*` across 16 files, including `FBottomNavigationBarItem` icons in `home_page.dart` and dialog/sheet icons. Keep `uses-material-design: true` until a final sweep confirms zero `Icons.` uses remain.

### Phase 7 — Tests
- Repoint `settings_test.dart`, `workout_test.dart`, `history_test.dart`, `analytics_test.dart` to `pumpApp()` from `test/helpers/test_helpers.dart` (real `MyApp` = full FTheme stack) instead of bare `MaterialApp` — FTheme/FToaster context required by Forui widgets.
- Update type-based finders to the new widgets: `SwitchListTile` → `FSwitch` (still 2), `TextField` → `FTextField`, `SegmentedButton` → `FTabs`; keep behavioral `find.text` assertions unchanged.
- `app_test.dart` already updated; unit tests unaffected (pure Dart).

### Phase 8 — Cleanup + CI
- Remove unused imports (e.g. the unused forui import in `new_split_page.dart`), run `dart fix --apply` + `dart format .`.
- Full verification (below). No Isar/model/codegen changes, so `build_runner` and generated-file drift checks are untouched.

## Verification

1. `cd tracker && flutter analyze` — clean after every phase (Phase 0 gate).
2. `cd tracker && flutter test` — full suite; `flutter test test/unit` first for fast feedback.
3. Run the app (`cd tracker && flutter run`) and walk all 5 tabs: start a workout from a split day (gym sheet → plan → log sets → warm-up toggle → end dialog), create/edit split + day + exercises, gyms CRUD (dialog + multiplier estimate toast/feedback), settings switches + unit dropdown, feed → progression → graph editor. Check **both brightness modes** (toggle system theme) and touch vs desktop variant.
4. Dialog return-value flows: editor pages returning drafts via `pushTo`, gym picker returning selection, end-workout confirm writing the session.
5. CI workflow (`dart.yml`) green on push.

## Risks / notes

- Forui 0.26 API drift vs docs: confirm `FAccordion`, `FPopoverMenu`, `FToaster`/toast API, `FSelect` form-integration signatures at implementation time; fallbacks listed in the mapping table.
- `FTabs` render may assume tab-content layout — if it fights the history page's toggle, fall back to a `FButton` group or keep `SegmentedButton` (already themed by the approximate Material theme) and mark as acceptable.
- Uncommitted conversion work should be committed first (as its own commit, after Phase 0 repair) so each phase's diff stays reviewable.
- Material icon font stays while any `Icons.` remain; final sweep can drop `uses-material-design` only after full FLucide migration.