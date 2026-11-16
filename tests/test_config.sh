#!/bin/sh
# Config-parse suite: config is data, never code (spec §5.2, §6).
# Sourced functions come from bin/qlaude (main() is guarded against sourcing).
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
. "$root/bin/qlaude"

fail=0
t() { # t <name> <0=expected-ok> <status>
    if [ "$3" -eq 0 ]; then
        echo "PASS $1"
    else
        echo "FAIL $1"
        fail=1
    fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 1. Valid config: values loaded, optional keys defaulted per spec §5.2.
cat >"$tmp/valid" <<'CFG'
QLAUDE_ENDPOINT=https://models.example.com
QLAUDE_MODEL=my-model
CFG
QLAUDE_ENDPOINT='' QLAUDE_MODEL='' QLAUDE_AUTH='' QLAUDE_CONTEXT_TOKENS='' \
    QLAUDE_EFFORT='' QLAUDE_CLAUDE_BIN='' QLAUDE_TOKEN=''
config_parse "$tmp/valid" >/dev/null 2>&1
t "valid: parse exits 0" 0 $?
[ "$QLAUDE_ENDPOINT" = "https://models.example.com" ]
t "valid: endpoint loaded" 0 $?
[ "$QLAUDE_MODEL" = "my-model" ]
t "valid: model loaded" 0 $?
[ "$QLAUDE_AUTH" = "bearer" ]
t "valid: auth defaults to bearer" 0 $?
[ "$QLAUDE_CONTEXT_TOKENS" = "262144" ]
t "valid: context defaults to 262144" 0 $?
[ "$QLAUDE_EFFORT" = "medium" ]
t "valid: effort defaults to medium" 0 $?

# 2. Corrupted config: fix message pointing at qlaude setup, no crash.
cat >"$tmp/broken" <<'CFG'
QLAUDE_ENDPOINT=https://models.example.com
this is not a key=value line
CFG
QLAUDE_ENDPOINT='' QLAUDE_MODEL=''
out=$(config_parse "$tmp/broken" 2>&1)
st=$?
t "corrupt: non-zero exit, no crash" 1 $((st == 0 || st > 128))
printf '%s\n' "$out" | grep -q 'qlaude setup'
t "corrupt: message points at qlaude setup" 0 $?

# 3. Missing required key: fix message, not crash.
cat >"$tmp/nomod" <<'CFG'
QLAUDE_ENDPOINT=https://models.example.com
CFG
QLAUDE_ENDPOINT='' QLAUDE_MODEL=''
out=$(config_parse "$tmp/nomod" 2>&1)
st=$?
t "missing model: non-zero exit, no crash" 1 $((st == 0 || st > 128))
printf '%s\n' "$out" | grep -q 'qlaude setup'
t "missing model: message points at qlaude setup" 0 $?

# 4. Trailing /v1 is stripped with a printed warning (spec §5.2).
# Run directly (not in a subshell): config_parse populates vars in this shell.
cat >"$tmp/v1" <<'CFG'
QLAUDE_ENDPOINT=https://models.example.com/v1
QLAUDE_MODEL=my-model
CFG
QLAUDE_ENDPOINT='' QLAUDE_MODEL=''
config_parse "$tmp/v1" 2>"$tmp/v1.warn"
t "v1-suffix: parse exits 0" 0 $?
[ "$QLAUDE_ENDPOINT" = "https://models.example.com" ]
t "v1-suffix: trailing /v1 stripped" 0 $?
grep -qi 'v1' "$tmp/v1.warn"
t "v1-suffix: warning printed" 0 $?

# 5. Bad auth style is refused like corruption.
cat >"$tmp/badauth" <<'CFG'
QLAUDE_ENDPOINT=https://models.example.com
QLAUDE_MODEL=my-model
QLAUDE_AUTH=sideways
CFG
QLAUDE_ENDPOINT='' QLAUDE_MODEL='' QLAUDE_AUTH=''
config_parse "$tmp/badauth" >/dev/null 2>&1
st=$?
t "bad auth style: non-zero exit" 1 $((st == 0 || st > 128))

# 6. Missing file: fix message, not crash.
QLAUDE_ENDPOINT='' QLAUDE_MODEL=''
out=$(config_parse "$tmp/nonexistent" 2>&1)
st=$?
t "missing file: non-zero exit, no crash" 1 $((st == 0 || st > 128))
printf '%s\n' "$out" | grep -q 'qlaude setup'
t "missing file: message points at qlaude setup" 0 $?

# 7. No eval as code in the tool (grep assert, plan T1). Comments mentioning
# the word eval are fine — strip comments before the assert.
if sed 's/#.*//' "$root/bin/qlaude" | grep -Eq '(^|[;&|[:space:]])eval([[:space:]]|$)'; then
    t "no eval in bin/qlaude" 1 1
else
    t "no eval in bin/qlaude" 0 0
fi

# 8. CONFDIR/INSTALLDIR resolve exactly per spec §0.
[ "${QLAUDE_CONFDIR_RESOLVED:-}" = "${QLAUDE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/qlaude}" ]
t "paths: CONFDIR matches spec §0" 0 $?
[ "${QLAUDE_INSTALLDIR_RESOLVED:-}" = "${QLAUDE_INSTALL_DIR:-$HOME/.local/bin}" ]
t "paths: INSTALLDIR matches spec §0" 0 $?

exit "$fail"
