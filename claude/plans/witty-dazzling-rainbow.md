# Flutter UI/UX Performance Optimization Plan

## Context

Tracker has solid functional coverage, but several screens do full-history work during build. Unbounded Isar watchers, eager `Column` rendering, repeated analytics scans, broad workout rebuilds, and calendar map reconstruction will degrade startup, scrolling, memory, and frame times as workout history grows. UX quality also lacks tested semantics, text scaling, theme contrast, and performance budgets.

Goal: make common flows fast and stable at realistic history sizes while preserving persisted data, hydration compatibility, navigation-stack state, workout semantics, and existing loading/error/empty behavior. No Isar schema migration needed.

## Recommended approach

### 1. Establish measurable baselines and fixtures

Add deterministic large-history fixtures and lightweight instrumentation for startup, query duration, analytics duration, rebuild counts, and profile-mode scrolling/logging. Define budgets for first frame, build/raster p95, and analytics latency before changing behavior. Keep instrumentation out of release behavior.

Representative tests and utilities live under `tracker/test/`; reuse existing persistence, widget, analytics, and calendar fixtures.

### 2. Add purpose-specific repository queries

Modify `tracker/lib/data/repositories.dart` and repository tests to add:

- Ordered, bounded recent-session stream/query for Feed’s five activities.
- Ordered history access supporting paging or date-range loading.
- Date/month-oriented session access for calendar work.
- Explicit ordering in repository results so pages never copy and sort full collections.

Migrate `tracker/lib/pages/feed_page.dart` first, then History. Retain `watchAll()` during migration for compatibility; remove only after all production callers move. Preserve watcher insert/update/delete and empty-database behavior. Do not expose raw Isar queries to pages.

### 3. Virtualize large UI collections

Replace eager parent `Column` trees with sliver builders and stable keys:

- `tracker/lib/pages/feed_page.dart`: bounded recent stream, no full-list sort, lazy activity items.
- `tracker/lib/pages/history_page.dart`: lazy history list; calendar mode built separately.
- `tracker/lib/pages/workout/workout_page.dart`: lazy split/day sections where collections grow.
- `tracker/lib/pages/exercises_page.dart`: precomputed group descriptors and lazy grouped items.

Preserve `pushTo`, ordering, editor navigation, expansion/reorder behavior, and loading/error/empty states. Avoid nested independently scrolling lists inside existing `CustomScrollView`s.

### 4. Cache calendar derived data

Refactor `tracker/lib/pages/history/history_calendar.dart` and, where useful, `tracker/lib/pages/history/calendar_grid.dart` so session grouping happens once per session-input revision, not once per calendar cell. Maintain an immutable normalized date index and use O(1) day lookup. Recompute month metrics and streak only when sessions or selected month changes. Keep local date-only normalization explicit.

Add tests for repeated builds, multiple sessions/day, month transitions, empty days, timezone boundaries, streak gaps, and selected-day navigation.

### 5. Isolate Current Workout rebuilds

Refactor `tracker/lib/pages/workout/current_workout_page.dart` around narrow `BlocSelector`/`buildWhen` widgets:

- Idle/in-progress shell.
- Header totals.
- One selector per plan exercise card.
- End-workout action.
- Free-form set list.

Avoid each card scanning all `state.sets`; use a presentation index or memoized grouping rebuilt once per state transition. Keep `WorkoutState.toJson`/`fromJson` format unchanged and preserve set order, warm-up flags, removal, free-form logging, end persistence, and hydration restart behavior. Use stable exercise keys. Add rebuild-count coverage proving unrelated cards do not rebuild.

Relevant state code: `tracker/lib/pages/workout/workout_cubit.dart`.

### 6. Move analytics out of widget build

Keep pure correctness functions in `tracker/lib/analytics/analytics.dart`. Add an immutable memoized analytics snapshot/service, keyed by session content/revision, gym multiplier revision, and optional exercise filter. Share normalized working-set intermediates across summary, volume, and 1RM metrics.

