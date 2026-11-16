#!/bin/sh
# Wizard suite (plan T4, spec §5.4): non-TTY etiquette (C9), -y full run,
# atomic 0600 save, token stdin hygiene (never echoed/never argv), authed
# model probe against the enforcing stub, context warning, re-setup preview.
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

[ -n "${QLAUDE_STUB_PORT:-}" ] || { echo "setup test: harness must export QLAUDE_STUB_PORT" >&2; exit 2; }
[ -n "${QLAUDE_CI_TOKEN:-}" ] || { echo "setup test: harness must export QLAUDE_CI_TOKEN" >&2; exit 2; }
base="http://127.0.0.1:$QLAUDE_STUB_PORT"

tmp=$(mktemp -d) || { echo "setup test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

# stand-in claude so the presence check passes; a curl shim logs argv
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/claude"
chmod +x "$tmp/bin/claude"
real_curl=$(command -v curl)
mkdir -p "$tmp/curlshim"
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" >> "$SHIM_LOG"' \
    "exec $real_curl \"\$@\"" >"$tmp/curlshim/curl"
chmod +x "$tmp/curlshim/curl"

wconf="$tmp/wconf"
mkdir -p "$wconf"

run_setup() { # isolated env; curl shim on PATH records every curl argv
    env -i PATH="$tmp/bin:$tmp/curlshim:/usr/bin:/bin" HOME="$tmp" \
        QLAUDE_CONFIG_DIR="$wconf" QLAUDE_INSTALL_DIR="$tmp/bin" \
        SHIM_LOG="$tmp/curl.argv" \
        sh "$tool" setup "$@"
}

# 1. Non-TTY, no inputs, no -y: exit 1 + usage, never hang (EOF-safe reads).
out=$(run_setup </dev/null 2>&1)
st=$?
if [ "$st" -eq 1 ]; then st=0; else st=1; fi
t "non-TTY bare setup: exit 1" 0 $st
printf '%s\n' "$out" | grep -qi 'usage'
t "non-TTY bare setup: usage printed" 0 $?

# 2. -y with incomplete inputs (no model, probe cannot decide it): exit 1.
out=$(run_setup -y --endpoint "$base" --token-stdin </dev/null 2>&1)
st=$?
if [ "$st" -eq 1 ]; then st=0; else st=1; fi
t "-y incomplete inputs: exit 1, never hang" 0 $st

# 3. Full -y run: saves 0600 config with every key; gauntlet exit passes.
printf '%s\n' "$QLAUDE_CI_TOKEN" | run_setup -y --endpoint "$base" \
    --token-stdin --model my-model --context 8192 --effort high \
    --claude-bin "$tmp/bin/claude" >"$tmp/setup.out" 2>"$tmp/setup.err"
st=$?
t "-y full run: exit 0" 0 $st
# shellcheck disable=SC2012  # fixed known filename
if [ -f "$wconf/config.env" ] && [ "$(ls -l "$wconf/config.env" | cut -c2-10)" = "rw-------" ]; then
    st=0
else
    st=1
fi
# shellcheck disable=SC2012
t "-y full run: config.env written at mode 600" 0 $st
for _k in QLAUDE_ENDPOINT QLAUDE_MODEL QLAUDE_TOKEN QLAUDE_CONTEXT_TOKENS QLAUDE_EFFORT QLAUDE_CLAUDE_BIN; do
    grep -q "^$_k=" "$wconf/config.env" || { st=1; break; }
    st=0
done
t "-y full run: all keys persisted" 0 $st
# atomic write: no temp leftovers in CONFDIR
if find "$wconf" -name '*.tmp*' | grep -q .; then st=1; else st=0; fi
t "-y full run: atomic save (no temp leftovers)" 0 $st

# 4. Token never echoed by setup, never in curl argv (C6/A4).
if grep -qF "$QLAUDE_CI_TOKEN" "$tmp/setup.out" "$tmp/setup.err"; then st=1; else st=0; fi
t "token never echoed in setup output" 0 $st
if grep -qF "$QLAUDE_CI_TOKEN" "$tmp/curl.argv"; then st=1; else st=0; fi
t "token never in curl argv (probe via stdin config)" 0 $st

# 5. Authed model probe: the enforcing stub answered (its model id listed),
# proving the /v1/models request carried the auth header.
if grep -q 'stub-model' "$tmp/setup.out" "$tmp/setup.err"; then st=0; else st=1; fi
t "model probe carried auth (stub listed its id)" 0 $st
# anti-vacuous: the probe must have actually gone through the curl shim
if [ -s "$tmp/curl.argv" ]; then st=0; else st=1; fi
t "probe went through the curl shim (argv log non-empty)" 0 $st

# 6. -y without --context: max-model-len warning (plan T4).
rm -f "$wconf/config.env"
out=$(printf '%s\n' "$QLAUDE_CI_TOKEN" | run_setup -y --endpoint "$base" \
    --token-stdin --model my-model --claude-bin "$tmp/bin/claude" 2>&1)
if printf '%s\n' "$out" | grep -qiE 'context|max-model-len'; then st=0; else st=1; fi
t "-y without --context: warning printed" 0 $st

# 7. Re-setup previews existing values (kept, not silently rewritten).
out=$(printf '%s\n' "$QLAUDE_CI_TOKEN" | run_setup -y --endpoint "$base" \
    --token-stdin --claude-bin "$tmp/bin/claude" 2>&1)
if printf '%s\n' "$out" | grep -q 'my-model'; then st=0; else st=1; fi
t "re-setup previews existing model value" 0 $st

# 8. Unknown flag: usage + exit 1 (C9).
out=$(run_setup --frobnicate </dev/null 2>&1)
st=$?
if [ "$st" -eq 1 ] && printf '%s\n' "$out" | grep -qi 'usage'; then st=0; else st=1; fi
t "unknown flag: usage + exit 1" 0 $st

exit "$fail"
