# MVVM + Repository restructure (Flutter app-architecture case study)

## Context

Repo is a cross-platform Flutter workout tracker (`tracker/`, package `tracker`). Layers are tangled: cubits live inside `pages/`, pure analytics logic imports a UI cubit, the app shell has import cycles with two feature pages, and one 5-class file is the whole repository layer. Goal: reorganize `lib/` into the official Flutter case-study layout (hybrid: data/domain by type, ui by feature) with **zero behavior change**.

**User-approved decisions:**

1. Keep `HydratedCubit`s as view models (guide explicitly blesses flutter_bloc) - relocated to `ui/<feature>/view_models/`.
2. Single models: Isar-annotated classes move as-is to `domain/models/` (no DTO/mapper split; `data/model/` deferred - no separate API models exist).
3. `repositories.dart` splits per class into `data/repositories/`.

**Verified facts that shape the work (checked by plan agent):**

- `workout_cubit.dart` analytics import is **live** (`estimateGymExerciseMultipliers`/`estimateGymMultiplier` at lines 415/432) - rewrite it, never drop.
- `weight_format.dart:5` re-export of `settings_cubit.dart` is load-bearing for exactly 2 consumers: `feed_page.dart` (SettingsCubit + GraphConfig) and `feed_page_graph_card.dart` (GraphConfig) - both need explicit imports added.
- `graph_editor.dart` uses no `SettingsCubit` - only GraphMetric/GraphTimeframe/GraphConfig.
- `test_helpers.dart` Isar-lib strings (`test/assets/*.dll/.so/.dylib`) are CWD-relative → moving helpers needs no path edits.
- `.g.dart` parts use bare `part of 'x.dart'` filenames; generated content has no path references; Isar schema IDs derive from class names → parent+part move together, regen is byte-identical.
- `quiver` imported only by `home_page.dart`.
- Only tooling path that breaks: `run-visual-tests.ps1` line 28.

## Target tree

```
lib/
├── main.dart                    # composition root (stays; theme bridge extracted out)
├── routing/
│   ├── tab_navigation.dart      # NEW: TabName, HomePageSingleton, TabVisibilityScope, quiver BiMap
│   └── home_page.dart           # HomePage shell + nested navigators only
├── utils/
│   └── form_validators.dart
├── domain/
│   ├── services/
│   │   └── analytics.dart       # pure analytics engine; settings_cubit dep replaced by graph_config
│   └── models/
│       ├── exercise.dart +.g.dart       gym.dart +.g.dart
│       ├── muscle.dart                  workout_set.dart +.g.dart
│       ├── workout_session.dart +.g.dart        workout_split.dart +.g.dart
│       ├── workout_split_templates.dart
│       ├── graph_config.dart    # NEW: GraphMetric, GraphTimeframe, GraphConfig
│       └── weight_unit.dart     # NEW: WeightUnit, WeightUnitLabel, FreeStartPlacement
├── data/
│   ├── repositories/
│   │   ├── exercise_repository.dart     gym_repository.dart
│   │   ├── workout_split_repository.dart        workout_session_repository.dart
│   │   └── tracker_repository.dart      # facade
│   └── services/
│       ├── db.dart              # Isar instance
│       └── seed.dart
└── ui/
    ├── core/
    │   ├── ui/
    │   │   ├── custom_app_bar.dart      custom_route.dart
    │   │   ├── max_width.dart           line_chart.dart
    │   │   ├── weight_format.dart       repository_scope.dart
    │   └── themes/
    │       └── material_theme_bridge.dart  # NEW: FThemeData.toSdkMaterialTheme() + strengthenNavLabels
    ├── feed/        widgets/feed_page.dart, widgets/feed_page_graph_card.dart
    ├── history/     widgets/history_page, session_detail_page, history_calendar, calendar_grid
    ├── workout/     widgets/workout_page, editor_page, split_day_page, split_day_editor_page,
    │                new_split_page, exercise_picker_page, gym_picker
    │                view_models/workout_cubit.dart
    ├── exercises/   widgets/exercises_page, exercise_detail_page, new_exercise_page
    ├── settings/    widgets/settings_page, gyms_page
    │                view_models/settings_cubit.dart   # slimmed: enums extracted
    └── analytics/   widgets/progression_page, graph_editor
```

