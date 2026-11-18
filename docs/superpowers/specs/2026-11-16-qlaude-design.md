# qlaude — design (rev 2)

Date: 2026-11-16 · Status: REV-2, gate findings folded · Repo: `randomm/qlaude` (public; renamed from `claude-qwen` 2026-11-18)
Evidence: 4 cited research lanes (`/opt/data/cache/delegation/live/deleg_00528480/`) + 3
pre-build gate lanes builder/cold-reader/adversarial (`.../deleg_8d4c7732/`), all 2026-11-16.
Platform claims carry [lane-N] citations; anything not verified is marked [INFERENCE].

Ceremony note: this is a two-script + CI tool, not a system. Full arc42/C4/MADR structure
would be filler; the doc keeps intent/constraints/design/acceptance and skips the rest.

## 0. Terms

- `INSTALLDIR` = `${QLAUDE_INSTALL_DIR:-$HOME/.local/bin}`;
  `CONFDIR` = `${QLAUDE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/qlaude}`.
  These definitions are canonical; every other mention means exactly this.
- **effort** — Claude Code's reasoning-effort dial (`CLAUDE_CODE_EFFORT_LEVEL`); the value
  rides from the exported env into request shaping at the serving layer. vLLM accepts
  `low|medium|xhigh`; `high` is rejected by the server with its accepted list — the
  wizard maps user intent onto the vLLM enum.
- **classifier / auto mode** — Claude Code's auto permission mode asks a model call
  ("classifier") whether an action is safe instead of prompting the user. The two
  `CLAUDE_CODE_*_MODEL` exports make that call hit the user's own endpoint; unset or
  neutered (`CLAUDE_CODE_AUTO_MODE_SERVER=0`), auto mode degrades toward prompting.
- **CLT** — Apple Command Line Tools; `/usr/bin/python3` and `git` on a fresh Mac are
  shims that pop the CLT installer GUI unless CLT is installed.
- `QLAUDE_STUB=1` — set in CI/local stub runs; steps that cannot pass against a stub by
  nature (tool-use probe) print SKIP instead of PASS, and stub-only assertions activate.
- [lane-N] — the four cited research lanes; transcripts at the path in the header.
- `docs/superpowers/` — the spec-driven build convention's canonical home for design
  specs and implementation plans; treat as plain `docs/`.

## 1. Intent

`qlaude` is a command that gives a teammate working Claude Code against their own
vLLM (or any Anthropic-Messages-compatible) endpoint in minutes, with no env-var
literacy: one install line, an interview on first run, a self-test gauntlet, then
`qlaude` just works. It encodes everything `README.md` documents manually (env block,
context window, effort enum, classifier pins, behavior prompt) so the happy path is
scripted and every failure prints the fix instead of a stack trace.

Why now: the README proved the setup; now remove the friction. Bar (owner's standing
rule): very easy and low friction, or developers will not use it.

## 2. Goals

- G1: cold machine → working `qlaude` in one paste + one interview, no sudo, no env-var
  knowledge.
- G2: `qlaude doctor` reproduces the README's **four mechanically-checkable** cheat-sheet
  rows (path/auth, round-trip, tool parser, context/effort) as its 0–3 steps with the
  exit codes below; proxy-pollution and classifier rows appear as informational warnings
  (step 4), not hard checks.
- G3: identical code path in CI (stub endpoint) and on real endpoints; owner's manual
  matrix (Fedora, Ubuntu, macOS) and CI test the same functions.
- G4: the user's token never appears in git, shell history, **process listings (argv or
  environment of any process qlaude starts) except the exec'd `claude` child where it is
  required**, or qlaude's own output.
- G5: honest behavior when assumptions break: missing tools, no Keychain, wrong auth
  style, missing vLLM tool-call parser.

## 3. Non-goals / anti-goals

- Not a vLLM manager: qlaude never starts, configures, or inspects servers.
- No sudo, ever. No rc-file edits without a `yes` the user gave explicitly.
- No telemetry, no update pings. **Update = re-run the installer** (uv convention);
  there is no `qlaude update` subcommand.
