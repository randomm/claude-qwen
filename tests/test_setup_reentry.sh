#!/bin/sh
# Four-lens audit (UX, 2026-11-18): every launch says "…run: qlaude setup"
# when config.env holds a parseable-but-invalid QLAUDE_AUTH/EFFORT/CONTEXT
# value. Re-setup loaded the bad value SILENTLY from the file, ran the whole
# interview, then aborted at the hard validate BEFORE saving — same file,
# same wall, forever; the only escapes were hand-editing a 0600 dotfile or
# env-var literacy (what the product exists to eliminate). Preview ingest
# must validate and DROP (re-ask/default), leaving the hard validates to
# explicit flag/env input only. Offline stub only.
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

[ -n "${QLAUDE_STUB_PORT:-}" ] || { echo "reentry test: harness must export QLAUDE_STUB_PORT" >&2; exit 2; }
[ -n "${QLAUDE_CI_TOKEN:-}" ] || { echo "reentry test: harness must export QLAUDE_CI_TOKEN" >&2; exit 2; }
base="http://127.0.0.1:$QLAUDE_STUB_PORT"

tmp=$(mktemp -d) || { echo "reentry test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/conf"
cat >"$tmp/bin/claude" <<'SHIM'
#!/bin/sh
case "$*" in
    *QLAUDE_TOOL_OK*) echo "QLAUDE_TOOL_OK" ;;
    *) echo "OK"
esac
SHIM
chmod +x "$tmp/bin/claude"
printf 'appended prompt body\n' >"$tmp/conf/SYSTEM-PROMPT.md"

_seed() { # poison-line argv... — fresh config carrying the poison value
    _p=$1
    rm -f "$tmp/conf/config.env"
    {
        printf 'QLAUDE_ENDPOINT=%s\n' "$base"
        printf 'QLAUDE_MODEL=stub-model\n'
        printf 'QLAUDE_TOKEN=%s\n' "$QLAUDE_CI_TOKEN"
        printf '%s\n' "$_p"
    } >"$tmp/conf/config.env"
    chmod 600 "$tmp/conf/config.env"
}

_run() {
    printf '%s' "$QLAUDE_CI_TOKEN" | env -i PATH="$tmp/bin:/usr/bin:/bin" \
        HOME="$tmp" QLAUDE_CONFIG_DIR="$tmp/conf" QLAUDE_INSTALL_DIR="$tmp/bin" \
        sh "$tool" setup -y --endpoint "$base" --model stub-model \
        --claude-bin "$tmp/bin/claude" --token-stdin 2>&1
}

# 1. Poison QLAUDE_AUTH: must not dead-lock; saved config ends valid (bearer default).
_seed 'QLAUDE_AUTH=sideways'
out=$(_run); rc=$?
if [ "$rc" -eq 0 ] && [ -f "$tmp/conf/config.env" ] \
    && grep -q '^QLAUDE_AUTH=bearer$' "$tmp/conf/config.env"; then st=0; else st=1; fi
t "invalid QLAUDE_AUTH: dropped at ingest, setup completes and saves" 0 $st
if printf '%s\n' "$out" | grep -q 'invalid QLAUDE_AUTH ignored'; then st=0; else st=1; fi
t "  anti-vacuous: the drop is announced" 0 $st

# 2. Poison QLAUDE_EFFORT.
_seed 'QLAUDE_EFFORT=turbo'
out=$(_run); rc=$?
if [ "$rc" -eq 0 ] && grep -q '^QLAUDE_EFFORT=medium$' "$tmp/conf/config.env"; then st=0; else st=1; fi
t "invalid QLAUDE_EFFORT: dropped, default saved, no abort" 0 $st

# 3. Non-numeric QLAUDE_CONTEXT_TOKENS.
_seed 'QLAUDE_CONTEXT_TOKENS=lots'
out=$(_run); rc=$?
if [ "$rc" -eq 0 ] && grep -q '^QLAUDE_CONTEXT_TOKENS=262144$' "$tmp/conf/config.env"; then st=0; else st=1; fi
t "invalid context tokens: dropped, 262144 saved, no abort" 0 $st

# 4. Valid values are still KEPT (no regression on the preview contract).
_seed 'QLAUDE_EFFORT=xhigh'
out=$(_run); rc=$?
if [ "$rc" -eq 0 ] && grep -q '^QLAUDE_EFFORT=xhigh$' "$tmp/conf/config.env"; then st=0; else st=1; fi
t "valid effort xhigh still kept verbatim (preview contract intact)" 0 $st

exit "$fail"
