# qlaude — implementation plan (rev 2, aligned to spec REV-2)

Source spec: `docs/superpowers/specs/2026-11-16-qlaude-design.md` REV-2 (acceptance rows
A1–A7 are the definition of done; every Review-Focus line below must be exercised by a
test or CI row). Task order T1→T8; one PR per task.

Conventions: strict POSIX sh (`shellcheck -s sh` clean, severity style; `dash -n`
clean). `set -u` everywhere; **no global `set -e` in gauntlet functions** — explicit
per-step exit handling per spec §5.5. Always `IFS= read -r` (`-rs` for secrets). One
function per gauntlet step so setup, doctor, and CI call identical code. The stub
speaks only the wire shapes verified this session (spec §5.8) and **enforces auth**.
CI dummy token: `qlaude-ci-dummy-token-8f31` (distinctive — A4 greps it).

## T1 — skeleton + config layer
Files: `bin/qlaude` (subcommand dispatch, usage/version, NO_COLOR helpers, config parse
— `read`/`case`, never `eval`), `tests/run_tests.sh` (harness: starts stub, exports CI
env, runs the suites, prints per-test PASS/FAIL, exits non-zero on any fail),
`tools/gen-checksum.sh`.
Tests: shellcheck + `dash -n` clean; config-parse unit on a fixture (valid file,
corrupted file → fix-message not crash, missing key → default); grep assert no `eval`.
Review-Focus: config treated as data; CONFDIR/INSTALLDIR resolved exactly per spec §0;
exit-code constants centralized.

## T2 — installer
Files: `install.sh`, `install.sha256` (from `tools/gen-checksum.sh` over
`bin/qlaude` + SYSTEM-PROMPT.md).
Tests: local via `tests/run_tests.sh`: installer with `QLAUDE_INSTALL_DIR/CONFIG_DIR`
into tmp + `QLAUDE_BASE_URL` pointed at a local file server or the repo at
`QLAUDE_REF` → modes 755/600 correct; PATH guidance printed iff INSTALLDIR not on
PATH; zero rc-file mutation; runs clean under `dash -c`. Checksum negative: corrupt
payload → install aborts with the truncation-corruption message, not a half-install.
Review-Focus: no git, no python on user paths, no `install -D`, no GNU-only tools;
HTTPS-only fetch flags; hasher ladder (sha256sum→shasum→openssl); QLAUDE_BASE_URL/REF
honored; no NO_MODIFY_PATH no-op flag.

## T3 — launcher
File: `bin/qlaude` (default branch).
Tests: `qlaude -- 'two words'` reaches a stand-in claude bin as two argv entries (A5,
`"$@"` contract); token absent → clear error, exit 1; `QLAUDE_DEBUG=env` prints the
export list with the token redacted and asserts the list == spec §5.3 set (A4); a
pre-set `ANTHROPIC_MODEL=whatever` is reported as shadowed in `qlaude config`;
`CLAUDE_CODE_AUTO_MODE_SERVER=0` in env → warning printed + unset for the child;
missing SYSTEM-PROMPT.md → note + launch without append, not death.
Review-Focus: `exec … "$@"` verbatim; absolute claude path; keychain→file ladder never
puts token in argv (keychain write via stdin — spec C6); no eval; no `set -x` paths.

## T4 — wizard (`setup`)
File: `bin/qlaude` (setup + `getopts` flags per spec §5.4).
Tests: non-TTY without complete inputs + `-y` → exit 1 + usage, never hang; full `-y`
env run writes 0600 atomically (temp+mv) and passes its gauntlet exit code; re-setup
previews existing values; token via `--token-stdin` never echoed and never in argv
(`ps` sampler during write, incl. the macOS `security -w` stdin form — T7 mac runner);
**token collected before the model probe, and the `/v1/models` probe carries the auth
header** (fixture: stub with auth enforced still lists models for the wizard);
`-y` without `--context` prints the max-model-len warning.
Review-Focus: prompts on stderr; `IFS= read -rs`; model-probe failure degrades to free
text, never blocks; detect-then-offer claude install, never silent.

## T5 — gauntlet (steps 0–4), shared by setup/doctor
File: `bin/qlaude` (doctor + one function per step).
Tests (all via stub): steps 0–2 PASS (A2); step 0 flags missing SYSTEM-PROMPT.md;
step 1 uses `curl -K -` — `ps` sampler during step 1 finds the token in **no argv**
(A4); wrong token → step 1 FAILs exit 3 with the auth hint and config is **not**
silently rewritten; stub mounted at `/api` → 404 path yields the /v1 hint + one
auto-fix attempt with printed notice; step 2 runs under isolated `HOME=$(mktemp -d)`
(fixture: poisoned `~/.claude.json` in the user HOME cannot affect it); step 3 carries
`--allowedTools 'Bash(echo QLAUDE_TOOL_OK)'` and prints SKIP under `QLAUDE_STUB=1`;
step 4 warns (not fails) on proxy pollution and stale AUTO_MODE_SERVER.
Review-Focus: `curl -m` everywhere; exit-code map exact; NO_COLOR; fix lines
copy-pasteable; token never interpolated into printed strings.

## T6 — ensure-path + config
File: `bin/qlaude`.
Tests: marker-block idempotency (run twice → one block); seeded foreign
`# qlaude PATH` block → refuses; `--dry-run` prints, touches nothing; `$SHELL=zsh` on
Linux targets `~/.zprofile` (fixture via env override), Darwin→.zprofile, Linux/bash→
.profile; `qlaude config` redaction (A4) + shadowed-exports section.
Review-Focus: "open a new terminal" hint; never writes outside the marker block.

## T7 — CI + stub polish
Files: `.github/workflows/ci.yml` (jobs: lint incl. **checksum-drift** step and hygiene
grep; smoke ubuntu+**macos-15 pinned**; dash full-chain; negative),
`tests/stub_server.py` (enforce dummy token per QLAUDE_AUTH style + anthropic-version
header on both routes; 401 otherwise).
Tests: A1–A6 green on push (`gh run list --watch`); negative job proves exit 3; mac
job < ~5 min. **Help-capture assert: save `claude --help`; use `--bare` in probes only
if listed, else isolated-HOME path (spec C7).** Pin the claude version actually
installed and record it in the pin line.
Review-Focus: npm install channel per official setup docs; secrets unused; artifacts
never contain the dummy token.

## T8 — README quickstart + uninstall + docs close-out
Files: `README.md` (Quickstart ≤5 lines; uninstall block, spec §6; link spec).
Tests: A6 mechanical check (launcher export list ⊆ README env table, grep in CI);
hygiene grep clean over repo **and git history** before pushing (public-repo rule);
A7 = owner-run manual matrix (Fedora/Ubuntu/macOS + macOS keychain locked/SSH checks),
tracked as a repo issue after merge.
Review-Focus: quickstart matches README's verified table exactly; ≤5 lines; no internal
hostnames anywhere.