`config/` is **not created** - no app constants exist outside widget scope and git can't track empty dirs; create when first config lands. All other user-targeted folders exist.

## File mapping - lib/ (47 files)

Flags: **[move]** git mv only · **[imp]** import rewrites only · **[edit]** substantive edits · **[new]** created.

| Original | Target | Flag |
| --- | --- | --- |
| `lib/models/*.dart` + 5 `.g.dart` (parents + parts, incl. `muscle.dart`, `workout_split_templates.dart`) | `lib/domain/models/` | move; `workout_split_templates.dart` [imp] |
| `lib/analytics/analytics.dart` | `lib/domain/services/analytics.dart` | [imp] settings_cubit → `domain/models/graph_config.dart` |
| - | `lib/domain/models/graph_config.dart` | [new] from settings_cubit |
| - | `lib/domain/models/weight_unit.dart` | [new] from settings_cubit |
| `lib/data/repositories.dart` | 5 files in `lib/data/repositories/` (4 repos + `tracker_repository.dart` facade; original deleted) | [new split] |
| `lib/data/db.dart`, `lib/data/seed.dart` | `lib/data/services/` | [imp] model paths |
| `lib/data/repository_scope.dart` | `lib/ui/core/ui/repository_scope.dart` | [imp] → `tracker_repository.dart` |
| `lib/home_page.dart` | `lib/routing/home_page.dart` | [edit] strip TabName/HomePageSingleton/TabVisibilityScope + quiver; import `tab_navigation.dart` |
| `lib/pages/custom/custom_app_bar.dart`, `custom_route.dart`, `max_width.dart` | `lib/ui/core/ui/` | [move] |
| `lib/pages/custom/line_chart.dart` | `lib/ui/core/ui/line_chart.dart` | [imp] analytics → domain/services |
| `lib/pages/custom/form_validators.dart` | `lib/utils/form_validators.dart` | [move] |
| - | `lib/ui/core/themes/material_theme_bridge.dart` | [new] from main.dart (public `toSdkMaterialTheme()`, `strengthenNavLabels`) |
| `lib/pages/settings/settings_cubit.dart` | `lib/ui/settings/view_models/settings_cubit.dart` | [edit] slim: GraphMetric/GraphTimeframe/GraphConfig/WeightUnit/WeightUnitLabel/FreeStartPlacement out; add graph_config+weight_unit imports; keeps SettingsState/SettingsCubit/maybeOf |
| `lib/pages/settings/weight_format.dart` | `lib/ui/core/ui/weight_format.dart` | [edit] drop re-export; imports → domain/services/analytics, ui/settings/view_models/settings_cubit, domain/models/weight_unit |
| `lib/pages/settings/gyms_page.dart`, `lib/pages/settings_page.dart` | `lib/ui/settings/widgets/` | [imp] |
| `lib/pages/feed_page.dart` | `lib/ui/feed/widgets/feed_page.dart` | [imp] + home_page → `routing/tab_navigation.dart` + **add** settings_cubit import |
| `lib/pages/feed_page_graph_card.dart` | `lib/ui/feed/widgets/feed_page_graph_card.dart` | [imp] + **add** `domain/models/graph_config.dart` import |
| `lib/pages/history_page.dart`, `history/{session_detail,history_calendar,calendar_grid}.dart` | `lib/ui/history/widgets/` | [imp] (calendar_grid [move]) |
| `lib/pages/workout/workout_cubit.dart` | `lib/ui/workout/view_models/workout_cubit.dart` | [imp] analytics → domain/services (**kept**), repositories → tracker_repository, models → domain/models |
| `lib/pages/workout/{workout_page,editor_page,split_day_page,split_day_editor_page,new_split_page,exercise_picker_page,gym_picker}.dart` | `lib/ui/workout/widgets/` | [imp] (gym_picker [move]; same-folder relatives survive) |
| `lib/pages/exercises_page.dart`, `exercises/{exercise_detail_page,new_exercise_page}.dart` | `lib/ui/exercises/widgets/` | [imp]; `exercises_page.dart` `../home_page.dart` → `routing/tab_navigation.dart` |
| `lib/pages/analytics/{progression_page,graph_editor}.dart` | `lib/ui/analytics/widgets/` | [imp]; graph_editor settings_cubit → `domain/models/graph_config.dart` |
| `lib/main.dart` | stays | [edit] imports; theme bridge extracted |

