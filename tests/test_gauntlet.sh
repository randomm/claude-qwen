#!/bin/sh
# Gauntlet suite (plan T5, spec §5.5): step ordering, exit-code map, the
# auth-enforcing stub as the only endpoint, token-free argv, isolated HOME
# for claude steps, step 3 SKIP under QLAUDE_STUB=1, warn-only step 4.
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

[ -n "${QLAUDE_STUB_PORT:-}" ] || { echo "gauntlet test: harness must export QLAUDE_STUB_PORT" >&2; exit 2; }
[ -n "${QLAUDE_CI_TOKEN:-}" ] || { echo "gauntlet test: harness must export QLAUDE_CI_TOKEN" >&2; exit 2; }
base="http://127.0.0.1:$QLAUDE_STUB_PORT"

tmp=$(mktemp -d) || { echo "gauntlet test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

# --- stand-ins: claude echoes what the gauntlet expects and logs argv+HOME
mkdir -p "$tmp/bin"
cat >"$tmp/bin/claude" <<'SHIM'
#!/bin/sh
printf '%s\n' "$@" >>"$CLAUDE_LOG"
printf 'HOME=%s\n' "$HOME" >>"$CLAUDE_LOG"
case "$*" in
    *QLAUDE_TOOL_OK*) echo "QLAUDE_TOOL_OK" ;;
    *) echo "OK"
esac
SHIM
chmod +x "$tmp/bin/claude"
real_curl=$(command -v curl)
mkdir -p "$tmp/curlshim"
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" >> "$CURL_LOG"' \
    '_in=$(cat); printf '"'"'%s\n'"'"' "$_in" >>"$CURL_STDIN"' \
    "printf '%s' \"\$_in\" | exec $real_curl \"\$@\"" \
    >"$tmp/curlshim/curl"
chmod +x "$tmp/curlshim/curl"

# --- config fixture (0600, spec §5.2)
conf="$tmp/conf"
mkdir -p "$conf"
printf 'QLAUDE_ENDPOINT=%s\nQLAUDE_MODEL=stub-model\nQLAUDE_TOKEN=%s\n' \
    "$base" "$QLAUDE_CI_TOKEN" >"$conf/config.env"
chmod 600 "$conf/config.env"
printf 'appended prompt body\n' >"$conf/SYSTEM-PROMPT.md"

# poisoned user HOME: step 2/3 must never see it
printf '{"bad": true}' >"$tmp/poison-claude.json"

run_doc() { # doctor with isolated env; shims log everything
    env -i PATH="$tmp/bin:$tmp/curlshim:/usr/bin:/bin" HOME="$tmp/poisonhome" \
        QLAUDE_CONFIG_DIR="$conf" QLAUDE_INSTALL_DIR="$tmp/bin" \
        CURL_LOG="$tmp/curl.argv" CURL_STDIN="$tmp/curl.stdin" \
        CLAUDE_LOG="$tmp/claude.argv" \
        QLAUDE_STUB="${QLAUDE_STUB:-}" \
        HTTPS_PROXY="${HTTPS_PROXY:-}" NODE_USE_ENV_PROXY="${NODE_USE_ENV_PROXY:-}" \
        CLAUDE_CODE_AUTO_MODE_SERVER="${CLAUDE_CODE_AUTO_MODE_SERVER:-}" \
        sh "$tool" doctor
}
mkdir -p "$tmp/poisonhome"
cp "$tmp/poison-claude.json" "$tmp/poisonhome/.claude.json"

# 1. Happy path against the enforcing stub: steps 0-2 PASS, step 3 SKIPs
# under QLAUDE_STUB=1 (harness default), exit 0 (A2).
out=$(QLAUDE_STUB=1 run_doc 2>&1)
st=$?
if [ "$st" -eq 0 ]; then st=0; else st=1; fi
t "doctor happy path: exit 0 (A2)" 0 $st
printf '%s\n' "$out" | grep -q '^PASS 0'
t "step 0 PASS line" 0 $?
printf '%s\n' "$out" | grep -q '^PASS 1'
t "step 1 PASS line (200 + content text from stub)" 0 $?
printf '%s\n' "$out" | grep -q '^PASS 2'
t "step 2 PASS line (claude echoed OK)" 0 $?
printf '%s\n' "$out" | grep -q '^SKIP 3'
t "step 3 SKIP under QLAUDE_STUB=1" 0 $?

