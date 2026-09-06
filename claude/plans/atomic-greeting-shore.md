# Context

Milestones 5-8 remain unfinished in `RefinementPlan.md`. They span calendar layout, shared validation across existing forms, an additive/time-aware gym multiplier model, and hydrated user-defined Feed graphs. Current code already has reusable seams: pure calendar math in `lib/pages/history/calendar_grid.dart`, `LineChart` and `AnalyticsService`, injected repositories, and `SettingsCubit` hydration. Implementation must proceed in dependency order so M8 consumes final M7 analytics behavior, while preserving existing data and generated-code CI checks.

# Plan

## 1. M6 — shared validation foundation

- Add pure validators in `tracker/lib/pages/custom/form_validators.dart` with exact messages `Cannot be empty` and `Must be greater than 0`.
- Apply them to split title/day title, gym name and positive multiplier, current-workout weight/reps, and the existing exercise form. Keep exercise-picker search unvalidated.
- Replace silent fallbacks/snackbar-only validation with inline errors and disabled Save/Add actions where appropriate.
- Change split/day/exercise/gym descriptions to multiline auto-growing fields (`minLines: 1`, `maxLines: null`, multiline keyboard).
- Add unit tests for validator branches and focused widget tests proving invalid values do not save/log and errors render.

## 2. M5 — compact history calendar

- Preserve `CalendarGrid`, `WorkoutDateIndex`, and streak math contracts.
- Compact day cells, labels, dots, gaps, and metrics strip in `tracker/lib/pages/history/history_calendar.dart`.
- Replace plain selected-day `Column` with a finite-height, internally scrolling workout panel so grid remains visible; retain empty states and `SessionDetailPage` navigation.
- Add HistoryCalendar widget coverage for marked days, selected long lists, bounded internal scrolling, and no layout exceptions.

## 3. M7 — additive multiplier model and analytics

- Extend `tracker/lib/models/gym.dart` with optional per-exercise overrides while retaining global `multiplier` and primary-gym baseline behavior. Verify Isar supports chosen representation; use an embedded/list representation if integer-keyed maps are unsupported.
- Regenerate `gym.g.dart` with `dart run build_runner build --delete-conflicting-outputs`; run generated drift checks and an old-record/default compatibility test. Never hand-edit generated files.
- Centralize multiplier resolution in `tracker/lib/analytics/analytics.dart`: exact exercise override, movement/equipment fallback, global gym fallback, then `1.0`.
- Evolve normalization and all series/summary consumers to use the final multiplier profile; include all profile inputs in analytics cache fingerprints.
- Implement deterministic time-decayed, warm-up-excluding estimation with robust median aggregation, shared-exercise estimates first and movement fallback when exercise data is absent. Require exercise metadata explicitly rather than guessing from sessions.
- Update Gyms UI, Progression, Exercise Detail, and `WorkoutCubit.endWorkout` to use the new APIs. Persist completed session before any automatic estimate update; never rewrite primary baseline.
- Add pure tests for precedence, decay/recent weighting, median/outlier behavior, movement fallback, insufficient data, and warm-up exclusion; add Isar round-trip and end-workout integration coverage.

## 4. M8 — hydrated Feed graphs

- Add serializable `GraphConfig` plus metric/timeframe enums under `tracker/lib/models/` or settings. Use enum names in JSON, stable IDs/order, defensive immutable lists, and tolerant malformed-entry parsing.
- Extend `SettingsState`/`SettingsCubit` with graph hydration and add/update/remove operations. Missing or malformed graph data must not break legacy settings hydration.
- Add analytics series selection/timeframe filtering, including exercise-filtered volume, using final M7 multiplier resolution. Expand cache keys for metric, timeframe, exercise, sessions, and complete multiplier profile.
- Extend Feed to load complete sessions, gyms, and exercises through repository seams; retain Recent activity, workout shortcut, and Progression. Add Analytics section, Add graph flow, validated edit form, chart cards using existing `LineChart`, and edit/delete actions.
- Handle no repository, empty data, deleted/unknown exercises, and empty series without crashes.
- Add settings serialization/CRUD tests, analytics metric/timeframe tests, and Feed widget tests for empty/render/add/edit/delete flows.

## 5. Checklist and final gates

- Before each stage, read its `RefinementPlan.md` checklist; after implementation, mark only verified items `[x]` and record blocked items accurately.
- After every stage run `dart format`, `flutter analyze`, focused tests, and nearest integration tests.
- Final run: `dart run build_runner build --delete-conflicting-outputs`, generated-file drift check, `flutter analyze`, all unit tests, then all integration tests. Distinguish any pre-existing native Isar binary mismatch from regressions.
- Stop after all four milestones’ acceptance criteria and checklist entries are verified; do not add unrelated polish.