Update `tracker/lib/pages/analytics/progression_page.dart` and `tracker/lib/pages/exercises/exercise_detail_page.dart` to compute on load/stream changes and render cached results, not rescan during every build. Invalidate on session or gym changes. Use an isolate only if profiling proves main-isolate work causes frame drops.

Test snapshot output against existing pure functions, warm-up exclusion, gym normalization, empty data, filtering, ordering, and invalidation.

### 7. Control visited-tab watcher lifetime

`tracker/lib/home_page.dart` correctly lazy-mounts unvisited tabs, but `Offstage` retains visited pages and their watchers. Add an explicit active/inactive visibility contract that lets Feed, History, Workout, and Exercises pause/cancel subscriptions while inactive and resume without losing navigator stacks. Do not rely on `Offstage` or `TickerMode` alone.

Test initial mount, subscription start/stop, inactive database writes, return behavior, stack preservation, and active workout state preservation. Keep this phase separate from list virtualization so regressions stay isolated.

### 8. Defer first-run exercise seeding

Refactor `tracker/lib/main.dart` and `tracker/lib/data/seed.dart` so app shell/repository become available before optional seed writes. Schedule idempotent seed work after first frame or idle priority, expose seed-pending state if needed to avoid a false empty-library message, and make failure observable/retryable. Preserve transaction safety and watcher updates.

Test first frame timing, first-run seed completion, repeat startup, and seed failure/retry.

### 9. Add UX and performance gates

Extend `.github/workflows/dart.yml` while keeping analyze, generated-code drift, and tests:

- Golden tests for Feed, History list/calendar, Current Workout, light/dark themes, narrow width, and large text scale.
- `SemanticsTester` coverage for navigation destinations, calendar days, actions, delete controls, and loading/error/empty states.
- Explicitly restore meaningful navigation tooltips instead of `tooltip: ''` in `tracker/lib/home_page.dart` and verify tap targets/labels.
- Stable widget/unit gates for repository bounds, calendar index, selectors, analytics cache, and deferred seed.
- Manual/nightly profile workflow with deterministic large data, startup/scroll/workout traces, frame build/raster timing, and checked-in thresholds.
- Release/profile smoke build where runner toolchains support it.

Keep device-dependent profile checks out of ordinary PR gates if runner variance makes them flaky.

## Execution order

1. Baselines and fixtures.
2. Repository query contracts.
3. Calendar index cache.
4. Feed and History lazy rendering.
5. Workout and Exercises lazy rendering.
6. Current Workout selector isolation.
7. Analytics snapshot/cache.
8. Tab watcher lifecycle.
9. Deferred seed startup.
10. Golden, semantics, and profile CI gates.

Each phase ships with focused tests before next phase. Run from `tracker/`: `flutter pub get`, `flutter analyze`, `dart run build_runner build --delete-conflicting-outputs` only if annotations change, `flutter test`, then profile/integration checks for relevant phases. Generated `.g.dart` files remain untouched unless generator requires regeneration.

## Critical files

- `tracker/lib/data/repositories.dart`
- `tracker/lib/pages/feed_page.dart`
- `tracker/lib/pages/history_page.dart`
- `tracker/lib/pages/history/history_calendar.dart`
- `tracker/lib/pages/workout/workout_page.dart`
- `tracker/lib/pages/exercises_page.dart`
- `tracker/lib/pages/workout/current_workout_page.dart`
- `tracker/lib/pages/workout/workout_cubit.dart`
- `tracker/lib/analytics/analytics.dart`
- `tracker/lib/pages/analytics/progression_page.dart`
- `tracker/lib/pages/exercises/exercise_detail_page.dart`
- `tracker/lib/home_page.dart`
- `tracker/lib/main.dart`
- `tracker/lib/data/seed.dart`
- `.github/workflows/dart.yml`
