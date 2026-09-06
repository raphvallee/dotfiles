# Phase 7 — World map of artist origins

## Context

User wants a world map showing countries, with a point placed at each listened-to artist's **origin** (where they are from — birth/foundation place — not where they currently live). Precision priority: city > state/province > country. Artist info fetched via API must be cached permanently in the browser and must survive the "Clear data" button in the Import menu.

User decisions (explicit, override blueprint defaults):
- Lookups run **automatically when the map page opens** (for uncached artists).
- Controls live on the **Import page** (next to MusicBrainzCard), with a toggle **ON by default** (persisted). This amends the blueprint's "opt-in + off by default" exception wording — record as user-approved in docs.
- Resolve **all** attributed artists, ordered most-played first; map displays points live as they load.

## Verified facts

- Dexie latest schema is `version(3)` (db.ts:43). New table goes in `this.version(4).stores({...})` full-copy block. `clearDataset()` (src/db/db.ts:123) wipes only `streams` + `meta` — new cache table survives automatically; do NOT touch `clearDataset`.
- `src/lib/musicbrainz.ts` exports `sleep()` + `MB_MIN_INTERVAL_MS` (1000) — reuse for pacing.
- Pattern to mirror: `src/state/enrichment.ts` (Zustand, paced loop, batched flush every 5, AbortController, localStorage flag) + `src/components/MusicBrainzCard.tsx` (Import page card).
- Artist list: `topArtists()` in `src/analytics/queries.ts` → `{artist, artistKey, plays}`, plays-desc. Time filter not used here — all-time by definition.
- tsconfig: `resolveJsonModule` on, `verbatimModuleSyntax` (type-only imports), `erasableSyntaxOnly` (no enums). Tests: vitest node env, `src/**/*.test.ts`, fake-indexeddb available.
- MusicBrainz artist search returns `begin_area` (birth/foundation = origin), `country` (ISO alpha-2, nullable), `type`, `id` (MBID). `area` = activity area — explicitly NOT origin. Areas' coordinates unreliable — use geocoder.
- Open-Meteo geocoding (no key): `GET https://geocoding-api.open-meteo.com/v1/search?name=X&count=1&language=en[&countryCode=XX]` → `results[]` (absent = no match) with `name, latitude, longitude, country, country_code, admin1, feature_code` (P* = city, ADM* = division). `countryCode` filter disambiguates using MB's `country`.

## Dependencies

```
bun add d3-geo topojson-client world-atlas
bun add -d @types/d3-geo @types/topojson-client
```
~145 KB raw / ~55 KB gzip. `world-atlas/countries-110m.json` static-imported (features carry ISO 3166-1 **numeric** ids). No react-simple-maps (React 19 peer risk; d3-geo is framework-agnostic).

## Implementation

### 1. Data layer
- `src/db/types.ts`: `export type OriginPrecision = "city" | "subdivision" | "country" | "miss"` + `ArtistOrigin { artistKey (pk), artistName, mbid: string|null, precision, placeName: string|null, subdivisionName: string|null, countryName: string|null, countryCode: string|null, lat: number|null, lng: number|null, resolvedAt: number }`.
- `src/db/db.ts`: `artistOrigins!: EntityTable<ArtistOrigin, "artistKey">`; append `version(4)` full-copy block adding `artistOrigins: "artistKey"`; helpers `putArtistOrigins` / `allArtistOrigins` / `clearArtistOrigins` (mirror mbReleases trio, db.ts:189-200).

### 2. Libs (pure + abortable, musicbrainz.ts style)
- `src/lib/mbArtist.ts`: `MB_ARTIST_ENDPOINT`, `buildArtistQuery(name)` → `artist:"NAME"`, `parseArtistResponse(json)` → `MbArtistHit|null` `{mbid, name, type, country, beginAreaName}` (tolerate absent fields, ignore `area`, validate 2-letter country), `fetchMbArtist(query, signal)` — one retry after 2 s on 503/429.
- `src/lib/geocode.ts`: `GEOCODE_ENDPOINT`, `buildGeocodeUrl(name, countryCode)`, `parseGeocodeResponse(json)` → `GeoHit|null` `{name, latitude, longitude, country, countryCode, admin1, featureCode}`, `classifyPrecision(hit, searchedName)` → subdivision iff `featureCode` starts `ADM` or `admin1` equals searched name (case-insensitive), else city. Unpaced (no rate limit).
- `src/lib/iso.ts`: ~250-entry alpha-2 → `{numeric (world-atlas feature id), name}` literal + `isoCountry(alpha2)`. Serves country-centroid fallback (`geoCentroid`), country display names, exact country shading.

