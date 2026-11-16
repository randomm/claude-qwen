# qlaude — design

Date: 2026-11-16 · Status: DRAFT for owner approval · Repo: `randomm/claude-qwen` (public)
Evidence base: 4 cited research lanes (2026-11-16, b200/qwen3.8-flash-next), transcripts
at `/opt/data/cache/delegation/live/deleg_00528480/`, plus this session's verified
README facts. Platform claims below carry lane citations; anything not verified is
marked [INFERENCE].

Ceremony note: this is a two-script + CI tool, not a system. Full arc42/C4/MADR
structure would be filler; the doc keeps intent/constraints/design/acceptance and
skips the rest deliberately.

## 1. Intent

`qlaude` is a command that gives a teammate working Claude Code against their own
vLLM (or any Anthropic-Messages-compatible) endpoint in minutes, with no
env-var literacy: one install line, an interview on first run, a self-test gauntlet,
then `qlaude` just works. It encodes everything `README.md` documents manually
(env block, context window, effort enum, classifier pins, behavior prompt) so the
happy path is scripted and every failure prints the fix instead of a stack trace.

Why now: the README proved the setup; now remove the friction. Bar (owner's standing
rule): very easy and low friction, or developers will not use it.

## 2. Goals

- G1: cold machine → working `qlaude` in one paste + one interview, no sudo, no
  env-var knowledge.
- G2: `qlaude doctor` reproduces the README's verify steps exactly; each failure
  names its cause and fix (the README's cheat-sheet rows become exit codes).
- G3: identical code path in CI (stub endpoint) and on real endpoints; owner's
  manual matrix (Fedora, Ubuntu, macOS) and CI test the same functions.
- G4: the user's token never appears in git, shell history, process listings beyond
  the child env, or qlaude's own output.
- G5: honest behavior when assumptions break: missing tools, no Keychain, wrong
  auth style, missing vLLM tool-call parser.

## 3. Non-goals / anti-goals

- Not a vLLM manager: qlaude never starts, configures, or inspects servers.
- No sudo, ever. No rc-file edits without a `yes` the user gave explicitly.
- No telemetry, no update pings; `qlaude update` is user-invoked only.
- No multi-endpoint profiles in v1 (single endpoint per machine; revisit only on
  real need).
- Anti-goal: becoming the thing people must debug — if qlaude blocks a power user,
  `QLAUDE_*` overrides and plain `claude` with the README table must always bypass it.

## 4. Constraints (platform ground truth, cited)

- C1 — One dialect: macOS `#!/bin/sh` is Apple's frozen bash 3.2 (GPLv2 freeze,
  [lane-1]); Debian/Ubuntu `/bin/sh` is **dash**, which hard-fails `[[ ]]`, arrays,
  `source`, `function`, `echo -e`, `$'…'` (measured live, [lane-2]). All shipped
  scripts are strict POSIX sh, `shellcheck -s sh` clean, no bashisms.
- C2 — No `git` in the install path: on fresh Macs `git` is the xcode-select GUI
  shim ([lane-1]). Installer fetches raw files by curl.
- C3 — macOS lacks `sha256sum`, `readlink -f`, `timeout`, `flock`, GNU `stat -c`,
  `install -D`; BSD variants or POSIX fallbacks only ([lane-1]). Network bounds come
  from `curl -m`; claude bounds from `--max-turns`. No `timeout(1)` anywhere.
- C4 — PATH: `~/.local/bin` is NOT on macOS default PATH ([lane-1]) and has
  non-login-shell holes on Linux ([lane-2]). The installer installs to
  `${QLAUDE_INSTALL_DIR:-$HOME/.local/bin}`, verifies PATH, prints the exact line to
  add (`~/.zprofile` macOS / `~/.profile` Linux), and the launcher always execs
  `claude` by resolved absolute path. `qlaude ensure-path` exists for users who want
  the edit done, guarded by marker comments and `--dry-run` (pipx ensurepath model,
  [lane-4]).
- C5 — curl-downloaded scripts get no quarantine xattr; `curl | sh` is not
  Gatekeeper-blocked ([lane-1]). Still: docs recommend download-then-run; pipe
  version documented with that caveat (Sandstorm analysis, [lane-3]).
