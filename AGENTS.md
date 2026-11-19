# AGENTS.md — qlaude

Rules for AI agents working in this repo. Humans: the product is `README.md`;
contributing context lives there and in the spec. This file is for agents.

**Authoritative sources:** the newest `qlaude-design` spec under
`docs/superpowers/specs/` and its aligned plan under `docs/superpowers/plans/`
own the *what*; this file owns the *never-break rules and how to work here*.
On conflict, the spec wins — but say so instead of silently diverging.

**Sync note:** when you change behavior that a section here describes, update
this file in the same commit. Never let a rule here describe code you just
changed away.

**Static-file declaration:** this file states permanent rules only. Nothing in
it may record dates, version numbers, progress, or any fact that ages —
mutable facts live in their canonical homes (README, spec, CI pins) and this
file *points* at them, never restates them. A PR that adds a dated or versioned
claim here is wrong by construction.

## 0. Prime directive

The verified claims (README summary, `docs/status.md` detail) **are** the product. Every claim about how Claude
Code or vLLM behaves was verified against a live upstream and is kept
verifiable, or it is removed. When truth and a claim conflict, delete the
claim — never defend it. Second law: qlaude must never become the thing people
must debug (§5).

## 1. Pre-Push Quality Gates (BLOCKING)

All of these pass locally before any push. CI runs the same set — **CI is for
verification, not discovery.**

- `shellcheck -s sh --severity=style` exits 0 on `bin/qlaude`, `install.sh`,
  `tools/*`, `tests/*.sh` (spec A1).
- `dash -n` exits 0 on every shipped shell script (spec A1).
- `tests/run_tests.sh` exits 0 (starts the auth-enforcing stub, runs all
  suites; the whole chain also re-runs under `dash -c` in a clean HOME — A3).
- Checksum current: regenerated `install.sha256` (via `tools/gen-checksum.sh`)
  matches the committed one — CI's checksum-drift step is a gate, not trivia.
- Mechanical export check: launcher exported-var list ⊆ docs/environment.md
  table first column (A6, grep).
- Hygiene grep clean over the repo **and git history** (§18) before any push
  to the public remote.

Banned escapes: `--no-verify`, disabling or weakening a check to make it pass,
`# noqa`-style suppressions without a written justification, "CI will catch
it", follow-up fix commits for gate misses. If a gate script is missing or
broken, that is a bug to fix first — never a bypass.

## 2. Project invariants (load-bearing; each maps to a spec constraint)

- **I1 — One dialect.** Every shipped script is strict POSIX sh, no bashisms
  (`[[ ]]`, arrays, `source`, `function`, `echo -e`, `$'…'` are out). `set -u`
  everywhere; **no global `set -e`** in gauntlet functions — explicit per-step
  exit handling (spec C1, §5.5).
- **I2 — No `git`, no `python` on any user-facing path.** CI may use them;
  end-user machines may not have them (spec C2).
- **I3 — No GNU-only tools** (`sha256sum`, `readlink -f`, `timeout`, `flock`,
  GNU `stat -c`, `install -D`). BSD or POSIX fallbacks only; time bounds via
  `curl -m` and `--max-turns`, never `timeout(1)` (spec C3).
- **I4 — The launcher always execs `claude` by resolved absolute path**, and
  passes arguments verbatim: `exec … "$@"` is the argv contract (spec C4, A5).
- **I5 — Config is parsed as data. No `eval`, ever** (grep-enforced).
  Corrupted config yields a fix message pointing at `qlaude setup`, not a
  crash.
- **I6 — `SYSTEM-PROMPT.md` is append-only**, and it is inside the install
  checksum: touching it or `bin/qlaude` requires regenerating `install.sha256`
  in the same commit.
- **I7 — One function per gauntlet step**, shared by `setup`, `doctor` and CI
  so all three run identical code. No parallel copies of a step.

## 3. The contract (wire and token)

The unforgivable-mistake section. Read before touching the launcher, wizard,
gauntlet, or any README claim about the wire.

- **Base URL never ends in `/v1`.** Claude Code appends `/v1/messages` itself;
  a `/v1`-suffixed base yields `/v1/v1/messages` → 404 → the CLI's generic
  "issue with the selected model" wrapper that masks the real cause. The
  gauntlet's step-1 `/v1` hint exists because of this.
- **Unrecognized model IDs get an assumed context window** (recent builds:
  1M), never the server's real one — compaction then fires at the wrong
  threshold. The context-window guidance in docs/how-it-works.md is canonical; keep it true.