### 3. State — `src/state/origins.ts` (mirror enrichment.ts)
- localStorage flag `"origin-lookup-optin"`, **default true when absent** (`"0"` = off).
- `originTargets(records, cache)`: pure; all music-kind rows with non-empty `artistKey`, aggregate plays per artistKey, plays-desc, drop cached keys. No time filter, no limit.
- `originFromLookups(artist, mb, geo, centroid)`: pure decision matrix (unit-tested):
  - mb null → miss.
  - beginArea + geocode hit → point at lat/lng, precision from `classifyPrecision`.
  - beginArea + geocode miss + country → country centroid via `iso.ts`+`geoCentroid`, precision "country".
  - no beginArea + country → country centroid (no geocode request).
  - neither → miss.
- Store: `cache`, `running`, `progress {done,total}`, `placedCount/missCount`, `error`, `reload()`, `run(signal)`, `clearCache()`. Loop per target (plays-desc order): `fetchMbArtist` in try/finally `sleep(MB_MIN_INTERVAL_MS)`, then `fetchGeocode` (with `countryCode` hint) when beginArea present, `originFromLookups`, push row. Persist batches of 5 + final flush; **update `cache` incrementally per batch** so map fills live. HTTP/network errors: no row written (only clean empty results = permanent "miss"), run aborts, partial kept.
- **Auto-start**: `maybeAutoStart()` called on MapWorldView mount — starts run if toggle ON, dataset loaded, not running, targets > 0. Run is store-level (module AbortController) so it survives page navigation.

### 4. Map — `src/components/charts/WorldMap.tsx`
- Module scope: `feature(topology, objects.countries)` (drop Antarctica `010`), `geoEqualEarth().fitExtent(...)` 960×500, `geoPath`.
- `<svg viewBox="0 0 960 500">` CSS-scaled; country paths fill `#3987e514` when shaded (has ≥1 origin) else `#26262b`, stroke `#0d0d0d`.
- Bubbles: one per resolved **place** (`${placeName}|${countryCode}` aggregation, plays summed — handles dense regions without a clustering lib), `r = 3 + 5*sqrt(plays/maxPlays)`, fill `#3987e5`.
- Tooltip: positioned div, country hover = name + origin count; bubble hover = place, precision chip, artist list (top ~8 + "and k more"), plays.
- Legend: precision chips (City / State or region / Country), bubble-area note, placed/total.

### 5. Pages
- `src/pages/MapWorldView.tsx` + route `/map` + NAV_ITEMS `{ to: "/map", label: "World Map" }` in `src/App.tsx` (after Music). Guards mirror MusicView (loading / no-data states). `maybeAutoStart()` on mount. No time filter — subtitle says "All-time". Renders WorldMap + "Artist origins" table (rank, artist, origin composite, precision chip, country, all-time plays, misses listed) + read-only progress line when running (controls live on Import).
- `src/components/OriginLookupCard.tsx` on Import page (below MusicBrainzCard): ON-by-default toggle (persisted), Run/Cancel, progress `x/y`, placed/miss counts, Clear cache. Toggle ON enables Run + auto-start; OFF disables both. Copy mentions both endpoints (musicbrainz.org + geocoding-api.open-meteo.com).

### 6. Docs + tests
- `docs/BLUEPRINT.md`: amend §0 external-calls row → two user-approved exceptions (Phase 6 MB releases opt-in; Phase 7 artist-origin lookup — **on by default, auto-starts on map open, user-adjustable toggle**, responses cached locally). Add `### Phase 7 - World map of artist origins` to §5 with checklist items; check off with evidence during implementation via `milestone-completion` skill.
- `CLAUDE.md` "must never make external API calls" line → amended to name the two toggled exceptions.
- Tests: `src/lib/mbArtist.test.ts`, `src/lib/geocode.test.ts` (incl. classifyPrecision), `src/lib/iso.test.ts` (BR→076, US→840, GB→826, unknown→null), `src/state/origins.test.ts` (targets: all-time, dedup, plays-desc, cached skipped; full decision matrix), extend `src/db/db.test.ts` (round-trip, upsert, **survives `clearDataset()`**).

## Verification

1. `bun run check && bun run typecheck && bun run test && bun run build` (CI gate).
2. `bun run dev` → Import → Load example → World Map → auto-run starts (toggle ON by default), points appear in batches of ~5, ordered most-played first; Import card shows progress; Cancel preserves partial; re-run resumes from cache.
3. Reload → origins persist. Clear data → dataset wiped, map still renders origins after reload.
4. `bun run build && bun run preview` → `http://localhost:4173/YoutubeAnalytics/map` serves (base-path rule: no runtime-fetched assets added).
5. BLUEPRINT Phase 7 items checked off with evidence (milestone-completion skill).

## Risks

- MB name ambiguity → wrong resolution cached; mitigation: `mbid`+resolvedName stored (future override UI possible), Clear cache escape hatch.
- Groups often lack `begin_area` → many country-precision points; legend sets expectation ("birth/foundation place; groups fall back to country").
- Long tail ≈ 1.5–3k artists → 25–50 min at 1 req/s; cancelable, resumable, live display.
- Geocode without country hint → wrong-city risk; ADM classification caps damage.