**Import rewrite map (applies to lib+test):** `models/X.dart`→`domain/models/X.dart`; `analytics/analytics.dart`→`domain/services/analytics.dart`; `data/repositories.dart`→per-symbol file (facade-only consumers need only `tracker_repository.dart`); `data/repository_scope.dart`→`ui/core/ui/`; `data/{db,seed}.dart`→`data/services/`; `home_page.dart`→`routing/home_page.dart` (only main.dart; feature pages take `routing/tab_navigation.dart`); `pages/custom/*`→`ui/core/ui/*` except `form_validators.dart`→`utils/`; `pages/settings/*`→`ui/settings/...`; `pages/workout/*`→`ui/workout/...` (cubit → `view_models/`); `pages/{feed_page,feed_page_graph_card}`→`ui/feed/widgets/`; `pages/history*`→`ui/history/widgets/`; `pages/exercises*`→`ui/exercises/widgets/`; `pages/analytics/*`→`ui/analytics/widgets/`.

**Relative-import policy:** rewrite only broken imports; surviving same-folder relatives stay (lint-legal): editor_page→gym_picker/new_split_page/split_day_page, split_day_page→gym_picker, workout_page→gym_picker, new_split_page→split_day_editor_page, history_calendar→calendar_grid/session_detail_page, exercise.dart→muscle.dart, workout_session.dart→workout_set.dart. Full `package:` normalization = optional follow-up, not in scope.

## File mapping - test/ (+ testing/)

New top-level `tracker/testing/` (sibling of `test/`); tests reach it via relative imports (`../../testing/...`) - `package:` URIs can't leave `lib/`, same-package relative imports are legal. Analyzer + husky cover `testing/` (package root). No pubspec change.

| Original | Target | Edits |
| --- | --- | --- |
| `test/helpers/test_helpers.dart` | `testing/test_helpers.dart` | [edit] package imports; InMemoryStorage extracted out; asset strings unchanged |
| `test/helpers/test_fixtures.dart` | `testing/test_fixtures.dart` | [imp] |
| `test/helpers/test_fonts.dart`, `screenshot_helpers.dart` | `testing/` | [move] |
| - | `testing/fakes/in_memory_storage.dart` | [new] extracted verbatim; direct users: workout/settings/layout_overflow/visual_screenshots integration tests + test_helpers |
| `test/unit/analytics_test.dart` | `test/domain/analytics_test.dart` | [imp] graph enums from new domain files |
| `test/unit/workout_templates_test.dart` | `test/domain/workout_templates_test.dart` | [imp] |
| `test/unit/form_validators_test.dart` | `test/utils/form_validators_test.dart` | [imp] |
| `test/unit/workout_test.dart` | `test/ui/workout/workout_cubit_test.dart` | [imp] (renamed; collision with integration move) |
| `test/unit/settings_test.dart` | `test/ui/settings/settings_cubit_test.dart` | [imp] |
| `test/unit/gyms_test.dart` | `test/ui/settings/gyms_test.dart` | [imp] |
| `test/unit/exercises_test.dart` | `test/ui/exercises/exercises_test.dart` | [imp] |
| `test/unit/calendar_test.dart` | `test/ui/history/calendar_test.dart` | [imp] |
| `test/integration/data_test.dart` | `test/data/data_test.dart` | [imp] + helpers path |
| `test/integration/workout_test.dart` | `test/ui/workout/workout_test.dart` | [imp] + helpers + fakes |
| `test/integration/app_test.dart` | `test/app_test.dart` | [imp] + helpers |
| `test/integration/settings_test.dart` | `test/ui/settings/settings_test.dart` | [imp] + helpers + fakes |
| `test/integration/history_test.dart` | `test/ui/history/history_test.dart` | [imp] + helpers |
| `test/integration/analytics_test.dart` | `test/ui/analytics/analytics_test.dart` | [imp] + helpers |
| `test/integration/layout_overflow_test.dart` | `test/ui/layout_overflow_test.dart` | [imp] + helpers + fakes |
| `test/integration/visual_screenshots_test.dart` | `test/ui/visual_screenshots_test.dart` | [imp] + helpers + fakes |

