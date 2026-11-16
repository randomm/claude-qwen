#!/bin/sh
# Launcher suite (plan T3, spec §5.3): "$@" contract (A5), token plumbing,
# qlaude-always-wins exports + shadow report, AUTO_MODE_SERVER=0 handling,
# missing SYSTEM-PROMPT degradation. Stand-in claude bin, never the real one.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
tool="$root/bin/qlaude"

fail=0
t() {
    if [ "$3" -eq 0 ]; then
        echo "PASS $1"
    else
        echo "FAIL $1"
        fail=1
    fi
}

tmp=$(mktemp -d) || { echo "launch test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

# --- stand-in claude: records argv and its own environment
mkdir -p "$tmp/bin"
cat >"$tmp/bin/claude" <<'SHIM'
#!/bin/sh
printf '%s\n' "$@" >"$SHIM_ARGV"
env >"$SHIM_ENV"
SHIM
chmod +x "$tmp/bin/claude"

# --- config fixture (mode and path per spec §5.2)
conf="$tmp/conf"
mkdir -p "$conf"
cat >"$conf/config.env" <<'CFG'
QLAUDE_ENDPOINT=https://models.example.com
QLAUDE_MODEL=my-model
QLAUDE_TOKEN=launch-token-9f2e
CFG
chmod 600 "$conf/config.env"
printf 'appended prompt body\n' >"$conf/SYSTEM-PROMPT.md"

# clean env for every launcher run: nothing inherited may leak in
run_q() { # run_q <args...> — launcher with fully isolated env
    env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
        QLAUDE_CONFIG_DIR="$conf" QLAUDE_INSTALL_DIR="$tmp/bin" \
        SHIM_ARGV="$tmp/argv" SHIM_ENV="$tmp/env" \
        QLAUDE_DEBUG="${QLAUDE_DEBUG:-}" \
        sh "$tool" "$@"
}

# 1. "$@" contract (A5): 'two words' arrives as ONE argv entry.
run_q -- 'two words'
st=$?
t "launch: exit 0 via stand-in claude" 0 $st
if grep -qxF 'two words' "$tmp/argv" && ! grep -qxF 'two' "$tmp/argv"; then st=0; else st=1; fi
t "launch: argument boundaries preserved (\"\$@\", not \"\$*\")" 0 $st

# 2. The append flag reaches claude verbatim with the CONFDIR prompt file.
if grep -qxF -- '--append-system-prompt-file' "$tmp/argv" && \
   grep -qxF "$conf/SYSTEM-PROMPT.md" "$tmp/argv"; then st=0; else st=1; fi
t "launch: --append-system-prompt-file with CONFDIR path" 0 $st

# 3. qlaude-always-wins: all 10 exports reach the child env WITH THEIR
# VALUES (review finding: name-presence alone let wrong values through).
_missing=''
for _v in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL \
    ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
    ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_AUTO_MODE_MODEL \
    CLAUDE_CODE_BG_CLASSIFIER_MODEL CLAUDE_CODE_EFFORT_LEVEL \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS; do
    grep -q "^$_v=" "$tmp/env" || _missing="$_missing $_v"
done
if [ -z "$_missing" ]; then st=0; else st=1; fi
t "launch: full export set in child env" 0 $st
for _exp in \
    'ANTHROPIC_BASE_URL=https://models.example.com' \
    'ANTHROPIC_AUTH_TOKEN=launch-token-9f2e' \
    'ANTHROPIC_MODEL=my-model' \
    'ANTHROPIC_DEFAULT_OPUS_MODEL=my-model' \
    'ANTHROPIC_DEFAULT_SONNET_MODEL=my-model' \
    'ANTHROPIC_DEFAULT_HAIKU_MODEL=my-model' \
    'CLAUDE_CODE_AUTO_MODE_MODEL=my-model' \
    'CLAUDE_CODE_BG_CLASSIFIER_MODEL=my-model' \
    'CLAUDE_CODE_EFFORT_LEVEL=medium' \
    'CLAUDE_CODE_MAX_CONTEXT_TOKENS=262144'; do
    if ! grep -qxF "$_exp" "$tmp/env"; then
        echo "  export value mismatch: $_exp" >&2
        st=1
        break
    fi
    st=0
done
t "launch: every contract export carries its spec value" 0 $st

# 4. Shadowing beats inherited values.
env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
    QLAUDE_CONFIG_DIR="$conf" QLAUDE_INSTALL_DIR="$tmp/bin" \
    SHIM_ARGV="$tmp/argv" SHIM_ENV="$tmp/env" \
    ANTHROPIC_MODEL=inherited-model CLAUDE_CODE_EFFORT_LEVEL=turbo \
    sh "$tool"
grep -q '^ANTHROPIC_MODEL=my-model$' "$tmp/env" && ! grep -q '^ANTHROPIC_MODEL=inherited-model$' "$tmp/env"
t "launch: inherited ANTHROPIC_MODEL overridden (qlaude-wins)" 0 $?

# 5. Missing token: doctor-style fix message, exit 1, claude never exec'd.
printf 'QLAUDE_ENDPOINT=https://models.example.com\nQLAUDE_MODEL=my-model\n' \
    >"$tmp/notoken.conf"
mkdir -p "$tmp/notok"
cp "$tmp/notoken.conf" "$tmp/notok/config.env"
out=$(env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
    QLAUDE_CONFIG_DIR="$tmp/notok" QLAUDE_INSTALL_DIR="$tmp/bin" \
    SHIM_ARGV="$tmp/argv2" SHIM_ENV="$tmp/env2" sh "$tool" 2>&1)
st=$?
if [ "$st" -eq 1 ]; then st=0; else st=1; fi
t "missing token: exit 1" 0 $st
printf '%s\n' "$out" | grep -qi 'qlaude setup'
t "missing token: fix message points at qlaude setup" 0 $?
if [ ! -f "$tmp/argv2" ]; then st=0; else st=1; fi
t "missing token: claude never ran" 0 $st

# 6. QLAUDE_DEBUG=env: export list, token redacted, never the value (A4).
QLAUDE_DEBUG=env out=$(run_q 2>&1)
if printf '%s\n' "$out" | grep -qF 'launch-token-9f2e'; then st=1; else st=0; fi
t "debug env: token value never printed" 0 $st
printf '%s\n' "$out" | grep -q 'ANTHROPIC_AUTH_TOKEN'
t "debug env: token export named (value redacted)" 0 $?
_cnt=$(printf '%s\n' "$out" | grep -oE '(ANTHROPIC|CLAUDE_CODE)_[A-Z_]+' | sort -u | wc -l)
if [ "$_cnt" -eq 10 ]; then st=0; else st=1; fi
t "debug env: export set is exactly the spec §5.3 names" 0 $st

# 7. Pre-set CLAUDE_CODE_AUTO_MODE_SERVER=0: warned and unset for the child.
env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
    QLAUDE_CONFIG_DIR="$conf" QLAUDE_INSTALL_DIR="$tmp/bin" \
    SHIM_ARGV="$tmp/argv" SHIM_ENV="$tmp/env" \
    CLAUDE_CODE_AUTO_MODE_SERVER=0 sh "$tool" 2>"$tmp/ams.err"
grep -qi 'AUTO_MODE_SERVER' "$tmp/ams.err"
t "AUTO_MODE_SERVER=0: warning printed" 0 $?
if grep -q '^CLAUDE_CODE_AUTO_MODE_SERVER=' "$tmp/env"; then st=1; else st=0; fi
t "AUTO_MODE_SERVER=0: unset for the child" 0 $st

# 8. Missing SYSTEM-PROMPT.md: one-line note, launch continues (never dies).
# Review finding: st must capture the GREP status — the command
# substitution's $? is the trailing restore-mv and proves nothing.
out=$(mv "$conf/SYSTEM-PROMPT.md" "$tmp/sp.bak" 2>/dev/null; \
    run_q 2>&1; mv "$tmp/sp.bak" "$conf/SYSTEM-PROMPT.md")
if printf '%s\n' "$out" | grep -qi 'SYSTEM-PROMPT'; then st=0; else st=1; fi
t "no system prompt: note printed" 0 $st
if grep -qxF -- '--append-system-prompt-file' "$tmp/argv"; then st=1; else st=0; fi
t "no system prompt: launched without the append flag" 0 $st

# 9. api-key auth style exports ANTHROPIC_API_KEY, never the bearer var.
mkdir -p "$tmp/apikey"
cat >"$tmp/apikey/config.env" <<'CFG'
QLAUDE_ENDPOINT=https://models.example.com
QLAUDE_MODEL=my-model
QLAUDE_TOKEN=launch-token-9f2e
QLAUDE_AUTH=api-key
CFG
printf 'appended prompt body\n' >"$tmp/apikey/SYSTEM-PROMPT.md"
env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
    QLAUDE_CONFIG_DIR="$tmp/apikey" QLAUDE_INSTALL_DIR="$tmp/bin" \
    SHIM_ARGV="$tmp/argv3" SHIM_ENV="$tmp/env3" \
    ANTHROPIC_AUTH_TOKEN=stale-inherited-bearer sh "$tool" >/dev/null 2>&1
grep -q '^ANTHROPIC_API_KEY=launch-token-9f2e$' "$tmp/env3"
t "api-key auth: ANTHROPIC_API_KEY exported" 0 $?
if grep -q '^ANTHROPIC_AUTH_TOKEN=' "$tmp/env3"; then st=1; else st=0; fi
t "api-key auth: bearer var unset for the child (even inherited)" 0 $st

# 10. Token never in claude's argv, on BOTH auth styles (review finding:
# grepping only the bearer run's argv left the api-key path untested).
# Anti-vacuous: both argv files must exist and be non-empty first.
if [ -s "$tmp/argv" ] && [ -s "$tmp/argv3" ] && \
    ! grep -qF 'launch-token-9f2e' "$tmp/argv" && \
    ! grep -qF 'launch-token-9f2e' "$tmp/argv3"; then
    st=0
else
    st=1
fi
t "launch: token absent from claude argv (bearer and api-key runs)" 0 $st

# 11. qlaude config reports a pre-set ANTHROPIC_MODEL as shadowed, never
# printing the token (plan T3; spec §5.3 + A4).
out=$(env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
    QLAUDE_CONFIG_DIR="$conf" QLAUDE_INSTALL_DIR="$tmp/bin" \
    ANTHROPIC_MODEL=whatever sh "$tool" config 2>&1)
st=$?
t "config: exit 0" 0 $st
printf '%s\n' "$out" | grep -q 'shadowed-inherited=ANTHROPIC_MODEL'
t "config: inherited ANTHROPIC_MODEL reported as shadowed" 0 $?
if printf '%s\n' "$out" | grep -qF 'launch-token-9f2e'; then st=1; else st=0; fi
t "config: token value never printed" 0 $st

# 12. 'launch' verb must not be forwarded to claude's argv (review finding).
env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" QLAUDE_CONFIG_DIR="$conf" \
    QLAUDE_INSTALL_DIR="$tmp/bin" SHIM_ARGV="$tmp/argv4" SHIM_ENV="$tmp/env4" \
    sh "$tool" launch --resume foo >/dev/null 2>&1
if grep -qxF 'launch' "$tmp/argv4"; then st=1; else st=0; fi
t "launch verb stripped before claude argv" 0 $st
if grep -qxF -- '--resume' "$tmp/argv4" && grep -qxF 'foo' "$tmp/argv4"; then st=0; else st=1; fi
t "launch passes user args through" 0 $st

# 13. Token ladder order is spec-mandated (keychain first on macOS): the
# Darwin keychain branch must precede the file/env branch in the source.
# Runtime exercise of that branch is mac-CI-only (T7) — Linux can only pin
# the code order (A7 owner-run matrix covers the rest).
_body=$(sed -n '/^token_resolve()/,/^}/p' "$tool")
_kc_line=$(printf '%s\n' "$_body" | grep -n 'find-generic-password' | head -1 | cut -d: -f1)
_tk_line=$(printf '%s\n' "$_body" | grep -n 'QLAUDE_TOKEN' | head -1 | cut -d: -f1)
if [ -n "$_kc_line" ] && [ -n "$_tk_line" ] && [ "$_kc_line" -lt "$_tk_line" ]; then
    st=0
else
    st=1
fi
t "token ladder: keychain branch precedes file/env (spec §5.3 step 2)" 0 $st

# 14. No subprocess may run AFTER the token is exported (A4 deepening):
# a PATH shim records any printenv call; QLAUDE_DEBUG=env must not spawn
# token-carrying children (values must come from the shell's own params).
mkdir -p "$tmp/peshim"
real_printenv=$(command -v printenv)
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'printf "printenv\n" >> "$PE_LOG"' \
    "exec $real_printenv \"\$@\"" >"$tmp/peshim/printenv"
chmod +x "$tmp/peshim/printenv"
: >"$tmp/pe.log"
env -i PATH="$tmp/bin:$tmp/peshim:/usr/bin:/bin" HOME="$tmp" \
    QLAUDE_CONFIG_DIR="$conf" QLAUDE_INSTALL_DIR="$tmp/bin" \
    SHIM_ARGV="$tmp/argv5" SHIM_ENV="$tmp/env5" PE_LOG="$tmp/pe.log" \
    QLAUDE_DEBUG=env sh "$tool" >/dev/null 2>&1
if grep -q printenv "$tmp/pe.log"; then st=1; else st=0; fi
t "debug export list spawns no token-bearing children" 0 $st

# 15. Relative QLAUDE_CLAUDE_BIN with a slash must be absolutized before
# exec (CWD-dependent exec is a hijack vector). The stand-in claude records
# its own $0; it must arrive as an absolute path.
mkdir -p "$tmp/sub"
# shellcheck disable=SC2016  # shim body is data for the stand-in, not this shell
printf '#!/bin/sh\nprintf "%%s\\n" "$0" >>"$SHIM_ARGV"\nprintf "%%s\\n" "$@" >>"$SHIM_ARGV"\nenv >"$SHIM_ENV"\n' >"$tmp/sub/claude"
chmod +x "$tmp/sub/claude"
# shellcheck disable=SC2016  # sh -c script: $1/$2 expand in the inner shell
env -i PATH="/usr/bin:/bin" HOME="$tmp" QLAUDE_CONFIG_DIR="$conf" \
    QLAUDE_INSTALL_DIR="$tmp/bin" SHIM_ARGV="$tmp/argv6" SHIM_ENV="$tmp/env6" \
    QLAUDE_CLAUDE_BIN="sub/claude" \
    sh -c 'cd "$1" && exec sh "$2"' _ "$tmp" "$tool" >/dev/null 2>&1
if grep -qxF "$tmp/sub/claude" "$tmp/argv6"; then st=0; else st=1; fi
t "relative claude bin exec'd by absolute path" 0 $st

# 16. abs_exec unit test — host-independent pin of the guard (some shells'
# exec absolutizes $0 themselves, masking a relative exec in test 15).
# $0 is set to a name outside the execute guard so sourcing stays inert.
# shellcheck disable=SC2016  # sh -c script: $1/$2 expand in the inner shell
_out=$(sh -c '. "$1" 2>/dev/null
    cd "$2" || exit 9
    abs_exec sub/claude' qlaude-scratch "$tool" "$tmp")
if [ "$_out" = "$tmp/sub/claude" ]; then st=0; else st=1; fi
t "abs_exec: slash-relative value absolutized" 0 $st
# shellcheck disable=SC2016  # sh -c script: $1 expands in the inner shell
_out=$(sh -c '. "$1" 2>/dev/null; abs_exec /bin/sh' qlaude-scratch "$tool")
if [ "$_out" = "/bin/sh" ]; then st=0; else st=1; fi
t "abs_exec: absolute value passed through" 0 $st
# shellcheck disable=SC2016  # sh -c script: $1 expands in the inner shell
if sh -c '. "$1" 2>/dev/null; abs_exec sub/nope' qlaude-scratch "$tool" \
    >/dev/null 2>&1; then st=1; else st=0; fi
t "abs_exec: missing slash-relative target refused" 0 $st

# 17. Source pins for the two binding launcher mechanics (review finding):
# claude must be reached via exec (spec §5.3.4 'exec'd') on BOTH branches,
# and only ever through abs_exec's resolved path (C4). Runtime cannot
# distinguish exec from a plain call on a stand-in, so pin the code.
# shellcheck disable=SC2016  # grep patterns are literal source snippets
_body=$(sed -n '/^cmd_launch()/,/^}/p' "$tool")
# shellcheck disable=SC2016  # grep pattern is a literal source snippet
if printf '%s\n' "$_body" | grep -q 'exec "$_abs" --append-system-prompt-file' && \
    printf '%s\n' "$_body" | grep -q 'exec "$_abs" "$@"'; then st=0; else st=1; fi
t "cmd_launch execs claude on both branches" 0 $st
# shellcheck disable=SC2016  # grep pattern is a literal source snippet
if printf '%s\n' "$_body" | grep -q '_abs=$(abs_exec'; then st=0; else st=1; fi
t "cmd_launch resolves the bin only via abs_exec" 0 $st

exit "$fail"