- **Bearer is the only wizard path.** `ANTHROPIC_API_KEY` against vLLM starts
  Anthropic account-login and fails without an account; the api-key style is
  env-only with a warning. Exported names follow the docs/environment.md table (A6).
- **The token never appears in argv, logs, or printed output.** macOS keychain
  writes pipe it on stdin (`security … -w` with stdin, never `-w <token>`);
  qlaude-issued auth calls use `curl -K -` with the header in the stdin
  config. It is exported only into the exec'd `claude` child. `set -x` is
  banned in launcher code paths — traces leak the environment.
- **Keychain-first on macOS, never a hard fail:** locked/odd keychain degrades
  to the 0600 `${CONFDIR}/config.env` file with a printed note.
- **Probes are deterministic:** isolated `HOME=$(mktemp -d)`, `--max-turns`,
  scoped `--allowedTools 'Bash(echo QLAUDE_TOOL_OK)'`. `--bare` may be used
  only if the pinned claude's `--help` assert (T7) lists it.

## 4. Security posture & blast radius

- Atomic writes (temp+mv) everywhere; modes 0600 on config, 0755 on executables.
- Writes confined to `INSTALLDIR` + `CONFDIR` + the consented `ensure-path`
  marker block; anything else needs an explicit flag pointing elsewhere.
  Never touch rc files without consent; `ensure-path` refuses foreign marker
  blocks.
- HTTPS-only fetches; checksum before exec, with the scope stated honestly in
  comments (CI drift-lint keeps the claim matching the code).
- No telemetry, no update pings, no secrets in workflows; artifacts must never
  contain even the CI dummy token. **Update = re-run the installer** — there
  is no `qlaude update`.
- No prompts on a non-TTY, ever: require `-y` + flags/env or exit 1 with
  usage. Prompts go to stderr; stdout carries data only.

## 5. Scope & anti-scope (what this repo is NOT)

Permanent anti-goals — re-proposing any of them is a review rejection:

- Not a vLLM manager: never starts, configures, or inspects servers.
- No `sudo`, ever. No rc-file edits without an explicit `yes`.
- No multi-endpoint profiles (`qlaude use <name>`) in v1.
- No `qlaude update` subcommand (§4).
- **Never become the thing people must debug:** `QLAUDE_*` overrides and plain
  `claude` with the docs/environment.md table must always bypass qlaude. Any feature that
  can block a power user is a defect.

## 6. Repo layout & change surfaces

| Path | Role |
|------|------|
| `bin/qlaude` | THE tool: single-file POSIX-sh launcher + setup + doctor + config + ensure-path |
| `install.sh` | curl-fetched installer (no git, no python — I2) |
| `install.sha256` | generated, never hand-edited (I6) |
| `tools/` | dev-side helpers (`gen-checksum.sh`, …) — not user-facing |
| `tests/` | `run_tests.sh` entry point + auth-enforcing `stub_server.py` |
| `.github/workflows/ci.yml` | the gates, mirrored; holds the version pins |
| `README.md` | public entry point: what it is + quickstart, nothing else canonical |
| `SYSTEM-PROMPT.md` | append-only behavior addendum (I6) |
| `docs/superpowers/specs/` `plans/` | design authority (read-only for agents; new spec revision = new file) |

Two change surfaces: **the tool** (`bin/`, `install.sh` — gates + review
discipline) and **the prose** (`README.md`, `SYSTEM-PROMPT.md` — same gates
where applicable, plus §15). Specs and plans are not edited in PRs.

## 7. Testing standards

- **Stub the world.** Tests never touch real endpoints, networks, Anthropic,
  or money. `tests/stub_server.py` speaks only wire shapes verified against
  the live upstream and **enforces auth** — a stub that accepts anything is
  not a test.
- TDD preferred: write the failing assertion first, watch it red, implement.
- Every bug fix ships its regression test in the same PR.
- CI's negative jobs (token removed → doctor exit 3; corrupted payload →
  install aborts) are first-class deliverables, not extras.

## 8. Claims are proven by a check

**A guard that has never failed is not a guard.** Every safety or behavior
claim needs a check that would go red if it broke: break the guard on purpose,
watch it go red, revert. Never weaken a check to make it pass — fix the code
or delete the claim (§0). The stub's auth enforcement, the `ps` token sampler,
and the A6 grep are the house examples.

## 9. Code review & review budget