- No multi-endpoint profiles in v1 (single endpoint per machine; revisit only on real need).
- Anti-goal: becoming the thing people must debug — if qlaude blocks a power user,
  `QLAUDE_*` overrides and plain `claude` with the README table must always bypass it.

## 4. Constraints (platform ground truth, cited)

- C1 — One dialect: macOS `#!/bin/sh` is Apple's frozen bash 3.2 ([lane-1]);
  Debian/Ubuntu `/bin/sh` is **dash**, which hard-fails `[[ ]]`, arrays, `source`,
  `function`, `echo -e`, `$'…'` (measured live, [lane-2]). All shipped scripts are strict
  POSIX sh, `shellcheck -s sh` clean, no bashisms. Policy: `set -u` everywhere; **no
  global `set -e`** in gauntlet functions — per-step explicit exit handling per §5.5.
- C2 — No `git` in the install path: on fresh Macs `git` is the CLT GUI shim ([lane-1]).
  Installer fetches raw files by curl. Same rule for `python3`: CI runners preinstall it,
  end-user Macs don't — no user-facing path may need python.
- C3 — macOS lacks `sha256sum`, `readlink -f`, `timeout`, `flock`, GNU `stat -c`,
  `install -D`; BSD variants or POSIX fallbacks only ([lane-1]). Network bounds come from
  `curl -m`; claude bounds from `--max-turns`. No `timeout(1)` anywhere.
- C4 — PATH: `~/.local/bin` is NOT on macOS default PATH ([lane-1]) and has
  non-login-shell holes on Linux ([lane-2]). Installer installs to `INSTALLDIR`, verifies
  PATH, prints the exact line to add, edits nothing itself; the launcher always execs
  `claude` by resolved absolute path. Consent-based `qlaude ensure-path` for users who
  want the edit (§5.7).
- C5 — curl-downloaded scripts get no quarantine xattr; `curl | sh` is not
  Gatekeeper-blocked ([lane-1]). Docs still lead with download-then-run; pipe version
  documented with the caveat (Sandstorm analysis, [lane-3]).
- C6 — Token ladder (lanes 1/2/4 + gate findings):
  - macOS → Keychain (amended 2026-11-18, real-run finding + noni
    wizard-input-picker-keychain-composite): `security add-generic-password -w`
    reads the secret via getpass **on /dev/tty, never the pipe** — with a controlling
    tty it blind-prompts "password data for new item" and Enter-Enter stores an EMPTY
    item with rc 0. So the Keychain is for **unattended (no-tty) runs only**: write with
    double-line stdin (`printf '%s\n%s\n' "$tok" "$tok" | security add-generic-password
    -U -a "$USER" -s qlaude -w`), token never as `-w <token>` argv (G4), **read-back
    equality is the sole success gate** (rc lies), any mismatch scrubs via
    `delete-generic-password` and degrades to the file with a printed note.
    **Interactive setup makes zero add/delete calls** and announces the 0600 file as the
    destination. `token_source` reports keychain only on a NON-EMPTY read-back.
    The old "no-prompt [INFERENCE]" is refuted; A7 still owns the locked-keychain and
    SSH/headless matrix.
  - Everywhere → `${CONFDIR}/config.env` at mode `0600`, the gh/docker plaintext-fallback
    model. Token exported only into the exec'd claude child.
  - All qlaude-issued curl calls that carry the token pass it via `curl -K -` with the
    config (incl. `header = ...`) on stdin — never `-H "Authorization: Bearer $TOKEN"`
    argv.
- C7 — Claude Code's sanctioned config surface (official docs, [lane-4]): exported env
  beats settings files. `ANTHROPIC_AUTH_TOKEN` (Bearer) vs `ANTHROPIC_API_KEY`
  (x-api-key + account-login flows) are **different mechanisms** — and the README's
  verified ground truth is that `ANTHROPIC_API_KEY` against vLLM starts Anthropic
  account-login and fails without an account, so bearer is the only wizard choice (§5.2).
  `claude -p` headless mode never prompts interactively — unpermitted tools are
  **auto-denied, not hangs** — and takes `--allowedTools` for scoped grants. Probe
  determinism: run probes under an isolated `HOME=$(mktemp -d)` so user
  `~/.claude.json`/settings cannot contaminate; `--bare` is [INFERENCE]-verified only —
  usable solely if T7's `claude --help` assert confirms it on the pinned version.
