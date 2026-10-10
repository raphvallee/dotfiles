# PTY Tools: LLM Operating Manual

Audience: an AI agent driving long-running and interactive processes through the
`opencode-pty` plugin (tools `pty_spawn`, `pty_read`, `pty_write`, `pty_list`, `pty_kill`).

Every rule in this document is either verified by live probe on this machine or
traced to source. Where docs and code disagree, this document follows the code.

---

## 0. Decision rules (read this first)

1. **Bounded job that ends on its own** (build, test, migration, codegen, lint, install):
   `pty_spawn` with `notifyOnExit: true` + `timeoutSeconds`, then **stop and wait**.
   Never call `pty_read` to check whether it finished. Never sleep-and-poll.
2. **Job that never ends** (dev server, watch mode, REPL, tunnel, local API):
   `pty_spawn` with **no** `timeoutSeconds` unless the user asked for one, then read once to
   confirm startup, do the work, and `pty_kill` with `cleanup: true` when done.
3. **Interactive prompt** (password, "press Y/n", REPL): `pty_spawn`, then `pty_write`.
4. **Anything else**: use the normal `bash` tool. PTY is for processes `bash` cannot wait on.
5. **On Windows, always spawn through `cmd /c "<full command line>"`** unless you have
   confirmed the bare name resolves to a real `.exe`. See section 4. This is the single
   largest source of silent failures.
6. **Never pass a command line with `&&`, `|`, `>`, `<`, `*`, `$VAR` as `args` elements
   without a shell.** There is no shell. See section 4.2.

---

## 1. What the tools are for

OpenCode's built-in `bash` tool is synchronous: it returns when the command exits. That makes
it unusable for anything long-running. The PTY plugin gives you real terminals (ConPTY on
Windows) whose output is captured into a rolling in-memory buffer you can page and regex-search
on demand, and which you can type into.

Use PTY for:

- dev servers (`npm run dev`, `dotnet watch run`, `gradle bootRun`, `go run`, `flutter run`,
  `cargo watch`, `python -m uvicorn ... --reload`)
- watch mode (`npm test -- --watch`, `tsc --watch`, `vite --watch`)
- long builds and full test suites (no timeout on your tool call)
- interactive programs (REPLs, prompts, `git` credential helpers, `ssh`, `psql`, `mysql`)
- anything that needs stdin, or that behaves differently when `isatty()` is true

Do **not** use PTY for:

- quick one-shot commands you want a plain exit code for (use `bash`)
- commands you need to run in a specific order inside one shell pipeline (use `bash`)
- reading a file (use `read`)

---

## 2. Tool reference (exact contracts)

### 2.1 `pty_spawn`

| Param | Type | Required | Default |
| --- | --- | --- | --- |
| `command` | string | **yes** | - |
| `args` | string[] | **yes** (pass `[]` if none) | - |
| `description` | string | **yes** | - |
| `workdir` | string | no | **the OpenCode server process's cwd**, NOT the project root |
| `env` | Record<string,string> | no | merged over inherited env, your keys win |
| `title` | string | no | `"{command} {args}"` |
| `notifyOnExit` | boolean | no | `false` |
| `timeoutSeconds` | number | no | never expires |

- `description` is 5-10 words. It is what shows up in the `<pty_exited>` notification as
  `Description:`, so make it the human meaning of the job, not a repeat of `title`.
- `title` is only cosmetic in `pty_list`. Keep it short and human.
- `workdir` default gotcha: the tool context's project directory is **never** used. If you omit
  `workdir` you get whatever directory OpenCode itself was launched from. **Always pass `workdir`
  explicitly** unless you genuinely want the ambient cwd.
- `timeoutSeconds` must be a positive integer. Validation runs before the process is created, so
  a bad value never leaves an orphan.
- `env` values must all be strings. You cannot *unset* an inherited variable, only override it
  with a value (`""` sets it empty). No `$VAR` expansion happens. `env` is not echoed back by
  `pty_list`, so record what you set.
- Terminal is fixed at 120 cols x 40 rows, `TERM=xterm-256color`. You cannot resize.

Returns:

```
<pty_spawned>
ID: pty_40108b2f
Title: Ticker
Command: cmd /c npm run dev
Workdir: C:\Temp\myproject
PID: 17776
Status: running
NotifyOnExit: true
TimeoutSeconds: 900
</pty_spawned>
```

The `Command:` line is a display string built by naive concatenation. It is **not** safely
copy-pasteable if any arg contains spaces.

`TimeoutSeconds: none` is printed when you omit `timeoutSeconds`.

**With `notifyOnExit: true` the result has an extra tail**: after `</pty_spawned>` the tool appends
a `<system_reminder>` telling you to wait for `<pty_exited>` instead of polling. Verified live. It
is injected text, not a spawn failure, and it is absent when `notifyOnExit` is false. See 3.4.

### 2.2 `pty_read`

| Param | Type | Required | Default |
| --- | --- | --- | --- |
| `id` | string | **yes** | - |
| `offset` | number | no | `0` (0-based) |
| `limit` | number | no | `500` |
| `pattern` | string | no | none |
| `ignoreCase` | boolean | no | `false` |

Semantics:

- **Plain mode** (`pattern` unset): `offset` is a 0-based **buffer line index**, `limit` is a line
  count. Printed line numbers are **1-based**. So `offset=0` prints line `00001`, `offset=500`
  prints line `00501`.
- **Pattern mode**: lines are filtered by regex **first**, then `offset`/`limit` page over the
  **matches**. `offset` here is a **match index**, not a line number. The printed numbers are
  still the original buffer line numbers. Verified: with matches on lines 3, 5, 6,
  `pattern="ERROR|CRITICAL", offset=1` returns lines `00005` and `00006`, and the footer suggests
  the next `offset` by adding to the match index.
- Only `''` and `'i'` regex flags are used, no `g`, so no lastIndex statefulness.
- A crude ReDoS filter rejects three shapes (nested optional groups with repetition, repeated
  `.*?` quantifiers, repeated alternation groups). **A syntactically invalid regex produces the
  same "Potentially dangerous regex pattern rejected" message**, because the validator swallows
  the parse error. Verified: `pattern="[unclosed"` returns
  `Potentially dangerous regex pattern rejected: '[unclosed'. Please use a safer pattern.`
  Treat that message as "your regex is invalid or unsafe", and simplify it.
