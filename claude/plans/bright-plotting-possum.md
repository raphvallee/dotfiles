# Strengthen the GGUF→HF tokenizer resolver

## Context

The resolver (`internal/hf/hf.go`, uncommitted new package) maps a local GGUF to the HF repo that owns its tokenizer, which lm-eval needs (`tokenizer=Org/Repo` in `--model_args`). It is too weak for derivative uploads: `Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M` must resolve to `Qwen/Qwen3.6-35B-A3B`, but today only ONE trailing quant token is stripped (`-Q4_K_M`), leaving `Uncensored-HauhauCS-Aggressive` in the search query, and the search falls back to an arbitrary `list[0]` candidate that gets cached forever.

Decisions made with user:
- Unverified search fallback allowed, but cached with `source='guess'` and flagged in log/CLI.
- New tool-managed `tokenizers.yaml` (next to config.yaml, exe dir): `entries: <model>: {tokenizer, source}`. Resolver priority: **config `hf_models` → tokenizers.yaml → sqlite `hf_map` → GGUF metadata → HF search (verified) → guess**. Manual command writes the yaml file.
- Console commands `models tokenizer <model> <org/repo>` (pin) and `models tokenizer --clear <model>` (removes yaml entry AND sqlite row).

## Changes

### 1. `internal/gguf/gguf.go` — more signals

Add to `Info` (mirroring `FileType/FileTypeKnown` style):
- `TokenizerModel string` — `tokenizer.ggml.model` (string switch, gguf.go:110-131). Parsed, currently inert.
- `TokensCount uint64` + `TokensCountKnown bool` — `tokenizer.ggml.tokens_count` (int switch gguf.go:132-142 already matches types 4/5/10/11).
- Change `skipArray()` to return `(count uint64, err)`; on key `tokenizer.ggml.tokens`, use array length as `TokensCount` fallback (older GGUFs lack the scalar). Arrays still skipped.

### 2. `internal/hf/names.go` (new) — pure name logic + table tests

- `baseName(info, name)`: `info.Basename` if set; else strip `info.Finetune` suffix (case-insensitive, `-` or `_` separator); else name.
- `stripQuant(name, seps)`: loop dropping trailing sep-delimited segments while `isJunkSegment`. Split on `-` only for the primary rung (keeps `Q4_K_M` one unit); one fallback rung splits on `-_` (handles `Mistral_7B_Q4_K_M`).
- `isJunkSegment(seg)`: lowercase; literals `{ud, imatrix, imat, gguf, ggml, bf16, fp16, f16, f32, fp32, fp8}` OR regex `^(i|t)?q[0-9]+(_[a-z0-9]+)*$`. Never matches `35b`, `a3b`, `qwen3`, `uncensored`, `v0.3`.
- `queryLadder(m) []string`: ordered, deduped (case-insensitive), ≤ `maxQueries`:
  1. `baseName` (empty → `m.Name`)
  2. quant-stripped (plus `-_` fallback rung if no change)
  3. backoff: drop last `-` segment until 2 remain (floor)
- Delete `searchQuery` + `quantSuffix` regex in hf.go.

### 3. `internal/hf/hf.go` — search/verify/guess rewrite