# 2. Diagnostics go to stderr (C9); stdout stays clean.
stdout=$(QLAUDE_STUB=1 run_doc 2>/dev/null)
if [ -z "$stdout" ]; then st=0; else st=1; fi
t "diagnostics on stderr only" 0 $st

# 3. Step 0 flags missing SYSTEM-PROMPT.md (plan T5) — fail before the net.
mv "$conf/SYSTEM-PROMPT.md" "$tmp/sp.bak"
out=$(QLAUDE_STUB=1 run_doc 2>&1)
st=$?
if [ "$st" -eq 2 ]; then st=0; else st=1; fi
t "missing SYSTEM-PROMPT: exit 2 (prereq)" 0 $st
if printf '%s\n' "$out" | grep -qi 'SYSTEM-PROMPT'; then st=0; else st=1; fi
t "missing SYSTEM-PROMPT: named in the FAIL line" 0 $st
mv "$tmp/sp.bak" "$conf/SYSTEM-PROMPT.md"

# 4. Token hygiene (A4): the token appears in NO curl argv; it IS in the
# stdin config (anti-vacuous: the request really carried it).
QLAUDE_STUB=1 run_doc >/dev/null 2>&1
if grep -qF "$QLAUDE_CI_TOKEN" "$tmp/curl.argv"; then st=1; else st=0; fi
t "step 1: token never in curl argv" 0 $st
if [ -s "$tmp/curl.stdin" ] && grep -qF "$QLAUDE_CI_TOKEN" "$tmp/curl.stdin"; then
    st=0
else
    st=1
fi
t "step 1: token carried via stdin config (anti-vacuous)" 0 $st

# 5. Wrong token: step 1 FAILs exit 3 with the auth hint; config untouched.
printf 'QLAUDE_ENDPOINT=%s\nQLAUDE_MODEL=stub-model\nQLAUDE_TOKEN=wrong-token\n' \
    "$base" >"$conf/config.env"
cp "$conf/config.env" "$tmp/config.wrong"
out=$(QLAUDE_STUB=1 run_doc 2>&1)
st=$?
if [ "$st" -eq 3 ]; then st=0; else st=1; fi
t "wrong token: exit 3 (auth)" 0 $st
if printf '%s\n' "$out" | grep -qiE 'auth|token|401|403'; then st=0; else st=1; fi
t "wrong token: auth hint printed" 0 $st
# untouched means: byte-identical to what we wrote BEFORE doctor ran
if cmp -s "$conf/config.env" "$tmp/config.wrong"; then st=0; else st=1; fi
t "wrong token: config NOT silently rewritten" 0 $st
cp "$tmp/config.wrong" "$tmp/keep"; # marker only; restored below
printf 'QLAUDE_ENDPOINT=%s\nQLAUDE_MODEL=stub-model\nQLAUDE_TOKEN=%s\n' \
    "$base" "$QLAUDE_CI_TOKEN" >"$conf/config.env"

# 6. 404 path (plan T5): an endpoint whose /v1/messages does not exist
# (path mounted elsewhere) → /v1 hint + ONE auto-fix attempt with a
# printed notice; the repair cannot reach this stub, so the run must end
# at exit 3 — exactly two request attempts are logged.
mkdir -p "$tmp/wconf"
printf 'QLAUDE_ENDPOINT=%s/v1/api\nQLAUDE_MODEL=stub-model\nQLAUDE_TOKEN=%s\n' \
    "$base" "$QLAUDE_CI_TOKEN" >"$tmp/wconf/config.env"
cp "$conf/SYSTEM-PROMPT.md" "$tmp/wconf/SYSTEM-PROMPT.md"
out=$(env -i PATH="$tmp/bin:$tmp/curlshim:/usr/bin:/bin" HOME="$tmp/poisonhome" \
    QLAUDE_CONFIG_DIR="$tmp/wconf" QLAUDE_INSTALL_DIR="$tmp/bin" \
    CURL_LOG="$tmp/curl2.argv" CURL_STDIN="$tmp/curl2.stdin" \
    CLAUDE_LOG="$tmp/claude2.argv" QLAUDE_STUB=1 \
    sh "$tool" doctor 2>&1)