- C8 — CI is sanctioned: Anthropic productizes Claude Code in Actions
  (`claude-code-action`, [lane-3]); public repo → free macOS runners. Pin `macos-15`
  (macos-14 retired from the reference table, [lane-3] + verified
  github.blog/changelog 2026-10-01); heavy jobs ubuntu-only.
- C9 — CLI etiquette baseline ([lane-4], clig.dev/rustup/pipx/gh): prompts on stderr
  only, data on stdout; `NO_COLOR`/`TERM=dumb`/non-TTY → plain output; **no prompt ever
  on a non-TTY** — require `-y` + flags/env, else exit 1 with usage (never hang);
  idempotent re-runs; `--help` works via `sh -s -- --help`; env overrides `QLAUDE_*`.

## 5. Design

### 5.1 Repository layout (additions)

```
bin/qlaude              single-file POSIX-sh tool: launcher + setup + doctor + config
                        + ensure-path
install.sh              installer (curl-only, checksum-verified; §5.6)
install.sha256          sha256 over bin/qlaude + SYSTEM-PROMPT.md (tools/gen-checksum.sh
                        regenerates; CI lint fails on drift)
tools/gen-checksum.sh   checksum generator (POSIX sh)
tests/run_tests.sh      offline suite: everything against tests/stub_server.py
tests/stub_server.py    stdlib-only python3 stub (CI/dev only; never a user path)
.github/workflows/ci.yml
docs/superpowers/specs/2026-11-16-qlaude-design.md
docs/superpowers/plans/2026-11-16-qlaude-plan.md
README.md               gains Quickstart (≤ 5 lines) + uninstall block
```

### 5.2 Config — `${CONFDIR}/config.env`, mode 0600

`KEY=value` lines parsed with `read`/`case` — **never `eval`'d**. Precedence for every
key: flags > `QLAUDE_*` env > file > default. Keys:

| Key | Meaning | Default |
|---|---|---|
| QLAUDE_ENDPOINT | base URL, no trailing /v1 (stripped with a warning) | — required |
| QLAUDE_MODEL | served model name | — required |
| QLAUDE_AUTH | `bearer` → ANTHROPIC_AUTH_TOKEN · `api-key` → ANTHROPIC_API_KEY | bearer; **wizard offers bearer only** — `api-key` reachable via env/flag only, prints the README warning (account-login trap, C7), and doctor flags it on vLLM-shaped endpoints |
| QLAUDE_CONTEXT_TOKENS | → CLAUDE_CODE_MAX_CONTEXT_TOKENS | 262144 — wizard asks (shows default); `-y` runs that don't supply it get a prominent printed warning citing the README's max-model-len rule |
| QLAUDE_EFFORT | see §0 | medium |
| QLAUDE_CLAUDE_BIN | absolute path to claude | `command -v claude` at setup |
| QLAUDE_TOKEN | file fallback ONLY (keychain preferred on macOS) | — |

### 5.3 Launcher (default `qlaude [args…]`)