- Zero matches is **not** an error. It returns a normal string: `No lines matched the pattern '...'`
  followed by `Total lines in buffer: N`.
- **Out-of-range `offset` lies.** Verified: reading `offset=999` from a 6-line buffer returns
  `(No output available - buffer is empty)` alongside `Total lines: 6`. If you see "buffer is
  empty" with a non-zero total, your offset was wrong, not the buffer.

### 2.3 `pty_write`

| Param | Type | Required |
| --- | --- | --- |
| `id` | string | **yes** |
| `data` | string | **yes** |

- Session must be `running`, otherwise it throws with the current status.
- Escape sequences are parsed in `data`: `\n`, `\r`, `\t`, `\xNN`, `\uNNNN`, `\\`. Anything else
  is sent literally.
- **Every line you type is permission-checked** against `permission.bash` before the bytes are
  written. Lines starting with `\x03` or `\x04` are exempt. So typing `rm -rf ...` into an
  interactive shell is checked exactly as if you had spawned it.
- The success line `Sent N bytes to <id>: "<preview>"` reports the **raw string length**, not the
  bytes actually written. `data="\x03"` reports `Sent 4 bytes` but writes 1. `preview` shows your
  literal escape text. Ignore both numbers and the preview.

Escape sequences worth memorizing:

| Want | Send |
| --- | --- |
| Enter | `\n` |
| Ctrl+C (interrupt) | `\x03` |
| Ctrl+D (EOF) | `\x04` |
| Tab (completion / accept) | `\t` |
| Ctrl+Z | `\x1a` |
| Arrow up / down / right / left | `\x1b[A` / `\x1b[B` / `\x1b[C` / `\x1b[D` |
| Yes to a prompt | `y\n` |

Verified on Windows: `\x03` on a ConPTY session interrupts the foreground process, conhost echoes
a literal `^C` line into the buffer, and the session transitions to `exited`.

### 2.4 `pty_list`

Takes **no arguments**. Returns every session, running or finished, in a block format:

```
[pty_ed5b26ff] workdir env probe
  Command: cmd /c echo hi
  Status: exited | exit: 0
  PID: 29584 | timeout: 60s
  Lines: 6
  Workdir: C:\Temp\opencode-pty\src
  Created: 2026-10-01T22:58:47.910Z

Total: 3 session(s)
```

Status suffixes: `| timed out`, `| exit: N`, `| signal: S`. The `timeout: Ns` marker is appended
to the **PID** line, not the status line. `pty_list` does **not** show `description`,
`notifyOnExit`, or `exitAt`. Remember what you spawned.

### 2.5 `pty_kill`

| Param | Type | Required | Default |
| --- | --- | --- | --- |
| `id` | string | **yes** | - |
| `cleanup` | boolean | no | `false` |

- `cleanup: false` keeps the session in the list with its buffer intact, so you can still
  `pty_read` the logs. Use this when you kill something you are about to investigate.
- `cleanup: true` deletes the session and frees the buffer. Use this when you are done.
- Verified wording bug: killing an already-finished session with `cleanup: false` reports
  `Cleaned up: <id> (session retained for log access)`. Both halves contradict each other and
  nothing was actually killed or cleaned. Check the status yourself rather than trusting the verb.
- Prefer `pty_write` with `\x03` over `pty_kill` for a graceful stop. Reserve `pty_kill` for
  processes that ignore interrupts.

---

## 3. Output format reference (what you will actually receive)

### 3.1 `pty_read`, plain

```
<pty_output id="pty_89dc0cdb" status="running">
00001| [?9001h[?1004h[?25l[2J[m[Htick 1
00002| ]0;C:\Windows\system32\cmd.EXE[?25htick 2
00003| tick 3

(Buffer has more lines. Use offset=3 to read beyond line 3)
</pty_output>
```

- Line format is `NNNNN| text`: 5-digit zero-padded 1-based line number, pipe, space.
- Lines longer than 2000 characters are cut and suffixed with `...`.
- Footer is either the "more lines" hint (with the exact next `offset`) or
  `(End of buffer - total N lines)`.
- `status` is one of `running`, `killing`, `exited`, `killed`.

### 3.2 `pty_read`, filtered

```
<pty_output id="pty_ed5b26ff" status="exited" pattern="ERROR|CRITICAL">
00003| ERROR alpha
00005| ERROR gamma
00006| CRITICAL delta

(3 matches from 6 total lines)
</pty_output>
```

### 3.3 The `<pty_exited>` notification

Fires as a **future message** on your own session, only when `notifyOnExit: true`. It does not
arrive inside a tool result.

```
<pty_exited>
ID: pty_f9fa792e
Description: Verify auto timeout kill behaviour
Exit Code: 0
TimeoutSeconds: 5
Timed Out: yes
Output Lines: 1
Last Line: [?9001h[?1004h
</pty_exited>

Process reached its PTY timeout and was stopped automatically. Use pty_read to inspect the final output.
```

Rules for reading it:

- `Description:` is your `description`, sliced to 64 chars **plus** a trailing `...` when longer
  (so up to 67 chars). Falls back to `title` only if `description` is missing.
- `Last Line:` is the last **non-blank** line, sliced to 250 chars plus `...`, and it is frequently
  conhost noise rather than anything meaningful. **Do not treat it as the result.**
- `Output Lines:` is the current buffer line count, not the number of lines the program printed.
- The trailing sentence is your routing instruction: timed out, or `Exit Code: 0`, or
  `Process failed. Use pty_read with the pattern parameter to search for errors`.
- **`Exit Code: 0` does not mean success when `Timed Out: yes`.** Verified: a session killed by
  its own 5-second timeout reported `Exit Code: 0`. Killed-by-signal also reports `0`. Always
  read the `Timed Out` and `Output Lines` fields too.

### 3.4 Injected `<system_reminder>` blocks

There are **three** reminder sites. None of them is a finding, all are injected text:

