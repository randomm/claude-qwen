#!/bin/sh
# Journey audit (2026-11-18): the gauntlet's 401 remedy is "re-run qlaude
# setup", but re-setup loaded the stored token SILENTLY (endpoint/model both
# print "preview: keeping …", the token did not) and never pointed at the one
# flag that replaces it (--token-stdin). A stale token therefore survived the
# documented remedy forever. Re-setup must name the kept token and the
# replacement flag — without ever printing the value (A4). Offline stub only.
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

[ -n "${QLAUDE_STUB_PORT:-}" ] || { echo "token-note test: harness must export QLAUDE_STUB_PORT" >&2; exit 2; }
[ -n "${QLAUDE_CI_TOKEN:-}" ] || { echo "token-note test: harness must export QLAUDE_CI_TOKEN" >&2; exit 2; }
base="http://127.0.0.1:$QLAUDE_STUB_PORT"

tmp=$(mktemp -d) || { echo "token-note test: mktemp -d failed" >&2; exit 2; }
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

_env() { env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
    QLAUDE_CONFIG_DIR="$tmp/conf" QLAUDE_INSTALL_DIR="$tmp/bin" "$@"; }

# Seed a config via a first setup run (token via stdin).
printf '%s' "$QLAUDE_CI_TOKEN" | _env sh "$tool" setup -y --endpoint "$base" \
    --model stub-model --claude-bin "$tmp/bin/claude" --token-stdin >/dev/null 2>&1
if grep -q "QLAUDE_TOKEN=" "$tmp/conf/config.env"; then st=0; else st=1; fi
t "anti-vacuous: config.env carries a stored token" 0 $st

# Re-setup WITHOUT --token-stdin: kept token must be named + remedy shown.
out=$(_env sh "$tool" setup -y --endpoint "$base" --model stub-model \
    --claude-bin "$tmp/bin/claude" </dev/null 2>&1)
if printf '%s\n' "$out" | grep -q 'keeping stored token'; then st=0; else st=1; fi
t "re-setup names the kept token" 0 $st
if printf '%s\n' "$out" | grep -q -- '--token-stdin'; then st=0; else st=1; fi
t "re-setup points at the flag that replaces it" 0 $st

# A4: the note must never materialize the value.
if printf '%s\n' "$out" | grep -qF "$QLAUDE_CI_TOKEN"; then st=1; else st=0; fi
t "kept-token note never prints the token value (A4)" 0 $st

# --token-stdin replaces the stored token (keeping-note stays honest: the
# replacement path must not claim "keeping" over a value it is about to swap).
out=$(printf '%s' 'rotated-token-9999' | _env sh "$tool" setup -y --endpoint "$base" \
    --model stub-model --claude-bin "$tmp/bin/claude" --token-stdin 2>&1)
if grep -q "QLAUDE_TOKEN=rotated-token-9999" "$tmp/conf/config.env"; then st=0; else st=1; fi
t "--token-stdin still replaces the stored token" 0 $st

exit "$fail"