Constants: `maxQueries=4`, `maxCandidates=10` (global config-fetch budget), `maxVerifyPerRung=4` (per-rung cap so junk rung-1 candidates can't drain the global budget), `minSearchScore=0.5`, vocab: bonus ≤1% rel-diff, reject >10%. Weights: `wPrefix=0.25, wExact=0.10, wVocab=0.15, wDownloads=0.05`. `failMemoTTL=10m`.

Vocab tolerance rationale: HF `vocab_size` is padded vs real token count (Qwen3 151936 vs GGUF 151669 ≈ 0.17%); wrong tokenizer families are ≥40% apart (32000 vs 128256 vs 151936).

- `Resolver` gains `Store *YamlStore`, `mu sync.Mutex`, `failed map[string]time.Time` (negative memo, TTL 10 min, gates ONLY the network path so runtime `models tokenizer set` takes effect mid-run), `Forget(model)`.
- `NewResolver(configModels, store, cache)`.
- `Cache` interface: `GetHFMapping(name) (repo, source string, ok bool, err)` — return stored source so `guess` survives restarts.
- Resolve chain per priority above; yaml Get errors = miss (broken file must not brick resolution); full failure records failMemo and errors with hint text pointing at `models tokenizer`.
- `search(m) (repo, source string, err error)`: per ladder rung — GET `/api/models?search=<q>&limit=50` (network error = fatal); gate `overlap ≥ minSearchScore`; score = `overlap + wPrefix*prefixBonus + wExact*exactBonus + vocabBonus + downloadsTiebreak` where prefix = candidate name-part tokens (id minus org) are a prefix of the rung's query tokens (derivative pattern: base is head of local name), exact = normalized equality, downloads = `min(log10(dl+1)/6,1)*wDownloads`.
- Verification per candidate (skip repos tried this Resolve; per-rung + global budget): `fetchConfig(repo)` returns `{model_type, vocab_size}` (extend `archMatches`). Gate order: ① vocab >10% apart (both known) → reject outright (not guess-eligible); ② arch mismatch/unknown → not verified, stays guess-eligible (normalize strips `_` AND `-`); ③ tokenizer-file presence on prospective winner: HEAD `tokenizer_config.json` → fallback `tokenizer.json` → `tokenizer.model`, 200 = present, 404/401/403 → demote, next candidate. All pass → `store(..., "search")`.
- After all rungs: guess = best-scoring non-rejected candidate from the earliest rung that produced any (bias to most-specific query) → `store(..., "guess")`. Otherwise record failMemo, return `noMappingErr`.
- **Remove unconditional `list[0]` fallback.** `noMappingErr` text: point at `models tokenizer <model> <org/repo>` and `hf_models`.

### 4. `internal/hf/tokenizers_yaml.go` (new) — yaml store

- `YamlStore{path, mu, loaded, entries map[string]yamlEntry}`; `yamlEntry{Tokenizer, Source}` keyed lowercased model.
- `NewYamlStore(path)`, `Get`, `Set` (upsert, source `manual`, overwrites), `Delete` (case-insensitive, returns existed).
- File shape: header comment + `entries:` map. Read-modify-write via `yaml.Node` round-trip to preserve user comments/unknown keys; corrupt file errors on Set (never blind overwrite); first Set creates skeleton. In `internal/hf` (only consumer; new package for one type = overkill). `gopkg.in/yaml.v3` becomes direct dep.
- `internal/config/config.go`: add `Dir()` (exe dir, `"."` on error), refactor `Path()` onto it.

### 5. `internal/db/db.go`

- `GetHFMapping` returns `(repo, source string, ok bool, err)`.
- New `DeleteHFMapping(name)`. No schema change (source column exists).

### 6. `internal/benchmark` — surface guess

- `benchmark.go` `EvalParams`: add `HFSource string`.
- `manager.go`: `ResolveHF func(models.Model) (repo, source string, err error)`; in `runEval` (manager.go:568-584) on `source=="guess"` emit WARN `eval '%s': tokenizer %s is an unverified guess - pin one with 'models tokenizer %s <org/repo>'` once per model per process (`guessWarned map[string]bool` field).
- `lm_eval.go:68` INFO line appends `" (unverified guess)"`; empty-repo guard message (lm_eval.go:65) mentions `models tokenizer` while keeping substring `hf_models` (asserted by test). Update `manager_test.go` closures.

### 7. `main.go` — wiring + console

- Wiring (main.go:88-98): `store := hf.NewYamlStore(filepath.Join(config.Dir(), "tokenizers.yaml"))`; `hf.NewResolver(cfg.HFModels, store, xdb)`; `mgr.ResolveHF` closure returns `(repo, source, err)`.
- Route `models tokenizer ...` before `listModels`:
  - `models tokenizer <model> <org/repo>`: exactly 2 fields; repo shape validation (same as `hf_models`: 2 non-empty `/`-separated parts); warn-but-store if model not found in scan; `Store.Set`, `Forget`; LogOK. No restart needed (yaml above failMemo).
  - `models tokenizer --clear <model>`: `Store.Delete` + `db.DeleteHFMapping` + `Forget`; report what existed. Both removed so stale guess can't resurface.
- `modelDetail` (main.go:518-522): on `Source=="guess"` append `" - UNVERIFIED, pin with: models tokenizer <model> <org/repo>"`.
- Help text (main.go:674-694): add both commands. Note: model names with spaces unsupported (consistent with `start <model>`).
- template.go: one line in `hf_models` comment pointing at the console command.

## Edge cases covered

Sharded files (Name already strips shard suffix); TheBloke-era GGUFs with only `general.name` (ladder from Name; vocab neutral when unknown); derivative whose own repo is canonical (rung-1 wins — correct, its tokenizer matches the weights); `qwen3moe` vs `qwen3_moe`; misleading `general.basename` (ladder still has Name-derived rungs); underscore quant uploads; gated repos / missing tokenizer files (demote); rate limits (failMemo self-heals); runtime edits mid-run (`Forget`).

## Implementation order

1. gguf parser + tests
2. `hf/names.go` + table tests (pure)
3. db signatures + `hf.Cache` interface + memCache/test updates
4. hf search rewrite + extended `fakeHF` (query-dependent responses; configurable tokenizer-file presence) + resolve tests
5. `tokenizers_yaml.go` + tests; `config.Dir()`
6. benchmark changes + `manager_test.go` closures
7. main.go wiring/commands/help/template
8. `go build ./... && go vet ./... && go test ./...`, `gofmt`

## Verification

- `TestQueryLadder`: user's exact name → ladder ends `Qwen3.6-35B-A3B`; finetune strip; `UD-Q4_K_XL`; TheBloke `F16`; `imatrix-Q8_0`; never strips `35B`/`A3B`; floor 2 segments; ≤4 rungs.
- Resolver tests: end-to-end user example with `Source=="search"`; verified beats higher-downloads; guess fallback caches `source=guess`, second Resolve hits cache with `guess`; arch hard gate (old name-match fallback now expects `guess`); vocab reject >10% / bonus ≤1%; tokenizer-file demotion; failMemo (two failing Resolves → one search call).
- Yaml store: round-trip set/get/delete, overwrite, comment preservation, skeleton creation, case-insensitive Get, Delete-missing.
- gguf: `tokens_count` types 4/10, `tokenizer.ggml.model`, array-length fallback.
- `TestLmEvalTokenizerArg` still passes; db hf_map round-trip incl. source + delete.
- Final: `go build ./... && go vet ./... && go test ./...`.