One full review, one fix wave, one re-review — then merge or escalate. HIGH+
findings block merge. Every PR description names the invariant (§2/§3/§4) it
touches and the check that proves it still holds. "Already on main" is never
an argument.

## 10. Minimalist engineering & file size

- **Every line of code is a liability.** Removal is a feature. One obvious way
  to do a thing; no speculative generality, no dead code, no TODOs.
- **Pre-creation challenge (mandatory):** before adding a file, function, flag
  or env var — what breaks if this does not exist? Unable to answer ⇒ do not
  create it.
- Line budgets are enforced by the gate scripts (single source for the
  numbers); ratchet-only: a file may shrink past its budget, never grow back.
  `bin/qlaude` staying a single file is a deliberate shape, not an accident.

## 11. Code style & conventions

- POSIX sh; `shellcheck -s sh` clean at severity style; `dash -n` clean.
- Always `IFS= read -r` (`-rs` for secrets).
- Exit-code constants centralized once, referenced everywhere.
- CLI etiquette: prompts on stderr only, data on stdout; `NO_COLOR`,
  `TERM=dumb`, non-TTY ⇒ plain output; idempotent re-runs; `--help` works via
  `sh -s -- --help`; env overrides are `QLAUDE_*` only.
- Comments explain *why* and cite the spec constraint (C1–C9) or lane evidence
  a line exists.

## 12. Current-docs protocol (Context7)

Before coding or documenting against these surfaces, look up **current**
official documentation (Context7 works from this host, keyless; or the
upstream docs directly) — never code from memory of older versions:

1. Claude Code CLI — flags, `-p` semantics, settings precedence, env vars.
2. vLLM — the Anthropic Messages route (`/v1/messages`) and its requirements.
3. macOS `security`/keychain — the tools' actual, current CLI behavior.
4. GitHub Actions — runner images and availability (the `macos-15` pin lives in
   `ci.yml`; never copy it into prose).

Escape: pure-internal POSIX changes (renames, comments, test tweaks) may skip
the lookup.

## 13. Upstream versions & drift

This file holds no version numbers, ever. All version claims and pins live in
their canonical homes: `ci.yml` pins are the **single version source of
truth** for CI-tested upstreams; the README carries verified-behavior claims.
Before adding or changing any statement about how an upstream behaves,
re-verify against the live upstream and cite the source in the PR. When an
upstream changes behavior, fix the README claim in the same PR — a stale
verified-claim is a bug with a severity, not housekeeping.

## 14. Common pitfalls (facts that bite)

- The `/v1/v1/messages` 404 and its misleading "issue with the selected model"
  wrapper — check the base URL before believing any model/auth theory.
- Assumed-1M context on unrecognized model IDs → compaction at the wrong
  threshold on smaller servers.
- `ANTHROPIC_API_KEY` against vLLM starts account-login and fails (§3).
- `/bin/sh` is dash on Debian/Ubuntu and frozen bash 3.2 on macOS — test
  against dash, not your login shell.
- `~/.local/bin` is not on macOS default PATH and has non-login-shell holes on
  Linux — verify PATH, print the line, edit nothing (spec C4).
- On fresh Macs `git` is the CLT GUI shim — never put `git` in the install
  path.
- Token leakage vectors to check on every diff: argv (both `security` and
  `curl`), printed output, `set -x` traces, CI artifacts.
- `claude -p` headless mode **auto-denies** unpermitted tools — a fast exit is
  correct behavior, not a hang; don't "fix" the absence of a prompt.
- zsh non-interactive contexts never see rc PATH edits — mooted by I4's
  absolute-path exec, but keep it that way.

## 15. Documentation policy

- **The 200-PR test:** before writing a doc, ask whether it will still be true
  after 200 PRs. Will not ⇒ it belongs in a code comment or the issue
  tracker, not a file.
- Document *why*; let *what/how* die as code. docs/status.md is the verified-claim
  surface; docs/environment.md is canonical for exported variables (A6
  enforces the link).
- Placement: root UPPERCASE files for agent/product contracts (`README.md`,
  `AGENTS.md`, `SYSTEM-PROMPT.md`); `docs/` lowercase-hyphen for design.
- Forbidden documentation: ALL_CAPS scratch files, closeout/summary docs,
  TODO comments (file an issue, §17), changelog-of-the-week files.
- Fixing wrong docs is part of the change set that made them wrong.

## 16. Git workflow & merge authority