st=$?
if [ "$st" -eq 3 ]; then st=0; else st=1; fi
t "404: unreachable after the one auto-fix → exit 3" 0 $st
if printf '%s\n' "$out" | grep -q 'note: 404'; then st=0; else st=1; fi
t "404 auto-fix: printed notice" 0 $st
if printf '%s\n' "$out" | grep -qiE '/v1'; then st=0; else st=1; fi
t "404: /v1 hint text" 0 $st
_n=$(grep -c '^url = ' "$tmp/curl2.stdin")
if [ "$_n" -eq 2 ]; then st=0; else st=1; fi
t "404: exactly one retry attempted (2 requests, no more)" 0 $st

# 7. Step 2 runs claude under an ISOLATED HOME (C7): the poisoned user
# ~/.claude.json must not be visible to the probe.
QLAUDE_STUB=1 run_doc >/dev/null 2>&1
# HOME lines emitted right after a --max-turns probe invocation (steps 2/3;
# step 0's --version runs in the user HOME by design and is excluded).
_probe_homes=$(awk '/--max-turns/{f=1} f && /^HOME=/{print; f=0}' "$tmp/claude.argv")
if printf '%s\n' "$_probe_homes" | grep -qF "HOME=$tmp/poisonhome"; then st=1; else st=0; fi
t "step 2: probe never sees the user HOME" 0 $st
_n=$(printf '%s\n' "$_probe_homes" | grep -c '^HOME=/')
if [ "$_n" -ge 1 ]; then st=0; else st=1; fi
t "step 2: HOME isolation actually applied (anti-vacuous)" 0 $st

# 8. Step 3 without QLAUDE_STUB: runs the tool probe with the exact
# --allowedTools contract (plan T5) and passes on the marker.
out=$(env -i PATH="$tmp/bin:$tmp/curlshim:/usr/bin:/bin" HOME="$tmp/poisonhome" \
    QLAUDE_CONFIG_DIR="$conf" QLAUDE_INSTALL_DIR="$tmp/bin" \
    CURL_LOG="$tmp/curl3.argv" CURL_STDIN="$tmp/curl3.stdin" \
    CLAUDE_LOG="$tmp/claude3.argv" \
    sh "$tool" doctor 2>&1)
st=$?
if [ "$st" -eq 0 ]; then st=0; else st=1; fi
t "step 3 live probe: exit 0 with marker" 0 $st
printf '%s\n' "$out" | grep -q '^PASS 3'
t "step 3 live probe: PASS line" 0 $?
if grep -qxF -- '--allowedTools' "$tmp/claude3.argv" && \
   grep -qxF 'Bash(echo QLAUDE_TOOL_OK)' "$tmp/claude3.argv"; then st=0; else st=1; fi
t "step 3: --allowedTools contract verbatim" 0 $st

# 9. Step 4 is warn-only (plan T5): proxy pollution + stale AUTO_MODE_SERVER
# produce warnings, never a failing exit.
out=$(HTTPS_PROXY=http://proxy:3128 CLAUDE_CODE_AUTO_MODE_SERVER=0 \
    QLAUDE_STUB=1 run_doc 2>&1)
st=$?
if [ "$st" -eq 0 ]; then st=0; else st=1; fi
t "step 4 pollution: warn-only, exit 0" 0 $st
if printf '%s\n' "$out" | grep -qi 'proxy'; then st=0; else st=1; fi
t "step 4: proxy pollution warned" 0 $st
if printf '%s\n' "$out" | grep -qi 'AUTO_MODE_SERVER'; then st=0; else st=1; fi
t "step 4: stale AUTO_MODE_SERVER warned" 0 $st

# 10. One line per step on stderr (rule: PASS/FAIL/SKIP <step>: cause→fix).
QLAUDE_STUB=1 run_doc 2>"$tmp/doc.err" >/dev/null
_lines=$(grep -cE '^(PASS|FAIL|SKIP) [0-9]' "$tmp/doc.err")
if [ "$_lines" -ge 4 ] && [ "$_lines" -le 8 ]; then st=0; else st=1; fi
t "one status line per step" 0 $st

exit "$fail"