1. **After `pty_spawn` with `notifyOnExit: true`** ("Completion signal for this session is the
   future `<pty_exited>` message..."). Only when `notifyOnExit` is true.
2. **After `pty_read` on a still-`running` session spawned with `notifyOnExit: true`** ("This
   session was started with `notifyOnExit=true`..."). Suppressed once the session leaves `running`.
3. **After `pty_read` on any session that was auto-killed by its own `timeoutSeconds`**
   ("This session was auto-killed after reaching `timeoutSeconds=N`..."). This one is
   **not** limited to the moment of death: it is re-appended to every later read of that session,
   however long ago it timed out. Verified live. Ignore it and read the log.

---

## 4. Windows execution rules (verified on this machine)

This is the most important section. The plugin contains **zero** platform-specific code, and
the underlying `bun-pty` uses ConPTY with a hand-rolled argument transport. The consequences are
sharp and specific.

### 4.1 Bare command names are unreliable

`pty_spawn` does not wrap your command in a shell. `command` becomes a program name and `args`
become literal argv entries. Verified results:

| Spawn form | Result |
| --- | --- |
| `command="java"`, `args=["-version"]` | works |
| `command="dotnet"`, `args=["--version"]` | works |
| `command="python"`, `args=["--version"]` | works |
| `command="go"`, `args=["--version"]` | works (but `--version` is not a valid go flag) |
| `command="pip"`, `args=["--version"]` | works |
| `command="uv"`, `args=["--version"]` | works |
| `command="npm"`, `args=["--version"]` | **`PTY spawn failed`** |
| `command="mvn"`, `args=["-version"]` | **`PTY spawn failed`** |
| `command="gradle"`, `args=["-version"]` | **`PTY spawn failed`** |
| `command="flutter"`, `args=["--version"]` | **`PTY spawn failed`** |
| `command="dart"`, `args=["--version"]` | **`PTY spawn failed`** |
| `command="bun"`, `args=["--version"]` | **`PTY spawn failed`** (despite `bun.exe` existing on PATH) |
| `command="C:\\Users\\rapha\\.bun\\bin\\bun.exe"`, `args=["--version"]` | works |
| `command="cmd"`, `args=["/c","npm --version"]` | works |

Two separate causes, both producing the same useless `PTY spawn failed` message:

1. **Windows shims are not executables.** `npm`, `npx`, `mvn`, `gradle`, `flutter`, `dart`,
   `yarn`, `pnpm`, `tsc` are installed as `.cmd` or `.bat` plus a shell script. There is no
   matching `.exe`, so the direct spawn finds nothing. `flutter` and `dart` on Windows are
   literally `flutter.bat` and `dart.bat`.
2. **Some real `.exe` files still fail bare-name resolution.** `bun` is a genuine `bun.exe` on
   PATH and failed anyway, while `dotnet`, `java`, `python`, `go`, `pip`, `uv` all succeeded from
   comparable PATH positions. Re-verified 2026-10-01: bare `bun` fails, the absolute
   `C:\Users\rapha\.bun\bin\bun.exe` works, `cmd /c bun --version` works. Treat the cause as
   unresolved, not as a rule you can derive: `bun-pty` is not vendored in this checkout, so
   nothing here explains it. Do not waste time theorising, just use `cmd /c`.

Note that `PTY spawn failed` is **not** a string the plugin emits. It comes from below the
plugin (`bun-pty`, or the host's tool runner), so you cannot grep this repo for it.

**Rule: on Windows, default to `cmd /c`.** It resolves `.cmd`, `.bat`, and `.exe` alike, it
applies your ambient PATH, and it costs you nothing.

### 4.2 You must ask for a shell explicitly

`args` entries never go through shell parsing. These do **not** work as bare `args` elements:

```
args: ["run", "dev", "&&", "echo", "done"]     // "&&" is passed as a literal argument
args: ["run", "dev", "&&", "npm", "test"]      // npm never runs
args: ["-c", "grep foo *.ts"]                  // "*" is not a glob
args: ["-c", "echo $HOME"]                     // no expansion
args: [">", "out.log"]                         // no redirection
```

They all work when wrapped:

```json
{
  "command": "cmd",
  "args": ["/c", "npm run dev && npm test"],
  "description": "Build then test the project"
}
```

Verified: `cmd /c` handles `&&`, `|`, `>`, `<`, `*`, `%VAR%`, and parentheses.

### 4.3 Shell wrapper recipes

```jsonc
// cmd.exe, the default choice. /c runs the string then exits.
{ "command": "cmd", "args": ["/c", "<command line>"] }

// cmd.exe kept alive as an interactive shell (Ctrl+C, pty_write work well here).
{ "command": "cmd", "args": [] }
{ "command": "cmd", "args": ["/k", "<command line>"] }   // /k keeps the shell open

// PowerShell 7 when you need pipes into PowerShell cmdlets or $env: syntax.
{ "command": "pwsh", "args": ["-NoProfile", "-Command", "<command line>"] }

// Git Bash, if it exists. Verify first; it is not guaranteed.
{ "command": "bash", "args": ["-lc", "<command line>"] }

// Absolute path to a real .exe. Verified to work.
{ "command": "C:\\Users\\rapha\\.bun\\bin\\bun.exe", "args": ["--version"] }
```

Always pass `-NoProfile` / `--noprofile` to PowerShell and avoid login shells: profile scripts
can print noise, change the working directory, or hang waiting for input.

Note that `%VAR%` is cmd syntax and `$env:VAR` is PowerShell syntax. Inside `cmd /c "..."` use
`%VAR%`.

### 4.4 conhost noise in every buffer

Windows console-host writes VT-enable and title-set sequences into the PTY before your program's
first byte of output. Verified across `cmd`, `python`, and `bun`:

- line 1 begins with `[?9001h[?1004h[?25l[2J[m[H`
- line 2 begins with `]0;<executable path>[?25h`

Consequences:

- Line `00001` and line `00002` of most sessions are partly garbage. Strip the escape runs and
  read what follows them.
- The `<pty_exited>` notification's `Last Line:` is sometimes exactly this garbage, e.g.
  `Last Line: [?9001h[?1004h`. **When the notification fires, run `pty_read` and read the real
  output. Do not report the notification's last line as the result.**
- `pty_read` splits on `\n` only. A progress bar or spinner that redraws with `\r` becomes one
  enormous single line that gets truncated at 2000 chars, destroying its content. This is why
  section 7 tells you to disable progress rendering per toolchain.

### 4.5 Killing is not SIGTERM

The tool description says "sends SIGTERM". On Windows that does not exist. Termination maps to
ConPTY's native mechanism, `exitSignal` may never populate, and a killed process often reports
`Exit Code: 0`. Prefer `\x03`, then `pty_kill`, then `taskkill` in a shell as a last resort:

```jsonc
{ "command": "cmd", "args": ["/c", "taskkill /F /T /PID <pid>"] }
```

The `PID` is in the `<pty_spawned>` block and in `pty_list`. `/T` kills the whole child tree,
which matters for `npm run dev` (npm spawns node, node spawns vite).

### 4.6 Python virtualenv layout

Windows venvs put executables in `Scripts\`, not `bin/`. Use
`C:\path\to\.venv\Scripts\python.exe`, not `.venv/bin/python`.

---

## 5. The two canonical workflows

### 5.1 Bounded job (build, test, install, migrate)

```
pty_spawn {
  command:      <executable>,
  args:         [...],
  workdir:      "<project root>",
  title:        "Tests",
  description:  "Run the full unit test suite",
  notifyOnExit: true,
  timeoutSeconds: 1800
}
```

Then: **nothing.** Do not read. Do not sleep. Do not poll. Wait for the `<pty_exited>` message.

On arrival:

- `Exit Code: 0` and `Timed Out: no`: success. Optionally `pty_read` if you need to quote
  details. `pty_kill {cleanup: true}`.
- `Exit Code: 0` and `Timed Out: yes`: **failure of unknown kind.** The job was cut off. Read the
  output and find out how far it got.
- `Exit Code != 0`: failure. `pty_read { pattern: "error|fail|exception|denied", ignoreCase: true }`
  first, then widen. Do not dump the whole buffer into your context.
- `pty_kill {cleanup: true}` when you are finished, or `cleanup: false` if you still need the log.

Timeout sizing: unit tests 900-1800, e2e 1800-3600, first-time installs 1800+, quick lint 300.
Under-provisioning produces a silent truncation that looks like success.

### 5.2 Long-running server or watch mode

```
pty_spawn {
  command: "cmd", args: ["/c", "npm run dev"],
  workdir: "<project root>",
  title: "Vite dev server",
  description: "Run the Vite dev server on port 5173",
  notifyOnExit: false
}
```

No `timeoutSeconds`. `notifyOnExit: false`, because you do not want a notification every time
you edit a file and the server restarts.

Then:

1. `pty_read { id, limit: 60 }` **once** to confirm it booted and to learn the port. Expected
   shape is "ready in NNNms" or "Listening on http://localhost:PORT".
2. If you need to answer a prompt, `pty_write`.
3. Do the actual work (edit files, run tests against the server, call the API).
4. On failure, `pty_read { pattern: "error|EADDRINUSE|Error", ignoreCase: true }`.
5. `pty_kill { id, cleanup: true }` when done. Do not leave servers running.

Live logs while you work: `pty_read { pattern: "...", limit: 30 }`. Since the buffer is a rolling
window, a targeted pattern is the only way to find what you need in a chatty server.

---

## 6. Reading output efficiently

The buffer holds roughly **1,000,000 characters** (not lines) per session, defaulting from
`PTY_MAX_BUFFER_SIZE`. Long lines eat capacity fast, and truncation slices from the front
mid-line, so `offset=0` on a truncated buffer returns a partial first line.

Strategy, in order of preference:

1. `pattern` with a tight alternation. This is the primary tool.
   `pattern: "error|warn|fail|panic|exception"`, `ignoreCase: true`.
2. `pattern` plus a small `limit` to sample: `pattern: "GET /api", limit: 20`.
3. Tail by arithmetic: from `(End of buffer - total 4821 lines)`, the last 80 lines are
   `offset: 4741, limit: 80`.
4. Whole-buffer dump only as a last resort, and only for small buffers.

Do not repeatedly read the same range to "stay current". Each read is wasted context. One read
with a good pattern beats twenty reads with a bad one.

Anchors worth remembering per toolchain: `error`, `Error`, `ERROR`, `FAILED`, `FAIL`, `warning`,
`WARN`, `panic:`, `Exception`, `Traceback`, `error CS`, `error TS`, `FAILED`, `BUILD FAILED`,
`npm ERR!`, `Unhandled exception`, `Segmentation fault`, `EADDRINUSE`, `No such file or directory`,
`Could not resolve`, `Unable to locate`.

---

## 7. Toolchain playbooks

Windows forms are shown. Replace the wrapper with the platform's equivalent elsewhere
(`sh -c "<line>"` on Linux and macOS).

### 7.1 Common preflight

Before trusting a toolchain in a PTY, verify it resolves. A `PTY spawn failed` from
`pty_spawn` means "no such executable", not "bad arguments", and it names nothing useful.

```jsonc
// Node
{ "command": "cmd", "args": ["/c", "node --version && npm --version"], "description": "Check node and npm", "notifyOnExit": true, "timeoutSeconds": 60 }
// Bun
{ "command": "cmd", "args": ["/c", "bun --version"], "description": "Check bun version", "notifyOnExit": true, "timeoutSeconds": 60 }
```

### 7.2 TypeScript / Node / npm / Bun

| Intent | Command |
| --- | --- |
| Install deps | `cmd /c npm ci` (or `npm install`) |
| Install deps, bun | `cmd /c bun install` |
| Dev server | `cmd /c npm run dev` |
| Dev server, bun | `cmd /c bun run dev` |
| Build | `cmd /c npm run build` |
| Typecheck | `cmd /c npx tsc --noEmit` |
| Lint | `cmd /c npm run lint` |
| Unit tests | `cmd /c npm test` |
| Tests, no watch | `cmd /c npm test -- --run` (vitest) |
| Watch tests | `cmd /c npm test -- --watch` |
| Run a one-off script | `cmd /c npx tsx script.ts` |
| Run with bun | `cmd /c bun run script.ts` |

Recommended `env` for any npm/bun job: `{ "NO_COLOR": "1", "CI": "1" }`. `CI=1` suppresses
interactive prompts and spinners that would otherwise sit forever waiting for a TTY answer.

Treat builds and tests as bounded jobs (`notifyOnExit: true` + timeout). Treat `npm run dev`,
`npm test -- --watch`, and `npx tsc --watch` as long-running (no timeout, `notifyOnExit: false`).

### 7.3 Python

| Intent | Command |
| --- | --- |
| Create venv | `cmd /c python -m venv .venv` |
| Create venv, uv | `cmd /c uv venv` |
| Activate (never needed) | use the full interpreter path instead |
| Install requirements | `cmd /c .venv\Scripts\python.exe -m pip install -r requirements.txt` |
| Install package, editable | `cmd /c .venv\Scripts\python.exe -m pip install -e .` |
| Install project, uv | `cmd /c uv sync` |
| Run script | `cmd /c .venv\Scripts\python.exe -u script.py` |
| pytest | `cmd /c .venv\Scripts\python.exe -m pytest -q` |
| pytest, one file | `cmd /c .venv\Scripts\python.exe -m pytest -q tests\test_api.py` |
| pytest, last failure | add `-x --lf` |
| FastAPI + reload | `cmd /c .venv\Scripts\python.exe -m uvicorn app.main:app --reload --port 8000` |
| Django dev server | `cmd /c .venv\Scripts\python.exe manage.py runserver 8000` |
| Flask | `cmd /c .venv\Scripts\python.exe -m flask run --port 5000` |
| REPL | `python` |
| Lint | `cmd /c .venv\Scripts\python.exe -m ruff check .` |

- **Always use `-m`**: `python -m pytest` puts the project root on `sys.path`, a bare `pytest`
  does not, and you will chase phantom import errors.
- Add `-u` for unbuffered output. A PTY is a TTY so Python is line-buffered by default, but `-u`
  removes all doubt, and `-u` is what you want when the process might be piped by a wrapper.
- Always use `python`, never `python3`, on Windows. There is no `python3.exe`.
- `pip` works bare (it is a real `.exe`) but `python -m pip` is safer because it guarantees the
  interpreter matches the venv.

### 7.4 Go

| Intent | Command |
| --- | --- |
| Version | `cmd /c go version` (not `go --version`, which exits 2) |
| Download deps | `cmd /c go mod download` |
| Tidy | `cmd /c go mod tidy` |
| Build | `cmd /c go build ./...` |
| Build with version | `cmd /c go build -ldflags "-X main.version=1.2.3" -o dist\app.exe .` |
| Vet | `cmd /c go vet ./...` |
| Test | `cmd /c go test ./...` |
| Test, bypass cache | `cmd /c go test -count=1 ./...` |
| Test with race detector | `cmd /c go test -race ./...` |
| Test, verbose, one package | `cmd /c go test -v -count=1 ./internal/foo` |
| Coverage | `cmd /c go test -coverprofile=coverage.out ./...` |
| Run | `cmd /c go run .` |
| Run a file | `cmd /c go run cmd\server\main.go` |
| Watch and reload | `cmd /c go run github.com/air-verse/air@latest` |
| Hot reload via nodemon-like | `cmd /c air` after `go install github.com/air-verse/air@latest` |

- `-count=1` is essential. Go's test cache will happily return a stale green result and you will
  report success for code you never ran.
- `go build ./...` on Windows produces `.exe` files next to the sources; pass `-o dist\app.exe`
  when you want a single artifact.
- `go test ./...` is a bounded job: `notifyOnExit: true`, `timeoutSeconds: 900`.

### 7.5 Java (Maven and Gradle)

Both `mvn` and `gradle` are `.cmd`/`.bat` on Windows. **`cmd /c` is mandatory.** Wrapper scripts
`mvnw` and `gradlew` are `mvnw.cmd` and `gradlew.bat` on Windows, so `cmd /c mvnw.cmd` /
`cmd /c gradlew.bat`.

Maven:

| Intent | Command |
| --- | --- |
| Resolve deps | `cmd /c mvn -B -ntp dependency:go-offline` |
| Compile | `cmd /c mvn -B -ntp -DskipTests compile` |
| Package | `cmd /c mvn -B -ntp -DskipTests package` |
| Test | `cmd /c mvn -B -ntp test` |
| One test class | `cmd /c mvn -B -ntp test -Dtest=UserServiceTest` |
| One test method | `cmd /c mvn -B -ntp test -Dtest=UserServiceTest#shouldCreate` |
| Integration tests | `cmd /c mvn -B -ntp verify` |
| Spring Boot run | `cmd /c mvn -B -ntp spring-boot:run` |
| Skip web tests | add `-DskipTests` |

`-B` is non-interactive batch mode and `-ntp` disables transfer progress. **Both are required**,
otherwise Maven asks interactive questions and draws a progress bar with `\r` that destroys the
buffer.

Gradle:

| Intent | Command |
| --- | --- |
| Compile | `cmd /c gradlew.bat --console=plain --no-daemon compileJava` |
| Build | `cmd /c gradlew.bat --console=plain --no-daemon build` |
| Test | `cmd /c gradlew.bat --console=plain --no-daemon test` |
| One class | `cmd /c gradlew.bat --console=plain test --tests "com.example.UserServiceTest"` |
| Integration tests | `cmd /c gradlew.bat --console=plain integrationTest` |
| Boot run | `cmd /c gradlew.bat --console=plain bootRun` |
| Lint | `cmd /c gradlew.bat --console=plain checkstyleMain` |
| Dependency tree | `cmd /c gradlew.bat --console=plain dependencies` |
| Stop the daemon | `cmd /c gradlew.bat --stop` |

`--console=plain` disables rich ANSI output. Without it Gradle emits cursor movement and
colors that turn into unreadable truncated lines. `--no-daemon` prevents a lingering JVM and
makes failures reproducible; omit it only for fast repeated local runs.

**JVM/Maven/Gradle tasks that never terminate**: `bootRun`, `spring-boot:run`,
`gradlew.bat --console=plain kspFlutterBuild` equivalents, and any `while(true)` task. These get
no timeout. If a Gradle task "hangs", first check whether it is actually a long-lived
`JavaExec` by reading the output for "started" lines.

Gradle daemon: a stuck build often means a stuck daemon. `cmd /c gradlew.bat --stop` is your
reset.

### 7.6 Kotlin

`kotlinc` and `kotlin` are `.bat` on Windows, so `cmd /c` is mandatory.

| Intent | Command |
| --- | --- |
| Compile | `cmd /c kotlinc src\Main.kt -include-runtime -d app.jar` |
| Run | `cmd /c kotlinc -script script.kts` |
| Run a jar | `cmd /c java -jar app.jar` |
| Version | `cmd /c kotlinc -version` |

Most real Kotlin work is Gradle-based, so section 7.5 applies with `--console=plain`.

### 7.7 .NET / C#

| Intent | Command |
| --- | --- |
| SDK version | `cmd /c dotnet --list-sdks` |
| Restore | `cmd /c dotnet restore` |
| Build | `cmd /c dotnet build -c Release --tl:off -v q --nologo` |
| Build a solution | `cmd /c dotnet build MyApp.sln -c Release --tl:off -v q` |
| Test | `cmd /c dotnet test --tl:off -v q` |
| One project | `cmd /c dotnet test tests\MyApp.Tests.csproj --tl:off` |
| Filter by name | `cmd /c dotnet test --filter "FullyQualifiedName~UserService"` |
| Coverage | `cmd /c dotnet test --collect:"XPlat Code Coverage"` |
| Run | `cmd /c dotnet run` |
| Run with watch | `cmd /c dotnet watch run` |
| ASP.NET, fixed port | `cmd /c dotnet run --urls http://localhost:5000` |
| Publish | `cmd /c dotnet publish -c Release -o dist --tl:off` |
| Pack a NuGet library | `cmd /c dotnet pack -c Release --tl:off` |
| EF migrations | `cmd /c dotnet ef migrations add InitialCreate` |
| EF apply | `cmd /c dotnet ef database update` |
| Format | `cmd /c dotnet format` |

`--tl:off` is **not optional**. Modern MSBuild's terminal logger paints the whole build with
cursor control and colour, which collapses into unusable truncated lines. Combine with `-v q`
(quiet) or `--verbosity minimal`.

Always pass the project or solution path explicitly in a monorepo, otherwise `dotnet build` may
pick the wrong one or fail with "found more than one project".

Recommended `env` for any `dotnet` job: `{ "DOTNET_CLI_TELEMETRY_OPTOUT": "1", "DOTNET_NOLOGO": "1" }`.
`DOTNET_NOLOGO=1` also matters in a TTY, where the first-run banner is emitted.

Global state: `dotnet` writes to `%USERPROFILE%\.nuget`. Concurrent `dotnet restore` processes
lock it. Do not run parallel restores in sibling sessions.

`dotnet watch run` is long-running: no timeout, `notifyOnExit: false`. `dotnet watch` also
restarts the app on every file change, so its buffer fills fast. Prefer pattern reads.

### 7.8 C++ / CMake

The hard problem on Windows is that the PTY inherits the **OpenCode server's** environment: the
plugin merges `process.env` with your `env` and hands the result to `bun-pty`
(`src/plugin/pty/session-lifecycle.ts`). So whether you get the MSVC toolchain (`cl.exe`,
`link.exe`, `INCLUDE`, `LIB`) depends entirely on **how OpenCode itself was launched**, not on the
plugin. Start OpenCode from a Developer Command Prompt or a shell where `vcvars64.bat` already
ran and the toolchain is simply inherited; there is no `vcvars` integration to worry about.

When OpenCode was launched from a plain shell (the usual case), initialise the environment inside
the spawned command instead, in one `cmd /c` line.

```jsonc
// Build with MSVC, environment set up in the same shell.
{
  "command": "cmd",
  "args": ["/c", "call \"C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\VC\\Auxiliary\\Build\\vcvars64.bat\" && cmake --build build --config Release"],
  "description": "Build the C++ project with MSVC"
}
```

Use your actual edition: `Community`, `Professional`, or `Enterprise`. `call` is required so the
batch file's changes to the environment survive into the rest of the line.

Commands:

| Intent | Command |
| --- | --- |
| Configure, MSVC | `cmd /c cmake -S . -B build` (run under `vcvars64.bat`) |
| Configure, Ninja | `cmd /c cmake -S . -B build -G Ninja` |
| Configure with Release | `cmd /c cmake -S . -B build -DCMAKE_BUILD_TYPE=Release` |
| Configure, multi-config | `cmd /c cmake -S . -B build -G "Visual Studio 17 2022" -A x64` |
| Build | `cmd /c cmake --build build --config Release` |
| Build, parallel | `cmd /c cmake --build build --config Release --parallel` |
| Build one target | `cmd /c cmake --build build --config Release --target myapp` |
| Test | `cmd /c ctest --test-dir build -C Release --output-on-failure` |
| Clean | `cmd /c cmake --build build --config Release --target clean` |
| Run the binary | `cmd /c build\Release\myapp.exe` |
| Install deps (vcpkg) | `cmd /c vcpkg install --triplet x64-windows` |

Notes:

- Multi-config generators (Visual Studio, Ninja Multi-Config) need `-C Release` on **both**
  `cmake --build` and `ctest`. Single-config generators (Ninja, "Unix Makefiles") use
  `-DCMAKE_BUILD_TYPE` at configure time instead.
- `--output-on-failure` on `ctest` is essential. Without it a failing test prints nothing.
- `--parallel` speeds up large builds noticeably; leave it on unless a build step is not
  thread-safe.
- `msbuild MyApp.sln /p:Configuration=Release /v:m` is the direct alternative to
  `cmake --build`. Add `/tl:off` if you use MSBuild directly on recent SDKs.
- A compiler crash or `LNK1102 out of memory` usually means a partial build directory. Delete
  `build` and reconfigure rather than retrying.
- Long-running: your own executable, or a server binary. `cmd /c build\Debug\server.exe`,
  no timeout.

### 7.9 Flutter / Dart

`flutter` and `dart` are **`.bat` on Windows**. `cmd /c` is mandatory. Verified: both fail with
`PTY spawn failed` when spawned bare.

| Intent | Command |
| --- | --- |
| Flutter version | `cmd /c flutter --version` |
| Dart version | `cmd /c dart --version` |
| Get packages | `cmd /c flutter pub get` |
| Get packages, no progress | `cmd /c flutter pub get --no-example` |
| Analyze | `cmd /c flutter analyze` |
| Analyze, Dart only | `cmd /c dart analyze` |
| Format check | `cmd /c dart format --output=none --set-exit-if-changed .` |
| Tests | `cmd /c flutter test` |
| One test file | `cmd /c flutter test test\widget_test.dart` |
| One test by name | `cmd /c flutter test --plain-name "renders correctly"` |
| Coverage | `cmd /c flutter test --coverage` |
| List devices | `cmd /c flutter devices` |
| Run, auto device | `cmd /c flutter run` |
| Run, web | `cmd /c flutter run -d chrome` |
| Run, specific device | `cmd /c flutter run -d <device-id>` |
| Run, release | `cmd /c flutter run --release` |
| Hot reload key | `pty_write` with data `r` |
| Hot restart key | `pty_write` with data `R` |
| Quit the run session | `pty_write` with data `q` |
| Build APK | `cmd /c flutter build apk --release` |
| Build web | `cmd /c flutter build web --release` |
| Build iOS (macOS host) | `cmd /c flutter build ios --release` |
| Build Windows desktop | `cmd /c flutter build windows --release` |
| Dart standalone run | `cmd /c dart run bin\main.dart` |
| Dart compile | `cmd /c dart compile exe bin\main.dart -o dist\main.exe` |
| Dart test | `cmd /c dart test` |
| Activate a package | `cmd /c dart pub global activate some_pkg` |

- `flutter run` is an **interactive, long-running** session. No `timeoutSeconds`,
  `notifyOnExit: false`, and it is a perfect use of `pty_write`. Press `r` to hot reload after
  edits, `R` to hot restart, `q` to quit. That is the intended workflow and far better than
  kill/respawn cycles.
- `flutter` draws a spinner and a status line with `\r`. To get clean logs in a bounded job use
  `--no-version-check` and, on builds, prefer `dart` tools or check the exit code rather than the
  rendered output.
- `flutter build` needs an Android SDK, Xcode, or the Visual Studio C++ toolchain, depending on
  target. If the toolchain is missing you get a long multi-line error. `pty_read` with
  `pattern: "error|failed|not found|requires"` to find it fast.
- First `flutter run` after a platform change can take many minutes (Gradle/Xcode warm-up). Give
  bounded builds a generous `timeoutSeconds` (3600+).
- Android emulators and iOS simulators are separate concerns from PTY. `flutter devices` tells
  you what exists; if the list is empty the problem is device setup, not the PTY.

### 7.10 Swift

| Intent | Command |
| --- | --- |
| Version | `cmd /c swift --version` |
| Resolve deps | `cmd /c swift package resolve` |
| Build | `cmd /c swift build` |
| Build, release | `cmd /c swift build -c release` |
| Test | `cmd /c swift test` |
| One test | `cmd /c swift test --filter UserServiceTests` |
| Run | `cmd /c swift run` |
| Run a target | `cmd /c swift run MyTarget --arg value` |
| Executable | `cmd /c .build\debug\myapp.exe` |
| Format | `cmd /c swift format lint --recursive .` |

- `swift build` and `swift test` are bounded jobs. Use `notifyOnExit: true` + timeout. Builds
  after a cold start can exceed 600s on Windows; provision 1800.
- On Windows the Swift toolchain requires the Visual Studio C++ toolchain and works best from a
  shell where `vcvars64.bat` has run, which is the same problem as section 7.8.
- On macOS, `swift run` for a server app is a long-running session.
- If `swift` is not on PATH, the toolchain is not installed. That is a `PTY spawn failed`, not a
  build failure.

---

## 8. Permissions

`pty_spawn` and `pty_write` are checked against OpenCode's `permission.bash`. `pty_read`,
`pty_list`, `pty_kill` are not.

Rules (V1 plugin API):

- `"ask"` is treated as **deny**. Plugins cannot raise OpenCode's permission prompt, so an
  `ask` match fails with `PTY spawn denied: Command "..." requires user permission which is not
  supported by this plugin. Configure explicit "allow" or "deny" in your opencode.json
  permission.bash settings.` A toast tells the user. The fix is the user editing `opencode.json`.
- Unmatched commands are **allowed**. An allow-list is not a deny-all-unlisted.
- With a record of patterns, the longest matching pattern wins.
- `workdir` outside the project directory is checked against `permission.external_directory`.
  `deny` blocks it; `ask` is treated as **allow**.
- Under the **V2** plugin API no permission checking happens at all.

Practical response to a denial: do not retry with cosmetic variations hoping to slip through.
Tell the user the exact `opencode.json` entry they need.

---

## 9. Failure modes and gotchas

| Symptom | Meaning | Action |
| --- | --- | --- |
| `PTY spawn failed` | executable not found. Bare `.cmd`/`.bat` names always do this | wrap in `cmd /c`, or use an absolute `.exe` path |
| Empty buffer, real `Total lines: N` | your `offset` was past the end | recompute from the total |
| `(No output available - buffer is empty)` on a fresh session | process has not written yet, or it wrote nothing at all | read once more; if still empty, the process probably died instantly. Check `pty_list` for status |
| `Potentially dangerous regex pattern rejected` | regex invalid **or** ReDoS-shaped | simplify the pattern, avoid nested quantifiers |
| `No lines matched the pattern` | not an error, just zero matches | loosen the pattern or drop it |
| Line 1 starts with `[?9001h[?1004h` | conhost noise | ignore the escape run |
| One giant line, content cut at 2000 chars | a `\r`-driven progress bar | disable progress: `--tl:off`, `--console=plain`, `-B -ntp`, `--no-progress` |
| `Exit Code: 0` with `Timed Out: yes` | the job was cut off, success is unknown | read the output, find where it stopped |
| `Exit Code: 0` from a session you killed | signal-terminated reports 0 | rely on the `Timed Out` field and the log |
| `Cannot write to PTY '<id>' - session status is 'exited'` | process already gone | nothing to type into; kill and respawn |
| `Cleaned up: <id> (session retained for log access)` | cosmetic bug on an already-dead session | check status yourself |
| Notification `Last Line` is escape garbage | conhost noise | `pty_read` instead |
| `<pty_exited>` never arrives | `notifyOnExit` was false, **or** the spawn had no parent session id, **or** the host has no `ctx.session.prompt` (V2 pre-2.0). `cleanup: true` is **not** a cause: `onExit` still fires after the map entry is deleted, so the notification is still attempted | check `pty_list` for status |
| Dangling `killing` status | transient, between kill request and exit | re-read after a moment |
| Log lines missing from the start | buffer truncated from the front at 1M chars | narrow the pattern, or write to a file with shell redirection and read the file |

Two more things that will silently waste your time:

- **The V2 plugin does not clean up PTYs when the OpenCode session is deleted.** Under V2,
  sessions leak until killed. Under V1 they are cleaned up. If you are on V2, `pty_list` at the
  end of a task and clean up anything you left behind.
- **Sessions are process-global, not scoped to your chat.** Two opencode instances in the same
  OS user share nothing but the same runtime; within one instance every session is visible from
  every chat. `pty_list` may show sessions you did not create. Do not kill them.

---

## 10. Anti-patterns

Do not do these:

1. `pty_spawn` then a loop of `pty_read` to detect completion. Use `notifyOnExit: true` and
   wait. The plugin injects a reminder telling you to stop when you do this.
2. `pty_spawn` with `timeoutSeconds` on a dev server or watch mode. It will be killed mid-work
   and you will think the server crashed.
3. `pty_spawn` with `notifyOnExit: true` on a dev server. Every hot reload fires a notification.
4. Omitting `args` or `description`. Both are required; the tool call will be rejected.
5. Omitting `workdir` and assuming you landed in the project root. You did not.
6. Passing `&&`, `|`, `>`, or `*` as `args` elements and expecting a shell.
7. Spawning `npm`, `mvn`, `gradle`, `flutter`, `dart` bare on Windows.
8. Reading a whole chatty buffer into context. Use a pattern.
9. Re-reading the same offset because you expect new output. Use a pattern or a new offset.
10. `pty_kill` with `cleanup: false` and never cleaning up. Log buffers are 1M chars each.
11. Reporting the `<pty_exited>` `Last Line` as the outcome of a build.
12. Treating `Exit Code: 0` as success without checking `Timed Out`.
13. Running `dotnet restore` concurrently in several sessions. NuGet locks.
14. Building C++ when OpenCode's own environment lacks the MSVC toolchain, without initialising it
    inside the same command. If OpenCode was launched from a Developer Command Prompt you already
    have it and none of this applies.

---

## 11. Cleanup discipline

Every session you create is your responsibility.

- Finished, log no longer needed: `pty_kill { id, cleanup: true }`.
- Just stopped it and about to investigate: `pty_kill { id }` (keeps the log), investigate, then
  `pty_kill { id, cleanup: true }`.
- Task complete: `pty_list`, then clean up anything still marked `running`.
- 1M characters per session is real memory in the OpenCode process.

---

## 12. Environment variables and server options

| Name | Default | Effect |
| --- | --- | --- |
| `PTY_MAX_BUFFER_SIZE` | `1000000` | **Characters** retained per session (not lines). Buffer is trimmed from the front, mid-line |
| `PTY_WEB_PORT` | `0` (ephemeral) | port for the web UI server |
| `PTY_WEB_HOSTNAME` | `::1` | bind address for the web UI server |
| `PTY_RUNTIME_DIR` | per-user runtime dir | where the server publishes its bound origin |
| `PTY_TUI_DEBUG` | off | append a TUI event log; on by setting to any value other than unset, `""`, or `"0"` |

Note: there is **no** `PTY_MAX_BUFFER_LINES`. The knob is character-based. If you remember an
older `README.md` or an older `pty_read` tool description advertising `PTY_MAX_BUFFER_LINES` with
a 50000-line default, both were wrong and have been corrected; the code only ever read
`PTY_MAX_BUFFER_SIZE`.

V2 plugin options (in `opencode.json`):

```json
{
  "plugin": [
    {
      "package": "opencode-pty/v2",
      "options": { "port": 4200, "hostname": "127.0.0.1", "autostart": false }
    }
  ]
}
```

Set `hostname: "127.0.0.1"` on Windows if IPv6 loopback is unavailable on the machine.

Slash commands: `/pty-open-background-spy` opens the web UI in a browser, `/pty-show-server-url`
prints its URL. Neither is needed for normal tool use.

---

## 13. One-page template

```jsonc
// Bounded: build
{
  "command": "cmd",
  "args": ["/c", "npm run build"],
  "workdir": "C:\\repo",
  "env": { "NO_COLOR": "1", "CI": "1" },
  "title": "Build",
  "description": "Run the production TypeScript build",
  "notifyOnExit": true,
  "timeoutSeconds": 900
}

// Bounded: tests, failing run then inspect
{
  "command": "cmd",
  "args": ["/c", "dotnet test --tl:off -v q"],
  "workdir": "C:\\repo",
  "title": "Tests",
  "description": "Run the xUnit test suite",
  "notifyOnExit": true,
  "timeoutSeconds": 1800
}
// on <pty_exited> with a non-zero code:
//   pty_read { id, pattern: "error CS|Failed|Assert", ignoreCase: true, limit: 60 }

// Long-running: dev server
{
  "command": "cmd",
  "args": ["/c", "npm run dev"],
  "workdir": "C:\\repo",
  "title": "Vite",
  "description": "Run the Vite dev server for the web client",
  "notifyOnExit": false
}
// pty_read { id, limit: 60 } once, then work, then:
//   pty_kill { id, cleanup: true }

// Long-running: interactive Flutter
{
  "command": "cmd",
  "args": ["/c", "flutter run -d windows"],
  "workdir": "C:\\repo\\app",
  "title": "Flutter",
  "description": "Run the Flutter app on the Windows desktop",
  "notifyOnExit": false
}
// pty_write { id, data: "r" } to hot reload, "q" to quit
```
