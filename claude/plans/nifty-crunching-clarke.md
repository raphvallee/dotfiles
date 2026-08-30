# Visual UI debugging: widget-test screenshot workflow

## Context

The user wants Claude Code to *see* the app's UI during test runs — CLI text output misses overflows, misalignment, tofu glyphs, and broken layouts. Current state: `tracker/test/integration/layout_overflow_test.dart` (untracked WIP, 465 lines) already sweeps 16 pages + dialogs at 3 window sizes with real Isar data and the Inter font, but overflow detection is passive (exception fails the test; only a `SWEEP:` print names the page) and **no image capture exists anywhere in the repo**.

**Decision — no new packages.** `flutter_test` (already present) + a hand-rolled `RepaintBoundary → toImage → PNG` capture helper. Rationale:
- `integration_test`'s `takeScreenshot` driver plumbing targets Android/iOS `flutter drive`; on desktop it buys nothing we don't already have (widget tests render real Skia rasters) and adds runner-build + headless-CI friction.
- `golden_toolkit` is unmaintained and comparison-oriented; these are *inspection* images, not baseline goldens (comparison mode rejected for now: golden pixel-diff is notoriously platform-flaky Windows vs Linux).
- Output dir: `tracker/build/test_screenshots/` — already gitignored (unanchored `build/` in root + `/build/` in tracker), deterministic, user-suggested.

## Files to create / modify

### 1. NEW `tracker/test/helpers/test_fonts.dart`
Shared idempotent font loader (extract + extend `layout_overflow_test.dart:64-110`):
- `Future<void> loadTestFonts()` — single-flight via `Future<void>? _pending`; **must be called inside `tester.runAsync`** (engine font loading is real async).
- Keep the existing pub-cache resolution (`PUB_CACHE` / `%LOCALAPPDATA%\Pub\Cache` / `~/.pub-cache`) and the Inter loading (`FontLoader('packages/forui/Inter')`, `Inter.ttf` + `Inter-Italic.ttf` from `forui-<ver>/assets/fonts/inter/`) verbatim.
- ADD: forui_lucide icon font from `forui_lucide-<ver>/assets/lucide.ttf`, registered under **both** family names — `ForuiLucideIcons` (what `IconData` requests; verified in `forui_lucide-0.26.1/lib/src/assets.g.dart:3204`) and `packages/forui_lucide/ForuiLucideIcons` (what FontManifest registers) — covers either resolution path.
- ADD: MaterialIcons from the Flutter SDK (`bin/cache/artifacts/material_fonts/materialicons-regular.otf`), resolved via `Platform.environment['FLUTTER_ROOT']`, else climbing from `Platform.resolvedExecutable` until an `artifacts` dir. App code uses no `Icons.*`, but Material widgets inject icons internally (ReorderableListView drag handles in SplitDayEditorPage, ExpansionTile chevrons).
- Every load individually guarded: missing file → `print('FONTS: ...')` + continue, never throw (degrades to wide test font / tofu, test still passes).

### 2. NEW `tracker/test/helpers/test_fixtures.dart`
Extract `_Fixtures` class + `_seed` from `layout_overflow_test.dart:338-465` **bodies unchanged**, renamed `SweepFixtures` / `seedSweepFixtures(TrackerRepository repo)`. Pure repository logic, zero widget coupling — extraction prevents drift between the two sweeps.

