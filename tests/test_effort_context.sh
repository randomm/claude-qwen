#!/bin/sh
# Audit a16 (important): the wizard accepted effort 'high' (which the README's
# env table — the single source of truth — says vLLM rejects with HTTP 400)
# and any garbage for --context, saving both verbatim; the user learned only
# at first real request. Spec §0: the wizard maps user intent onto the vLLM
# enum. Fix: 'high'→'xhigh' with a note, low|medium|xhigh accepted, anything
# else rejected at setup; context must be digits.
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

[ -n "${QLAUDE_STUB_PORT:-}" ] || { echo "effort-context test: harness must export QLADE_STUB_PORT" >&2; exit 2; }
[ -n "${QLAUDE_CI_TOKEN:-}" ] || { echo "effort-context test: harness must export QLADE_CI_TOKEN" >&2; exit 2; }
base="http://127.0.0.1:$QLAUDE_STUB_PORT"

tmp=$(mktemp -d) || { echo "effort-context test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
printf '#!/bin/sh\ncase "$*" in\n *QLAUDE_TOOL_OK*) echo QLADE_TOOL_OK ;;\n *) echo OK\nesac\n' >"$tmp/bin/claude"
chmod +x "$tmp/bin/claude"

_setup() { # confdir argv...
    _cd=$1; shift
    mkdir -p "$_cd"
    printf 'body\n' >"$_cd/SYSTEM-PROMPT.md"
    printf '%s' "$QLAUDE_CI_TOKEN" | env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
        QLAUDE_CONFIG_DIR="$_cd" QLAUDE_INSTALL_DIR="$tmp/bin" QLAUDE_STUB=1 \
        sh "$tool" setup -y --endpoint "$base" --token-stdin \
        --model stub-model --claude-bin "$tmp/bin/claude" "$@" 2>&1
}

# 1. 'high' is the README's documented 400 trap: must be MAPPED, not saved.
out=$(_setup "$tmp/c1" --effort high --context 8192); rc=$?
if [ "$rc" -eq 0 ] && grep -qx 'QLAUDE_EFFORT=xhigh' "$tmp/c1/config.env"; then st=0; else st=1; fi
t "a16 --effort high is mapped onto the vLLM enum (saved xhigh)" 0 $st
if printf '%s\n' "$out" | grep -qF "saved 'xhigh'"; then st=0; else st=1; fi
t "  the mapping is announced (user learns the rename)" 0 $st

# 2. garbage effort rejected at setup, config.env not written.
out=$(_setup "$tmp/c2" --effort turbo --context 8192); rc=$?
if [ "$rc" -ne 0 ] && ! grep -rq 'QLAUDE_EFFORT=turbo' "$tmp/c2" 2>/dev/null; then st=0; else st=1; fi
t "a16 unknown effort rejected at setup (exit 1, not saved)" 0 $st
if printf '%s\n' "$out" | grep -qi 'README'; then st=0; else st=1; fi
t "  fix message points at the README row (single source of truth)" 0 $st

# 3. garbage context rejected (digits only — README max-model-len rule).
out=$(_setup "$tmp/c3" --effort medium --context abc); rc=$?
if [ "$rc" -ne 0 ] && ! grep -rq 'QLAUDE_CONTEXT_TOKENS=abc' "$tmp/c3" 2>/dev/null; then st=0; else st=1; fi
t "a16 non-numeric --context rejected at setup" 0 $st

# 4. anti-vacuous: enum members + digits save verbatim, no note fired.
out=$(_setup "$tmp/c4" --effort xhigh --context 131072); rc=$?
if [ "$rc" -eq 0 ] && grep -qx 'QLAUDE_EFFORT=xhigh' "$tmp/c4/config.env" \
    && grep -qx 'QLAUDE_CONTEXT_TOKENS=131072' "$tmp/c4/config.env"; then st=0; else st=1; fi
t "  anti-vacuous: accepted values save unchanged" 0 $st
case $out in *"'high' is Claude Code's name"*) st=1 ;; *) st=0 ;; esac
t "  no mapping note when nothing was mapped" 0 $st

# 5. anti-vacuous: default path unaffected (no --effort/--context under -y).
out=$(_setup "$tmp/c5"); rc=$?
if [ "$rc" -eq 0 ] && grep -qx 'QLAUDE_EFFORT=medium' "$tmp/c5/config.env" \
    && grep -qx 'QLAUDE_CONTEXT_TOKENS=262144' "$tmp/c5/config.env"; then st=0; else st=1; fi
t "  anti-vacuous: -y defaults (medium/262144) still work" 0 $st

exit "$fail"
