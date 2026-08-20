# Milestone 6 - Analytics, multipliers & progression

## Context

M5 shipped history + calendar. M6 is the analytics layer (Todo.md "Milestone 6 - Analytics, multipliers & progression", Plan.md §1.4.1.1, §2.3, §2.4, §2.1): per-exercise historical stats/graphs, machine weight-equivalence multipliers, normalized progression, and general strength/volume graphing - with warm-up sets excluded everywhere.

Exploration found two gaps that gate the milestone:
- **No gyms exist anywhere** - no `Gym()` constructor use outside the model, no gym-management UI, none seeded. Multiplier normalization (§2.3) has no data source. So M6 must add a **Gyms management page** (create/edit gyms, set primary, edit or auto-estimate multiplier). `Gym.multiplier` already exists in the schema - no codegen needed.
- **No charting dependency** in `pubspec.yaml`. Rather than add `fl_chart` (extra weight + risks the existing jni build fragility), build a lightweight `CustomPainter` line chart.

Decisions from user: **Gyms page only, no default seed**; general **Progression page reachable from Feed (tab 0)**.

Design principle: keep all analytics **pure** (operate on `List<WorkoutSession>` + a `Map<int,double> gymMultipliers`, no Isar/widgets) so it is unit-testable without a DB - same pattern as `calendar_grid.dart` in M5, which avoids the documented `testWidgets` FakeAsync + real-Isar limitation.

## Normalization model (§2.3)

A `WorkoutSession` carries `gymId`; a `Gym` carries `multiplier`. Define:
`normalizedWeight(raw, multipliers, gymId) = raw * (multipliers[gymId] ?? 1.0)`
- Primary gym = baseline, multiplier locked to **1.0**.
- Secondary gym multiplier = weight-increment required to align it to the primary gym. To estimate from logs, for each exercise shared between a secondary gym and the primary gym: `ratio = meanRawWeight(primary, ex) / meanRawWeight(secondary, ex)`, then take the **median** across shared exercises → estimated multiplier. Manual override stored on `Gym.multiplier`. (Ratio-of-means is a pragmatic stand-in for full trendline regression; sufficient to satisfy the checkpoint with sparse data.)

## Warm-up exclusion (§2.1)

Every stat/series excludes `SetType.warmup` sets (100% of 1RM, volume, peaks).

## 1RM estimate

Epley: `reps <= 1 ? weight : weight * (1 + reps / 30)`, computed on normalized working-sets.

## Files

**NEW `lib/analytics/analytics.dart`** - pure, DB-free analytics layer:
- `double normalizedWeight(double raw, Map<int,double> multipliers, int? gymId)`
- `double epley1rm({required double weight, required int reps})`
- `class ProgressionPoint { DateTime date; double value; }`
- `class ExerciseSummary { best1rm, peakVolume, sessionCount }`
- Per-exercise series: `exerciseBest1rm(sessions, multipliers, exerciseId)`, `exercisePeakWeight(...)` - one point per session (best normalized working value), sorted by date.
- Overall: `volumeTrend(sessions, multipliers)` (per-session normalized working volume), `overallBest1rm(...)`, `overallSummary(...)`.
- `double? estimateGymMultiplier(List<WorkoutSession> sessions, int? primaryGymId, int gymId)` - median ratio across shared exercises; null if none.

**NEW `lib/pages/custom/line_chart.dart`** - lightweight `CustomPainter` line chart from `List<ProgressionPoint>`: polyline + point dots, single min/max y labels, "No data" empty state. No external dependency.

**MODIFY `lib/pages/exercises/exercise_detail_page.dart`** - convert to a `StatefulWidget`; load `repo.sessions.getAll()` + `repo.gyms.getAll()` in `didChangeDependencies` (guarded, `RepositoryScope.maybeOf` → empty in tests). Replace the "Milestone 6" placeholder with a **Performance history** section: summary stats (best 1RM, peak volume, session count) + a `LineChart` of `exerciseBest1rm` (normalized) over time. Existing profile rows unchanged.

**NEW `lib/pages/analytics/progression_page.dart`** - loads sessions + gyms in `didChangeDependencies`. Renders overall summary (total workouts, best normalized 1RM, peak volume, total volume) + `LineChart`s of `volumeTrend` and `overallBest1rm`.

**MODIFY `lib/pages/feed_page.dart`** - add an "Analytics / Progression" card/button that `pushTo(ProgressionPage)` (Feed is currently a bare shell; still the designated analytics home).

**NEW `lib/pages/settings/gyms_page.dart`** - gym CRUD + multipliers:
- List gyms (`repo.gyms.watchAll()`), primary badge, multiplier shown.
- Add/edit gym dialog (name, description, multiplier). Primary gym multiplier locked to display 1.0.
- Set-primary toggle; making a gym primary unsets others.
- Per-gym "auto-estimate" button → `estimateGymMultiplier` from sessions, applies result when data exists.
- Uses `CustomAppBar` + `didChangeDependencies` load + `pushTo` conventions from M4/M5.

**MODIFY `lib/pages/settings_page.dart`** - add a "Gyms" settings card (`Icons.fitbit`/gym icon) → `pushTo(GymsPage)`. Other snackbar placeholders stay (M7).

**NEW `test/milestone6_test.dart`** - pure unit tests: Epley math, normalization with two multipliers, per-exercise series excludes warmups + normalizes across gyms (the checkpoint: same movement on two gyms with different multipliers → unified normalized chart values), volume-trend excludes warmups, `estimateGymMultiplier` median-of-ratios. Plus a DB-free `LineChart` widget build test.

**MODIFY `Todo.md` + `CLAUDE.md`** - check M6 box + "Note (Milestone 6)" block; update CLAUDE.md architecture (analytics layer, Gyms page, chart widget).

## Out of scope / noted

- Full trendline regression for §2.3 auto-estimation → substituted with median-of-ratio estimator (documented).
- Feed activity-stream content, full Settings polish → M7.
- No new dependency; native chart via CustomPainter.

## Verification

1. `cd tracker && flutter analyze` → "No issues found!"
2. `cd tracker && flutter test` → all existing (20) + new M6 tests pass.
3. M6 unit tests directly assert Checkpoint 6: a session at gym B (multiplier 0.9, raw 110) and one at gym A (multiplier 1.0, raw 100) of the same exercise produce chart values 100/99 (normalized); warmup-only sets contribute nothing to 1RM/volume.
4. Manual: create two gyms in Settings→Gyms, log the same exercise at both, verify ExerciseDetailPage chart shows normalized (not raw) values, and Progression page (Feed) shows overall charts.