### 3. NEW `tracker/test/helpers/screenshot_helpers.dart`
- `final GlobalKey screenshotBoundaryKey` — the sweep wraps the pumped app in `RepaintBoundary(key: screenshotBoundaryKey, child: const MyApp())` **above MaterialApp** so captures include dialogs, sheets, toasts, bottom bar.
- `Directory screenshotDir()` — walk up from `Directory.current` (max 3 levels) to the dir containing `pubspec.yaml`, join `build/test_screenshots`, create recursively. Do **not** use `Platform.script` (under flutter test it points at the test-runner bootstrap kernel).
- `class ScreenshotRecorder { ScreenshotRecorder(this.tester); void beginRun({required String sizeLabel}); Future<void> capture(String label, {bool fail = false}); Future<void> captureFailure(String label); }`
  - Naming: `NNN_<sanitized-label>@<W>x<H>.png` — counter zero-padded to 3, resets per `beginRun`; sanitizer lowercases + collapses non-`[a-z0-9]` runs to `-`. Fail captures insert `_FAIL` before `@`. The `@WxH` suffix makes names collision-proof across size runs and deterministic across runs (no timestamps). Example: `003_history-calendar@800x600.png`.
  - Mechanics: build name → inside `tester.runAsync`: `screenshotBoundaryKey.currentContext.findRenderObject()` (must be `RenderRepaintBoundary`, else print `SCREENSHOT-SKIP`) → `boundary.toImage()` (dpr is 1.0, so pixel-exact WxH) → `toByteData(png)` → `File.writeAsBytes(flush: true)` → `image.dispose()` in `finally`. **All IO/encoding inside `runAsync`** (real IO never completes in the fake-async zone; PNG encoding there is unproven).
  - After each capture: `print('SCREENSHOT: <abs path>')`, record entry, rewrite `manifest.json` in full (`JsonEncoder.withIndent`; entries: file, label, size, width, height, fail). Rewriting per capture = crash-safe manifest even if a later size run dies. Print `MANIFEST: <path>` once per run.
  - `captureFailure` wraps `capture(fail: true)` in try/catch, prints on error — a broken tree must not cause a second failure.