- Branch per issue: `issue-{N}-{slug}`. Conventional Commits
  (`feat|fix|docs|test|chore(scope): …`).
- `Fixes #N` in the PR body only, never in commit messages.
- Squash-merge is the only merge style; never commit directly to `main`, never
  force-push `main`.
- **Merge grant (standing):** an agent may squash-merge its own PR when (1)
  all §1 gates passed locally **and** CI is green, (2) the PR is not a draft,
  (3) it does not modify `AGENTS.md`, `.github/`, `ci.yml` pins, or gate
  scripts, and (4) it passes §9 review within the budget. Anything touching
  §2–§5, the README verified-claim surface, or the gate/governance files is
  owner-review-only. This grant's wording is load-bearing — quote it, don't
  paraphrase it in PR notes.

## 17. Issue-driven development

- No work starts without an issue that has been read; the issue is the scope
  contract. Drive-by and "while I'm here" changes are refused — found a
  separate bug? File a focused issue.
- Commits map to issue scope; if the issue text drifts during work, update the
  issue first, then the code.
- Issues are filed and steered through the **pi-rukas plan driver** (works
  headless; usage in `~/projects/pi-rukas/docs/headless.md` and README) rather
  than hand-typed one-liners.
- Discovered work is never silently deferred in chat — into the tracker or
  explicitly declined in the PR.

## 18. Never commit (public-repo hygiene)

Never in the repo, the history, or CI artifacts:

- Real endpoints, tokens, hostnames, or account identifiers. The **only**
  token in the repo is the distinctive CI dummy (`qlaude-ci-dummy-token-…`);
  A4's grep is its guardian.
- Raw transcripts, request/response dumps from real sessions, model output
  pasted wholesale.
- Agent scratch files, ephemeral notes, local logs.
- Secrets of any kind — if a mechanism needs one, it is a stdin/env input,
  never a committed value.

The §1 hygiene grep runs over repo **and git history** before any push; a leak
that reached the public remote is an incident: rotate, scrub (history rewrite),
and record how it happened in an issue.

## 19. Commands reference

The gate scripts in §1 are canonical for exact invocations; this is the
orientation table.

| Task | Command |
|------|---------|
| Full gate | `tests/run_tests.sh` |
| Lint | `shellcheck -s sh --severity=style bin/qlaude install.sh tools/* tests/*.sh && dash -n <each>` |
| Checksum | `tools/gen-checksum.sh` (then commit `install.sha256`) |
| Watch CI | `gh run list --watch` |
| File an issue | pi-rukas plan driver (see §17 pointer) |

## 20. Agent working conventions

- No scratch docs, no summary documents — deliver in chat, capture decisions
  in the issue/PR (§16 forbids the rest).
- Verify-before-done: don't report "done" without all §1 gates green and their
  output shown; "it should work" is not evidence.
- Parallelize genuinely independent work (lanes/gates per spec §9); serialize
  anything touching the same file.
- Never read bulk transcripts or logs to answer a question a grep answers.
- Cite the spec section (C1–C9, A1–A7, or §5.x) in any commit or PR line
  where a rule was followed because the spec says so.

## 21. Cross-references

- `README.md` — entry point (what + quickstart); `docs/environment.md` —
  canonical env table; `docs/status.md` — verified-claim surface.
- Newest `docs/superpowers/specs/qlaude-design*` + aligned plan — design
  authority, acceptance criteria A1–A7.
- `SYSTEM-PROMPT.md` header comment — usage of the append-only addendum.
- `~/projects/pi-rukas/` — plan driver for issues; `docs/headless.md`.
- Upstream docs homes: vLLM Claude Code integration page, Claude Code official
  docs, clig.dev (CLI etiquette) — look up current (§12).

## 22. At a glance

1. README's verified claims are the product; unverified claims get deleted (§0).
2. Gates first, locally, always; CI verifies, it does not discover (§1).
3. One POSIX dialect, no exceptions (I1–I3).
4. The token never touches argv/logs/traces; bearer-only wizard (§3).
5. No eval, no writes outside INSTALLDIR/CONFDIR, no consentless rc edits (§4).
6. Never a vLLM manager, never a blocking mystery (§5).
7. Stub the world; break the guard to prove the guard (§7–8).
8. This file stays static — points at mutable truth, never copies it.
9. Agents may merge when the grant's conditions are literally met (§16).
10. No issue, no work (§17).

**Golden rule:** when speed and a verified claim conflict, the claim waits for
nobody — either prove it this session or ship without it.
