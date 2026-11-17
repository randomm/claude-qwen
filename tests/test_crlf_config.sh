#!/bin/sh
# Audit a15 (important): config.env with CRLF endings kept every value's
# trailing CR: step0 told the user claude was missing (and to reinstall it)
# when only an invisible \r broke abs_exec, `qlaude config` emitted ^M into
# the stdout data channel, and the CR rode into ANTHROPIC_MODEL (the
# generic-404 class the README warns about). Fix: config_parse strips one
# trailing CR per line (CR is never legal in these values).
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

[ -n "${QLAUDE_STUB_PORT:-}" ] || { echo "crlf test: harness must export QLAUDE_STUB_PORT" >&2; exit 2; }
[ -n "${QLAUDE_CI_TOKEN:-}" ] || { echo "crlf test: harness must export QLADE_CI_TOKEN" >&2; exit 2; }
base="http://127.0.0.1:$QLAUDE_STUB_PORT"

tmp=$(mktemp -d) || { echo "crlf test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
printf '#!/bin/sh\ncase "$*" in\n *QLAUDE_TOOL_OK*) echo QLADE_TOOL_OK ;;\n *) echo OK\nesac\n' >"$tmp/bin/claude"
chmod +x "$tmp/bin/claude"

_cr=$(printf '\r')
conf="$tmp/conf"
mkdir -p "$conf"
printf 'appended prompt body\n' >"$conf/SYSTEM-PROMPT.md"

_write_conf() { # $1=which keys get CR (all|bin|model)
    _w=$1
    {
        printf 'QLAUDE_ENDPOINT=%s%s\n' "$base" "$([ "$_w" = all ] && printf '%s' "$_cr")"
        printf 'QLAUDE_MODEL=stub-model%s\n' "$([ "$_w" = model ] || [ "$_w" = all ] && printf '%s' "$_cr")"
        printf 'QLAUDE_TOKEN=%s%s\n' "$QLAUDE_CI_TOKEN" "$([ "$_w" = all ] && printf '%s' "$_cr")"
        printf 'QLAUDE_CLAUDE_BIN=%s/claude%s\n' "$tmp/bin" "$([ "$_w" = bin ] || [ "$_w" = all ] && printf '%s' "$_cr")"
    } >"$conf/config.env"
    chmod 600 "$conf/config.env"
}

_run() {
    env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" QLAUDE_CONFIG_DIR="$conf" \
        QLAUDE_STUB=1 sh "$tool" "$@"
}

# 1. full-CRLF config must be USABLE, not reported as missing claude.
_write_conf all
out=$(_run doctor 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then st=0; else st=1; fi
t "a15 CRLF config: doctor exits 0 (CR stripped, not 'claude not found')" 0 $st
case $out in
    *'claude not found'*) st=1 ;; *) st=0 ;;
esac
t "  no misleading 'claude not found' reinstall hint" 0 $st

# 2. stdout data channel must be CR-free; model line exact.
out=$(_run config 2>/dev/null)
if ! printf '%s' "$out" | grep -q "$_cr"; then st=0; else st=1; fi
t "a15 qlaude config: zero CR bytes in stdout" 0 $st
if printf '%s\n' "$out" | grep -qxF 'model=stub-model'; then st=0; else st=1; fi
t "  model= line exactly matches (no ^M, no invisible junk)" 0 $st

# 3. CR isolated to the BIN line (the audit's exact misdiagnosis).
_write_conf bin
out=$(_run doctor 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then st=0; else st=1; fi
t "a15 CR only on QLAUDE_CLAUDE_BIN: prereq passes (rc 0)" 0 $st

# 4. anti-vacuous: a genuinely missing claude still fails prereqs with rc 2
# — stripping CR never masks a real absence.
mv "$tmp/bin/claude" "$tmp/bin/claude.hidden"
_write_conf all
out=$(_run doctor 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'claude not found'; then st=0; else st=1; fi
t "  anti-vacuous: missing claude still FAILs prereqs (rc 2)" 0 $st
mv "$tmp/bin/claude.hidden" "$tmp/bin/claude"

# 5. anti-vacuous: plain LF config still works (no regression from stripping).
_write_conf none
out=$(_run doctor 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then st=0; else st=1; fi
t "  anti-vacuous: LF-only config unaffected" 0 $st

exit "$fail"