1. No config → exec `qlaude setup`.
2. Read config (never eval). Token: keychain first on macOS, else file (§4 C6 ladder).
3. **qlaude-always-wins**: export `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` (per
   QLAUDE_AUTH), `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL`
   (= QLAUDE_MODEL), `CLAUDE_CODE_AUTO_MODE_MODEL`, `CLAUDE_CODE_BG_CLASSIFIER_MODEL`
   (= QLAUDE_MODEL), `CLAUDE_CODE_EFFORT_LEVEL`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS` —
   unconditionally overriding any inherited values (predictability beats inheritance;
   the README's manual block remains the bypass). `qlaude config` lists which of these
   shadowed a pre-existing inherited export.
   Exception: if `CLAUDE_CODE_AUTO_MODE_SERVER=0` is present in the environment, print the
   README warning and unset it for the child (stale exports must not silently defeat the
   classifier pins).
4. If `${CONFDIR}/SYSTEM-PROMPT.md` missing/empty → one-line note, run without the append
   (never die). Else
   `exec "$QLAUDE_CLAUDE_BIN" --append-system-prompt-file "$CONFDIR/SYSTEM-PROMPT.md" "$@"`
   — `"$@"` verbatim (argument boundaries preserved; `"$*"` is a bug), quoted, exec'd.
5. Any config/keychain error → doctor-style message with the fix, exit 1.

### 5.4 Wizard `qlaude setup [-y] [--endpoint U] [--model M] [--auth A] [--context N] [--effort E] [--claude-bin P] [--token-stdin]`

- Interactive order (each item one question): claude present? (detect-then-offer official
  install, never silent) → endpoint → **token first** (`IFS= read -rs`, never echoed) →
  auth style (bearer only, §5.2) → model probe `GET {base}/v1/models` **with the auth
  header** (auth-enforcing vLLM answers too); list ids if reachable, else free text →
  context window (shows default) → effort → save (0600, atomic write: temp + mv) →
  **run gauntlet**, passing its exit code through.
- Every answer flag/env-able; non-TTY without complete inputs + `-y` → exit 1 with usage
  (never hang; C9). `-y` with everything supplied is fully non-TTY-safe by construction.
- Re-running setup with existing config previews current values, edits in place.
- Summary prints exactly what a README reader would reproduce manually (`qlaude config`).

### 5.5 Gauntlet (shared by setup tail and `qlaude doctor`)

| # | Step | Pass | Main failure → fix | Exit |
|---|---|---|---|---|
| 0 | prereqs: OS ∈ {Linux,Darwin}; curl; claude bin `--version`; `${CONFDIR}/SYSTEM-PROMPT.md` present + non-empty | all found | install claude via official channel (printed, offered, never silent) | 2 |
| 1 | `curl -m 15 -K -` (stdin config: url + `header = content-type: application/json`, `header = anthropic-version: 2023-06-01`, `header = Authorization: Bearer …` [token from stdin config, C6]; POST body `{"model":M,"max_tokens":8,"messages":[{"role":"user","content":"say OK"}]}` — the README verify-curl verbatim) | 200 + JSON `content[0].text` | 404 → trailing-/v1/path hint (auto-fix once **with printed notice**, re-test); 401/403 → print the flip-auth-style hint, never silently rewrite config | 3 |
| 2 | `claude -p "Reply with exactly: OK" --model M --max-turns 1` under isolated `HOME=$(mktemp -d)` (C7) | stdout contains OK | auth/login/env failure text surfaced verbatim | 4 |
| 3 | same isolated HOME + `claude -p "Use the Bash tool to run: echo QLAUDE_TOOL_OK" --max-turns 5 --allowedTools 'Bash(echo QLAUDE_TOOL_OK)'` — headless auto-denial means non-hang (C7); SKIP under `QLAUDE_STUB=1` | stdout contains QLAUDE_TOOL_OK | marker absent → README tool-call-parser row (server `--tool-call-parser`) | 5 |
| 4 | informational: classifier exports set; stale `CLAUDE_CODE_AUTO_MODE_SERVER=0`; proxy pollution (`HTTPS_PROXY` set + `NODE_USE_ENV_PROXY` unset → warn with README row) | warn-only | — | — |

Rules: ordered, stop on first hard fail (0–3); one line `PASS/FAIL/SKIP <step>: <cause → fix>`
per step; diagnostics to stderr; `NO_COLOR` honored; exit codes per table; token never
interpolated into printed strings and never in any argv qlaude spawns (§4 C6); `set -u`,
no `set -e` in this code.

### 5.6 Installer `install.sh`

- Fetch coordinates: `QLAUDE_BASE_URL` (default the repo raw URL) + `QLAUDE_REF` (default
  `main`) — CI points these at the PR commit so smoke tests the change, not main. Users
  pin tags by putting the tag in the URL (documented).
- Steps: OS check → `mkdir -p INSTALLDIR CONFDIR` → fetch `bin/qlaude`, `SYSTEM-PROMPT.md`,
  `install.sha256` (curl `--proto '=https' --tlsv1.2 -fL`) → verify sha256 over the two
  payloads (hasher ladder C3). **Honest scope: a same-origin checksum guards
  truncation/corruption, not the supply chain** — that is TLS + GitHub's auth on raw
  endpoints; documented as such, never oversold. → `chmod 755 bin/qlaude`, `chmod 600`
  config pieces → PATH check + guidance line (no rc edits, C4) → offer `qlaude setup` if TTY.
- Idempotent; re-run = update. `QLAUDE_INSTALL_DIR`/`QLAUDE_CONFIG_DIR` overrides. No
  QLAUDE_NO_MODIFY_PATH flag (consent-based §5.7 makes it a no-op — removed).
- Fresh-Mac safety: needs only `/bin/sh`, curl, and standard BSD tools (C2/C3).

### 5.7 `qlaude ensure-path [--dry-run]` and `qlaude config`

- `ensure-path`: picks the file by the user's interactive shell — basename of `$SHELL`:
  `zsh` → `~/.zprofile` on **both** OSes (covers zsh-on-Fedora); otherwise Darwin →
  `~/.zprofile`, Linux → `~/.profile`. Appends a `# qlaude PATH` marker-delimited block;
  refuses files whose marker block it didn't write; `--dry-run` prints the change, touches
  nothing; prints "open a new terminal" hint.