`test/assets/*` (Isar native libs) stays. `run-visual-tests.ps1` line 28 → `flutter test test/ui/visual_screenshots_test.dart`. `CLAUDE.md` path references (`lib/pages/...`, `test/unit`, `test/integration`, `test/helpers`) updated in final commit.

## Execution - 5 commits, each compiles+passes tests

Bottom-up by layer; test file **contents** rewritten in the same commit as the lib moves they depend on (tests import via `package:`); test file **relocations** deferred to commit 5.

1. **Domain**: `git mv lib/models → lib/domain/models` (parents+parts one batch); `git mv analytics → lib/domain/services/`; create `graph_config.dart` + `weight_unit.dart`; slim settings_cubit in place; apply models/analytics/settings_cubit rewrite map lib+test; drop weight_format re-export + add 2 compensating imports; normalize `analysis_options.yaml` exclude to `/lib/**/*.g.dart`. Then `dart run build_runner build --delete-conflicting-outputs` + `git diff --exit-code -- '**/*.g.dart'` (CI-equivalent drift proof) before proceeding.
2. **Data**: create 5 files in `lib/data/repositories/` (delete `repositories.dart`); `git mv db.dart seed.dart → lib/data/services/`; `git mv repository_scope.dart → lib/ui/core/ui/`; rewrite data imports lib+test.
3. **Routing + utils**: create `lib/routing/tab_navigation.dart`; `git mv home_page.dart → lib/routing/` + strip primitives; rewrite feed_page/split_day_page/exercises_page/main.dart; `git mv form_validators.dart → lib/utils/`. Cycles broken here.
4. **UI + theme**: `git mv` all remaining pages into `ui/<feature>/widgets/` + `view_models/` + `ui/core/ui/`; create `material_theme_bridge.dart` from main.dart; rewrite remaining imports lib+test. Mechanical bulk commit.
5. **Tests + tooling + docs**: `git mv test/helpers/* → testing/` + create `testing/fakes/in_memory_storage.dart`; relocate 16 test files per table; rewrite helper relative imports; update `run-visual-tests.ps1`; update `CLAUDE.md`.

Windows mechanics: `git mv` (no case-only renames exist → NTFS safe; preserves history; `.gitattributes` eol rules hold). Pre-run `dart fix --apply && dart format .` on touched files before staging so husky pre-commit becomes a no-op (no reformat noise).

## Verification

1. `cd tracker && flutter analyze` - 0 issues (unused_import warnings are fatal → stale-import safety net).
2. `dart run build_runner build --delete-conflicting-outputs` + `git diff --exit-code -- '**/*.g.dart'` - no drift.
3. `flutter test` - all green (Isar tests prove native libs still load; hydration round-trips prove storage intact).
4. Stale-import greps - 0 hits: `package:tracker/(models|analytics)/`, `package:tracker/pages/`, `package:tracker/data/(repositories\.dart|repository_scope|db|seed)`, `package:tracker/home_page`, `helpers/` in test/, `export 'settings_cubit` in lib/.
5. `pwsh run-visual-tests.ps1` - sweep passes at new path; spot-check PNGs (behavior-preserving → pixel-equivalent expected).
6. Layer sanity: domain imports nothing from data/ui; data imports only domain+isar; ui imports domain/data; no cycles (grep home_page/feed/exercises mutual imports).

## Risks / mitigations

- **Part breakage**: parts move with parents; bare `part of` verified; commit-1 drift check gates.
- **Hydration**: storage keys from `runtimeType` (class names unchanged); JSON payload enums unchanged → existing persisted state loads.
- **Isar schema**: schema IDs from class/property names, not paths → existing DBs unaffected.
- **Re-export removal**: exactly 2 affected consumers identified; analyzer catches stragglers.
- **Live-import trap**: workout_cubit analytics import rewritten, never dropped.
