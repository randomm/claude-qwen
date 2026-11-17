#!/bin/sh
# Audit a6 (minor): _probe_claude mktemp -d's a fresh HOME+PWD per spawn and
# never removes it — every doctor leaves 0700 dirs with the probe claude's
# session traces in TMPDIR, unbounded growth in the documented CI loop.
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

[ -n "${QLAUDE_STUB_PORT:-}" ] || { echo "probe-cleanup test: harness must export QLADE_STUB_PORT" >&2; exit 2; }
[ -n "${QLAUDE_CI_TOKEN:-}" ] || { echo "probe-cleanup test: harness must export QLADE_CI_TOKEN" >&2; exit 2; }
base="http://127.0.0.1:$QLAUDE_STUB_PORT"

tmp=$(mktemp -d) || { echo "probe-cleanup test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/mytmp"
printf '#!/bin/sh\ncase "$*" in\n *QLAUDE_TOOL_OK*) echo QLADE_TOOL_OK ;;\n *) echo OK\nesac\n' >"$tmp/bin/claude"
chmod +x "$tmp/bin/claude"
conf="$tmp/conf"
mkdir -p "$conf"
printf 'body\n' >"$conf/SYSTEM-PROMPT.md"
printf 'QLAUDE_ENDPOINT=%s\nQLAUDE_MODEL=stub-model\nQLAUDE_TOKEN=%s\nQLAUDE_CLAUDE_BIN=%s/claude\n' \
    "$base" "$QLAUDE_CI_TOKEN" "$tmp/bin" >"$conf/config.env"
chmod 600 "$conf/config.env"

before=$(find "$tmp/mytmp" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -c)
out=$(env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" TMPDIR="$tmp/mytmp" \
    QLAUDE_CONFIG_DIR="$conf" QLAUDE_STUB=1 sh "$tool" doctor 2>&1)
rc=$?
after=$(find "$tmp/mytmp" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -c)
# anti-vacuous: the probe really ran (claude spawn is step 2's subject)
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'PASS 2'; then st=0; else st=1; fi
t "probe ran under isolated TMPDIR (doctor green, step 2 PASS)" 0 $st
if [ "$before" = "$after" ]; then st=0; else st=1; fi
t "a6 doctor leaves ZERO probe dirs behind in TMPDIR" 0 $st

exit "$fail"