- `config`: resolved state — CONFDIR/INSTALLDIR paths, endpoint, model, auth style,
  context, effort, claude bin + version, token source (`keychain`/`file`/`unset`), plus the
  shadowed-inherited-exports list from §5.3. **Never the token value.**

### 5.8 CI (`.github/workflows/ci.yml`)

| Job | Runner | Content |
|---|---|---|
| lint | ubuntu-latest | `shellcheck -s sh` severity=style on install.sh, bin/qlaude, tools/, tests shell; `dash -n` same; regenerate install.sha256 → **fail on drift**; public-repo hygiene grep |
| smoke | ubuntu-latest + macos-15 (pinned) | npm i -g @anthropic-ai/claude-code; capture `claude --help` (assert `--allowedTools` present; `--bare` used only if listed, else isolated-HOME path per C7); start stub with `QLAUDE_CI_TOKEN=qlaude-ci-dummy-token-8f31`; installer with QLAUDE_BASE_URL/REF→PR commit, INSTALL/CONFIG_DIR→temp; `qlaude setup -y` (all inputs via env) → `qlaude doctor` exit 0 |
| dash | ubuntu-latest | **fresh chain re-run under dash**: `dash -c 'sh install.sh && sh bin/qlaude setup -y … && sh bin/qlaude doctor'` in a clean HOME |
| negative | ubuntu-latest | doctor step 1 against the enforcing stub with the token removed/wrong → must FAIL (exit 3) with the auth hint — proves token plumbing, not stub gullibility |