### 4. NEW `tracker/test/integration/visual_screenshots_test.dart`
Capture sweep. Scaffolding copied from `layout_overflow_test.dart` (proven): same `_sizes` table, `debugDefaultTargetPlatformOverride = windows` (+ restore + `pump(5s)` tail for hydration-debounce timers), real Isar opened+seeded inside `runAsync` (name `'isar_visual_$label'`, no `isar.close()` teardown — native close never completes in fake async), `InMemoryStorage`, plan workout started with 2 logged sets + `SettingsCubit.addGraph(...)`, same 2-round `runAsync(150ms)` + `pump` settle (no `pumpAndSettle` — loading spinners animate forever under fake time). Deltas:
- Pump `MultiBlocProvider(..., child: RepaintBoundary(key: screenshotBoundaryKey, child: const MyApp()))` with `RepositoryScope`.
- **Hardened settle**: track `var current = '<page label>'`; after each settle, `tester.takeException()` (frame exceptions land in the binding's pending slot and do **not** throw in-body — `takeException` retrieves + clears them mid-body; polling also prevents the "Multiple exceptions" dump). On non-null: add `'[<label>] <exception>'` to `failures`, `recorder.captureFailure(current)`. At end: `if (failures.isNotEmpty) fail(...)`. (Chosen over a `FlutterError.onError` wrapper: onError fires mid-frame where rasterizing is unsafe; takeException after settle runs in a clean body context with the page label known.) Hard failures from `expect`/`tap` DO throw in-body → each state helper wraps in try/catch → `captureFailure` → rethrow.
- Sweep (~21 states per size, ≈63 PNGs total):
  1. **Tabs** (real shell incl. bottom bar) — switch via `tester.widget<FBottomNavigationBar>(find.byType(FBottomNavigationBar)).onChange!(index)` (the pattern proven in `app_test.dart:50-62`; hit-testing is brittle under Offstage navigators per its comment). Capture: Feed, History list → tap `find.text('Calendar')` → capture in place, Workout (in progress), Editor, Exercises. Return to Feed (index 0) before dialogs.
  2. **Pushed pages** (same widgets/args as layout test — root-navigator push, capture between settle and pop): Settings, Gyms, Progression, NewExercise, ExerciseDetail, SessionDetail, SplitEditor (new), SplitEditor (edit), SplitDayEditor, SplitDay, ExercisePicker. (No pushed WorkoutPage — the tab already shows it.)
  3. **Dialogs/sheets** via Feed tab context (same builders as layout test): GraphEditor dialog, EditGymDialog, Gym picker sheet — capture between open and pop.
  4. **End-workout dialog** last: push WorkoutPage → `ensureVisible`/tap `'End Workout'` → capture dialog → tap `'Keep going'` → `runAsync(cubit.endWorkout)`.
- Fonts: `await tester.runAsync(loadTestFonts)` at top of each test.
- Doubles as a hardened overflow sweep: runs on ubuntu CI via bare `flutter test` (Linux pub-cache + `libisar_linux_x64.so` paths already handled).

### 5. EDIT `tracker/test/integration/layout_overflow_test.dart` (minimal churn, behavior-identical)
- Delete font loader (lines 64-110) + call site → `await tester.runAsync(loadTestFonts);` + import.
- Delete `_Fixtures`/`_seed` (lines 338-465) → `seedSweepFixtures`/`SweepFixtures` via import.
- Drop now-unused imports (`dart:io`, `flutter/services.dart`) — verify with `flutter analyze` (CI enforces).
Everything else stays exactly as the user wrote it. (Fallback if user prefers zero churn on their WIP file: duplicate the seed into the fixtures file and leave layout_overflow_test untouched — decide at implementation start.)

### 6. NEW `run-visual-tests.ps1` (repo root, PowerShell 7)
Params: `[switch]$NoClean`. Default: delete `tracker/build/test_screenshots`; run `flutter test test/integration/visual_screenshots_test.dart` from `tracker/` (Push-Location/Pop-Location); capture `$LASTEXITCODE`; then list every PNG absolute path (sorted) + manifest path; exit with flutter's code (the automation loop depends on passthrough). Non-zero exit message points at `*_FAIL*.png`. No `.sh` twin (user is Windows-only; pwsh 7 itself is cross-platform if ever needed; CI runs bare `flutter test`).

### 7. EDIT `CLAUDE.md`
Append section (after "Running GitHub Actions locally") — the vision-analysis loop, so future sessions know it exists:
> - `pwsh run-visual-tests.ps1` renders every app page/dialog at 320×568 / 800×600 / 1280×720 with real Inter text + Lucide/Material icon fonts, writing ~60 PNGs + `manifest.json` to `tracker/build/test_screenshots/` (gitignored). Exit code = test result.
> - Loop after UI changes: run script → read `manifest.json` / glob `*.png` → inspect images (Read tool renders them) for overflow / clipped text / misalignment / tofu glyphs → fix → re-run. `_FAIL`-suffixed files are auto-captures of the screen that threw a render exception.
> - Under the hood: `test/integration/visual_screenshots_test.dart`, `test/helpers/screenshot_helpers.dart`, `test/helpers/test_fonts.dart`. Works on Linux CI too; output dir is disposable.

## Fake-async caveats (embed as comments in helpers/test)

1. All capture IO + font loading + Isar seeding inside `tester.runAsync`.
2. Never `pumpAndSettle` (forever-animating spinners) — 2-round `runAsync(150ms)` + `pump` settle.
3. Capture strictly between settle and pop (after pop the boundary shows the base page).
4. Frame exceptions don't throw in-body — `takeException()` after every settle; accumulate + `fail()` at end.
5. `image.dispose()` after encoding (leak-tracker hygiene).
6. Tail `pump(Duration(seconds: 5))` + `debugDefaultTargetPlatformOverride = null` before teardowns.
7. Never `isar.close()` in teardown.
8. Known flake: 2 settle rounds may catch a 300ms page transition mid-flight (layout test lives with it); if verification shows mid-transition captures, bump the visual test's settle to 3 rounds.

## Out of scope (unless requested)

CI artifact upload of `tracker/build/test_screenshots` on failure (`actions/upload-artifact@v4`, `if: failure()` in `dart.yml`) — trivial to add later; core need is Windows-local. Baseline golden comparison.

## Verification

1. `cd tracker && flutter analyze` — clean (catches unused-import fallout in edit #5).
2. `pwsh run-visual-tests.ps1` → exit 0, ~63 PNG paths printed, counter sequence + `@WxH` suffixes sane.
3. **Tofu check with vision** (Read tool on PNGs): feed tab shows real house/history/dumbbell nav icons (verifies dual lucide family registration), Inter text metrics on settings/exercise pages, ReorderableListView handle on SplitDayEditorPage (MaterialIcons). A tofu verdict → adjust family name / SDK font path.
4. **Failure-path proof**: scratch-edit an unconstrained long-text `Row` into a visited page, re-run → `<NNN>_<page>_FAIL@*.png` exists, failure message carries page label, script exits non-zero. Revert.
5. `flutter test` full suite green on Windows; run `layout_overflow_test.dart` once (still behaves); `git status` shows no `build/test_screenshots` entries (gitignore working).
6. Linux parity verified by CI on next push (font/SDK paths are the Linux-relevant code).
