# Plan: Terminal-Bench 4.0 adapter pilot for localbench

## Context

User asked to implement four public agentic evaluations (DeepSWE, Terminal-Bench v4.0, AutomationBench-AA, SWE-Atlas-QnA). Decision (AskUserQuestion): **pilot one adapter end-to-end first — Terminal-Bench** — prove the pipeline (external harness pointed at local llama-server, scores ingested into localbench store), then replicate the pattern for the other benchmarks later. localbench's native model (JSON items + deterministic graders) cannot represent container-based agentic evals, so the adapter shells out to the official harness.

Research findings that shape the design:
- TB 4.0 runs via the **Harbor** framework (`harbor run -d terminal-bench/terminal-bench@4.0.0 -a terminus-2`), NOT the legacy `terminal-bench` pip CLI. Harbor needs Python ≥3.12.
- **Windows native broken** (laude-institute/terminal-bench#1170) → harbor runs inside **WSL2** (Ubuntu-22.04 default here). Terminus-2 runs on the WSL host and makes LLM calls from there → llama-server on Windows must be reachable from WSL (mirrored networking: `localhost`; NAT: gateway IP from `ip route show default`). Docker containers themselves never need to reach llama-server.
- Endpoint wiring: `-m openai/<model>` + `--ak api_base=http://HOST:PORT/v1` + `OPENAI_API_KEY=sk-dummy` (non-empty required) + `--ak model_info=...` + `--ak 'llm_call_kwargs={"timeout":1800}'` + `--agent-timeout-multiplier`.
- Results: `~/.cache/harbor/jobs/<job>/result.json` — JobResult with `trial_results[]` (`verifier_result.rewards`; trial resolved iff rewards non-empty and all ≥1.0), `evals[key].pass_at_k`, `stats`.
- 66 tasks; ~6 need GPU inside Docker → default exclude list.
- Machine state: Docker CLI 29.6.2 present, daemon down; WSL2 + Ubuntu-22.04 present.

## Changes

### 1. Store bug fix — `localbench/store.py:105-106`
`begin_run` uses positional `INSERT INTO runs VALUES (...)`. On legacy DBs where `_migrate()` appended `duration_seconds` last, physical order is `[run_id, started_at, finished_at, status, metadata, duration_seconds]` → NULL lands in `status` → `IntegrityError: NOT NULL constraint failed: runs.status` (blocks every eval on migrated DBs). Fix: named-column INSERT. Regression test `test_begin_run_on_legacy_column_order` in `tests/test_core.py` (hand-built old-schema DB → Store migrates → begin_run/finish_run work).

### 2. New module — `localbench/tbench.py`
All external interaction behind an injectable runner boundary (tests mock it; no WSL/Docker/harbor/llama-server in tests):

- `Runner` protocol + `SubprocessRunner` (default): `subprocess.run` list-argv, `shell=False`, `CREATE_NO_WINDOW` on Windows, no `text=True`; `stream()` variant with `on_line` callback for live harbor progress. Catches missing-binary as synthetic rc 127.
- `_decode_output(raw: bytes) -> str`: single choke point for wsl.exe **UTF-16LE** output (BOM check → null-byte heuristic → UTF-8 fallback).
- `wsl_argv(distro, script)` → `["wsl.exe", "-d", distro, "--", "bash", "-lc", script]`; all quoting via `shlex.quote` inside the one script string.
- `check_prereqs(runner, distro, llama_server) -> list[CheckResult]`: WSL distro exists, `harbor --version` inside WSL (fail detail = install hint incl. Python 3.12/uv note), `docker info` from inside WSL (fail detail = start Docker Desktop + WSL integration), llama-server binary present.
- `probe_host_address(runner, distro, port) -> str | None`: bash script inside WSL tries `localhost` then NAT gateway via `/dev/tcp` connect test; returns winning host.
- `list_job_dirs` / `locate_result_json`: snapshot `~/.cache/harbor/jobs/*` before/after run; pick new dir (fallback newest). `linux_to_unc()` maps to `\\wsl.localhost\<distro>\...` for reading `result.json` from Windows Python; fallback `cat` through WSL.
- `build_harbor_script(...) -> str`: composes the full `export OPENAI_API_KEY=sk-dummy; harbor run ...` script — dataset/agent/model flags, `--ak api_base=/v1`, `temperature`, `model_info` (JSON via `json.dumps`+quote), `llm_call_kwargs` timeout, `--agent-timeout-multiplier`, optional `-n/-k/--n-tasks/--task-name/--exclude-task-name` (only when set), user excludes merged with `DEFAULT_EXCLUDE_TASKS` (6 GPU tasks).
- `model_info_from_ctx(ctx_size, ...)`: explicit `--max-input-tokens`/`--max-output-tokens` win; else `max_input = max(1024, ctx - 8192)`; else defaults (32768/8192) + `ctx_size: null` recorded.
- `harbor_model_name(identifier, override)`: sanitized GGUF stem (llama-server ignores model name; sanitized chars only).
- `role_for_dataset("terminal-bench/terminal-bench@4.0.0")` → `"terminal-bench@4.0.0"` (scores.role value).
- `parse_result_json(payload) -> TbenchSummary`: per-trial resolution from `verifier_result.rewards` (non-empty, all ≥1.0) + `exception_info`; fallback to `evals[].pass_at_k` (marks `partial=True`); `ValueError` on unrecognized shape. Returns score, resolved/total, per-task rows, stats.

### 3. CLI — `localbench/cli.py`
- Parser block in `_build_parser` + dispatch branch after cli.py:480. Subcommand **`tbench`**.
- Flags: `--gguf-dir` (req), `--llama-server` (req), `--model`, `--dataset` (default `terminal-bench/terminal-bench@4.0.0`), `--agent` (default `terminus-2`), `--n-tasks`, `--n-attempts`, `--n-concurrent`, `--task-name` (repeatable), `--exclude-task-name` (repeatable, GPU defaults always merged), `--agent-timeout-multiplier` (default 3), `--wsl-distro` (default `Ubuntu-22.04`), `--ctx-size`, `--max-input-tokens`, `--max-output-tokens`, `--harbor-model-name`, `--temperature` (default 0), `--llm-call-timeout` (default 1800), `--bind` (default `0.0.0.0`), `--db`, `--dry-run`.
- `_tbench_command(args, store)` mirrors `_eval_command` (cli.py:324-406): `_resolve_models(args)` (cli.py:290) → metadata `{kind: "tbench", dataset, agent, wsl_distro, filters, model_info, platform, hardware: collect_hardware(), backend: "llama.cpp+harbor", ...}` → `begin_run` → `add_models` → prereq checks (fail → finish "failed", rc 2, actionable messages) → dry-run: print composed harbor script, finish "planned" (rc 0 if checks pass) — no server spawn → live: `LlamaServer(..., host=args.bind)` + `start()` in `try/finally: server.stop()`; `set_run_config(ctx_size, extra={build_info, api_base, bind})`; stream harbor output; parse `result.json`; `store.add_score(run_id, role_for_dataset(...), model.path, summary.score, details={total_trials, resolved, per_task, stats, partial, harbor_returncode, harbor_script, api_base, job_dir})`; per-model loop with multi-model warning. Statuses: completed / failed (incl. partial ingest: score kept, status "failed") / interrupted (KeyboardInterrupt, rc 130, prints `wsl -t <distro>` cleanup hint) / planned.
- Resume: out of scope v1 (harbor keeps own job dirs; each tbench run = new localbench run).

### 4. Tests — `tests/test_tbench.py` (new) + `tests/test_core.py`
Offline only, fake Runner (scripted `CompletedProcess`, UTF-16LE stdout), `_FakeServer` pattern from test_core.py:433-450, monkeypatched `LlamaServer`. ~20 tests: UTF-16 decode matrix, wsl_argv shape, prereq pass/fail per check, harbor script flag composition + optional omission + default excludes, model name sanitize/override, model_info math, role mapping, result parsing (trial resolution / evals fallback / reject unknown), host probe, job-dir location, UNC mapping, CLI dry-run ("planned", no server constructed), CLI happy path (score row + status + run_config extra), prereq failure, harbor failure with partial ingest, probe failure (server stopped).

### 5. Docs
- `AGENTS.md`: Common Commands row (`tbench ... [--n-tasks 2] [--dry-run]`); architecture bullet for `localbench/tbench.py` (runner boundary, UTF-16 choke point, harbor result ingestion, tests never require WSL/Docker/harbor); Verification line extended.
- `README.md`: "Terminal-Bench via Harbor (WSL2)" section — prereqs (WSL2 distro, Python ≥3.12 via uv inside it, `uv tool install 'harbor[modal]'`, Docker Desktop + WSL integration), dry-run + small live example, notes: llama-server binds 0.0.0.0 during run (LAN exposure), runs take hours (subsets mandatory), GPU tasks excluded by default, no resume v1.

## Verification

1. `python -m pytest -q` — full offline suite green (no WSL/Docker/harbor/server).
2. `python -m compileall -q localbench` — compile check.
3. Smoke on this machine: `python -m localbench.cli tbench --gguf-dir <dir> --llama-server <bin> --dry-run --db %TEMP%\tbench.db` — exercises real wsl.exe decode + prereqs; expect docker check to fail with actionable message (daemon currently down), status "planned".
4. Live pilot (user starts Docker Desktop, installs harbor in WSL): `tbench --n-tasks 2 --n-concurrent 1 --task-name "hello-world*"` — validates real `result.json` shape against `parse_result_json` before any long run; adjust parser if shape differs.

## Risks

1. wsl.exe quoting quirks → all complexity inside one `bash -lc` string; fallback = base64-wrapped script (one-function change).
2. `result.json` schema may differ by harbor version → defensive parser + evals fallback; live pilot validates before long runs.
3. Ctrl-C orphans harbor/containers in WSL → cleanup hint printed; reaper out of scope.
4. `0.0.0.0` bind exposes llama-server on LAN during run → documented, `--bind` overridable (127.0.0.1 works under mirrored networking).
5. `model_info` context budgeting is an approximation → recorded in metadata for attribution.