Stub contract (shapes verified this session): `POST /v1/messages` → 200
`{"content":[{"type":"text","text":"<echo of last user text>"}],"stop_reason":"end_turn","model":<requested>}`;
`GET /v1/models` → OpenAI-shape list. **Stub enforces auth**: both routes require the
configured dummy token in the style `QLAUDE_AUTH` dictates and the `anthropic-version`
header; missing/wrong → 401. Step 3 prints SKIP under `QLAUDE_STUB=1` (a tool probe
can't pass against a stub by nature — SKIP is honest, faked PASS is not).

## 6. Security posture

- Token: keychain (macOS, headless runs only, **stdin write + read-back gate**, C6) or 0600 file; exported only into the claude
  child; never logged, never in `doctor`/`config`, never in **any argv** (`security` and
  `curl` both take it via stdin); never in repo (CI uses the distinctive dummy
  `qlaude-ci-dummy-token-8f31`). `set -x` in launcher code paths is banned (traces leak
  the env).
- Config parsed as data; no eval; atomic writes (temp+mv) to survive partial writes.
- Corrupted config (non-KEY=value lines) → step-1-style fix message pointing at
  `qlaude setup`, not a crash.
- HTTPS-only fetches; checksum before exec (scope honest per §5.6).
- Writes confined to INSTALLDIR + CONFDIR (+ the consented marker block via ensure-path);
  anything else needs an explicit flag pointing elsewhere.
- Uninstall (documented in README, 3 lines, no subcommand): `rm "$INSTALLDIR/qlaude"`,
  `rm -rf "$CONFDIR"`, `security delete-generic-password -s qlaude` (last one macOS only).

## 7. Acceptance criteria

- A1: `shellcheck -s sh` (severity=style) exits 0 on install.sh, bin/qlaude, tools/,
  tests shell; `dash -n` exits 0 on all of them.
- A2: ubuntu-latest + macos-15: installer → `qlaude setup -y` (env inputs) →
  `qlaude doctor` exits 0 against the enforcing stub. Negative job: remove token →
  doctor exits 3.
- A3: fresh install→setup→doctor chain re-executed under `dash -c` in a clean HOME
  passes (the whole chain, not per-script `dash -n`).
- A4: `qlaude config` and all doctor output contain no occurrence of
  `qlaude-ci-dummy-token-8f31` (distinctive by design); a `ps` sampler run during step 1
  finds the token in no argv.
- A5: missing config → wizard starts; with config, `qlaude -- 'two words'` reaches the
  child as two separate argv entries (asserted via stand-in bin) — the `"$@"` contract.
- A6: mechanical — the launcher's exported-var list (extracted from its export
  statements) is a subset of the README env table's first column, checked by grep in CI.
- A7: owner-run manual matrix, results posted as a repo issue: on Fedora, Ubuntu LTS,
  macOS — the full chain against a **real** vLLM endpoint: install (download-then-run and
  `curl | sh`), `qlaude setup` (interactive once, `-y` once), `qlaude doctor` exit 0, real
  `qlaude` session with a file edit. On macOS additionally: keychain round-trip including
  a **locked-keychain and an SSH/headless run** (settles C6's [INFERENCE]).

## 8. Risks & honest gaps

| Risk | Mitigation |
|---|---|
| Keychain no-prompt claim is [INFERENCE] | A7 Mac check incl. locked/SSH; ladder degrades to file with a note meanwhile |
| `--bare` may not exist on pinned claude | probes need only isolated HOME + --max-turns; --bare optional behind T7 `claude --help` assert |
| Stub ≠ real endpoint fidelity | A7 is the truth test; CI's negative job covers token plumbing |
| zsh non-interactive contexts never see rc PATH | documented; absolute-path exec makes it moot for the tool itself |
| Effort/context defaults drift upstream | doctor surfaces server 400 text verbatim; README links stay authoritative |
| `claude -p` headless behaviour changes upstream | version pin in CI + T7 help-capture assert |

## 9. Decisions (owner + gate-driven agent calls; veto-able)

- RESOLVED (owner): public repo — free macOS CI, unauthenticated install; owner runs the
  A7 matrix; agents fanned out wherever parallel.
- RESOLVED (research/gates): POSIX dialect forced from both directions; no git/python on
  user paths; keychain-first with stdin write; download-then-run led; macos-15 pinned;
  clig/pipx/rustup/gh etiquette; **bearer-only wizard** (api-key env-only + warning,
  because README ground truth says api-key style starts account-login and fails on
  vLLM); token-before-model-probe; **qlaude-always-wins** exports with shadow reporting;
  probes on isolated HOME; probes carry `--allowedTools 'Bash(echo QLAUDE_TOOL_OK)'`
  (scoped, headless auto-denial makes non-hang a documented property); checksum scope
  stated honestly + CI drift-lint; no update subcommand — re-run installer; ensure-path
  branches on `$SHELL`; distinctive CI token.

## 10. After this works (not v1)

Profiles (`qlaude use <name>`) when someone runs two endpoints; `--json` doctor for fleet
checks; a Homebrew tap; shell completions — each after real demand.