- C6 — Token ladder (lanes 1/2/4): macOS → Keychain via
  `security add-generic-password -U -a "$USER" -s qlaude -w …` (no prompt fatigue:
  the ACL actor is Apple's own `/usr/bin/security`, the model gh itself uses);
  everywhere → `~/.config/qlaude/config.env` at `0600`, consistent with gh/docker
  plaintext fallbacks. Token is exported only into the `claude` child process.
- C7 — Claude Code's sanctioned config surface (official docs, [lane-4]): exported
  env beats settings files; `ANTHROPIC_AUTH_TOKEN` (Bearer) vs `ANTHROPIC_API_KEY`
  (x-api-key) have different semantics → auth style is a wizard question.
  `claude -p` exit codes + stdout are scriptable; `--bare` skips auto-discovery for
  deterministic gauntlet runs; `--append-system-prompt-file` keeps the default prompt.
- C8 — CI is sanctioned: Anthropic productizes Claude Code in Actions
  (`claude-code-action`, [lane-3]); public repo → free macOS runners. Pin
  `macos-15` explicitly (macos-14 is retired from the reference table, [lane-3]);
  heavy jobs ubuntu-only.
- C9 — CLI etiquette baseline ([lane-4], clig.dev/rustup/pipx/gh): prompts on
  stderr only, data on stdout; `NO_COLOR`/`TERM=dumb`/non-TTY → plain output;
  no prompt ever on a non-TTY (require `-y` + flags/env); idempotent re-runs;
  `--help` via `sh -s -- --help`; env overrides named `QLAUDE_*`.

## 5. Design

### 5.1 Repository layout (additions)

```
bin/qlaude              single-file POSIX-sh tool: launcher + setup + doctor + config
install.sh              installer: fetches bin/qlaude + SYSTEM-PROMPT.md, verifies
                        checksum, installs to ~/.local/bin, prints PATH guidance
tests/stub_server.py    stdlib-only python3 stub serving Anthropic-shape
                        POST /v1/messages (CI + local dev; NOT part of user paths)
.github/workflows/ci.yml
docs/superpowers/specs/2026-11-16-qlaude-design.md
docs/superpowers/plans/2026-11-16-qlaude-plan.md
README.md               gains Quickstart (≤ 5 lines) pointing at qlaude
```

### 5.2 Config

Location `${XDG_CONFIG_HOME:-$HOME/.config}/qlaude/`:

```
config.env   # KEY=value, mode 0600, plain `KEY=value` only — the launcher
             # parses with read/case, NEVER `eval`s file contents
SYSTEM-PROMPT.md   # copied at install; behavior addendum (exists today)
```

Keys (all `QLAUDE_`-prefixed; `qlaude setup` writes them; env vars of the same
name override at read time — precedence flags > env > file > default):

| Key | Meaning | Default |
|---|---|---|
| QLAUDE_ENDPOINT | base URL, no trailing /v1 (stripped with a warning) | — required |
| QLAUDE_MODEL | served model name | — required |
| QLAUDE_AUTH | `bearer` → ANTHROPIC_AUTH_TOKEN · `api-key` → ANTHROPIC_API_KEY | bearer |
| QLAUDE_CONTEXT_TOKENS | → CLAUDE_CODE_MAX_CONTEXT_TOKENS | 262144 (wizard asks) |
| QLAUDE_EFFORT | low\|medium\|xhigh (vLLM enum; `high` rejected with explanation) | medium |
| QLAUDE_CLAUDE_BIN | absolute path to claude | `command -v claude` at setup |
| QLAUDE_TOKEN | file fallback ONLY (keychain preferred on macOS) | — |

### 5.3 Launcher (default `qlaude [args…]`)

1. No config → exec `qlaude setup`.
2. Read config (never eval). Token: keychain first on macOS, else file.
3. Export: `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`|`ANTHROPIC_API_KEY` (per
   QLAUDE_AUTH), `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL`
   (= QLAUDE_MODEL), `CLAUDE_CODE_AUTO_MODE_MODEL`,
   `CLAUDE_CODE_BG_CLASSIFIER_MODEL` (= QLAUDE_MODEL),
   `CLAUDE_CODE_EFFORT_LEVEL`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS`.
4. `exec "$QLAUDE_CLAUDE_BIN" --append-system-prompt-file "$CONFDIR/SYSTEM-PROMPT.md" "$@"`
   — quoted, exec (no extra process), `"$*"` passed through untouched.
5. Any config/keychain error → doctor-style message with the fix, exit 1.

### 5.4 Wizard `qlaude setup [-y] [--endpoint U] [--model M] [--auth A] [--context N] [--effort E] [--claude-bin P] [--token-stdin]`

- Interactive order: claude present? → endpoint → model (probe via
  `GET {base}/v1/models`, present ids if reachable, accept free text) → auth style →
  token (`read -s`, never echoed) → context window → effort → save → **run gauntlet**.
- Every answer flag/env-able; non-TTY without complete inputs + `-y` → exit 1 with
  usage text (never hang; clig rule C9).
- Re-running setup with existing config previews current values, edits in place.
- Trailing summary prints exactly what a README reader would need to reproduce it
  manually (`qlaude config`).

### 5.5 Gauntlet (shared by setup tail and `qlaude doctor`)

| # | Step | Pass | Main failure → fix | Exit |
|---|---|---|---|---|
| 0 | prereqs: OS, curl, claude bin (`--version`) | all found | install claude via official channel (printed, offered, never silent) | 2 |
| 1 | `curl -m 15 POST {base}/v1/messages` say-OK | 200 + content JSON | 404 → trailing-`/v1`/path hint (auto-fix once, re-test); 401/403 → flip auth style | 3 |
| 2 | `claude -p "Reply with exactly: OK" --max-turns 1` | stdout contains OK | auth/login/env failure text surfaced verbatim | 4 |
| 3 | tool probe: `claude -p "Use the Bash tool to run: echo QLAUDE_TOOL_OK" --max-turns 5` | stdout contains marker | "writes files but nothing happens" → server `--tool-call-parser` row from README | 5 |
| 4 | classifier check: auto-mode vars set, endpoint reachable (informational) | set | warn only (auto mode degrades, doesn't break) | — |

Rules: steps run in order, stop on first hard fail (0–3), each prints
`PASS/FAIL/SKIP <step>: <one-line cause → fix>`; prompts/diagnostics to stderr;
`NO_COLOR` honored; exit codes as table; `--bare` on all `-p` probes; token never
in messages.

### 5.6 Installer `install.sh`

- `curl -fsSL …/install.sh -o install.sh && sh install.sh` (documented) or
  `curl -fsSL … | sh` (works — C5; caveat documented).
- Steps: OS check → mkdir -p install dir + config dir → fetch `bin/qlaude` and
  `SYSTEM-PROMPT.md` (curl, `--proto '=https' --tlsv1.2`) → checksum verify
  (fetch repo-pinned `install.sha256`; hasher resolved `sha256sum → shasum -a 256 →
  openssl dgst -sha256`) → `chmod 755` (no `install -D`, C3) → PATH check + guidance
  line (no rc edits, C4) → offer `qlaude setup` if TTY.
- Idempotent; `QLAUDE_INSTALL_DIR`/`QLAUDE_CONFIG_DIR` overrides;
  `QLAUDE_NO_MODIFY_PATH=1` implied by default (flag kept for familiarity).
- Update story v1: re-run the installer (uv convention). No silent updates.

### 5.7 `qlaude ensure-path [--dry-run]` and `qlaude config`

- `ensure-path`: appends a marker-delimited block (`# qlaude PATH`) to `~/.zprofile`
  (Darwin) / `~/.profile` (Linux); refuses to modify files whose block it didn't
  write (pipx rule); `--dry-run` prints what would change; prints "open a new
  terminal" hint.
- `config`: prints resolved state — config path, endpoint, model, auth style,
  context, effort, claude bin + version, token source (`keychain`/`file`/`unset`),
  never the token itself.

### 5.8 CI (`.github/workflows/ci.yml`)

| Job | Runner | Content |
|---|---|---|
| lint | ubuntu-latest | `shellcheck -s sh` (severity style) on install.sh, bin/qlaude; dash available → run `dash -n` too |
| smoke | ubuntu-latest + macos-15 (pinned) | npm i -g @anthropic-ai/claude-code; start `tests/stub_server.py` (Anthropic-shape /v1/messages + /v1/models); run installer into `$RUNNER_TEMP/.local/bin` (Q…_INSTALL_DIR overrides, NO_MODIFY_PATH); `qlaude setup -y` against stub; `qlaude doctor` → exit 0 |
| dash | ubuntu-latest | installer + doctor executed via `dash -c` to prove /bin/sh safety |

Stub contract (from this session's verified curl responses):
`POST /v1/messages` → 200 `{"content":[{"type":"text","text":"…echo of last user
text…"}],"stop_reason":"end_turn","model":<requested>}`; `GET /v1/models` →
OpenAI-shape list. Step 3 (tool probe) against the stub may legitimately FAIL
(claude will actually invoke the tool; stub never sees tools) — CI asserts steps
0–2 pass and treats 3 as SKIP when `QLAUDE_STUB=1`.

## 6. Security posture

- Token: keychain (macOS) or 0600 file; exported only into the claude child; never
  logged, never in `doctor`/`config` output, never in repo (CI uses dummy `stub` value).
- Config parsing without eval (no code execution from config file).
- HTTPS-only fetches (`--proto '=https' --tlsv1.2`), checksum verify before exec,
  download-then-run documented first.
- No git on the install path (no xcode-select trap, no credential prompts).

## 7. Acceptance criteria (each a CI/CLI-verifiable statement)

- A1: `shellcheck -s sh` exits 0 (severity=style) on `install.sh` and `bin/qlaude`.
- A2: On Ubuntu CI and macOS-15 CI: installer (non-interactive) → `qlaude setup -y`
  (env-supplied inputs) → `qlaude doctor` exits 0 against stub.
- A3: Same flow passes when run under `dash` explicitly on ubuntu.
- A4: `qlaude config` output contains no substring matching the token value.
- A5: `qlaude` with missing config launches the wizard; with config, execs claude
  (asserted in CI by `claude --version` passthrough smoke).
- A6: README quickstart ≤ 5 lines, copy-pasteable, matches README manual table.
- A7: Owner's manual matrix (Fedora, Ubuntu, macOS) against a real endpoint passes —
  this is the only test against non-stub truth; CI can't replace it.

## 8. Risks & honest gaps

| Risk | Mitigation |
|---|---|
| Keychain ACL quirks on a machine (ad-hoc contexts) | fallback ladder is automatic; doctor reports token source |
| Stub ≠ real endpoint fidelity (steps 1–2 only) | A7 manual matrix; README already proves the real path |
| zsh non-interactive contexts never see rc PATH | documented; absolute-path exec makes it moot for the tool itself |
| python3 on fresh Macs is a CLT shim | stub is CI/dev-only, never a user path |
| Effort/context defaults drift from vLLM releases | doctor's 400-parsing surfaces server's accepted list verbatim; README links stay authoritative |
| `claude -p` behavior changes upstream | doctor fixes messages from observed strings; version pin in CI |

## 9. Decisions (owner calls + agent calls)

- RESOLVED (owner, 2026-11-16): repo public — free macOS CI, unauthenticated
  install; owner runs manual matrix on Fedora/Ubuntu/macOS; agents fanned out
  wherever parallel.
- RESOLVED (research): install never requires git (lane 1); POSIX-sh dialect
  forced from both directions (lanes 1+2); keychain-first token with 0600 file
  fallback (lanes 1/2); download-then-run documented as the careful path (lane 3);
  macos-15 pinned (lane 3); clig/pipx/rustup/gh conventions adopted (lane 4).
- RESOLVED (agent calls, veto-able): single endpoint v1; rc files edited only via
  `ensure-path` consent; `claude` install detected-and-offered never silent; gauntlet
  auto-runs at setup tail; auth style a wizard question (two real semantics);
  `qlaude update` = re-run installer in v1.

## 10. After this works (one paragraph each, NOT v1)

- Profiles: `qlaude use <name>` + per-endpoint configs — build when someone runs
  two endpoints.
- `--json` for doctor (fleet checks), a Homebrew tap, and shell completions
  (zsh/bash) — each after real demand.
