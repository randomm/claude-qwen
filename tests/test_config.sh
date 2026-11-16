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
if [ "$QLAUDE_ENDPOINT" = "https://models.example.com" ]; then st=0; else st=1; fi
t "valid: endpoint loaded" 0 $st
if [ "$QLAUDE_MODEL" = "my-model" ]; then st=0; else st=1; fi
t "valid: model loaded" 0 $st
if [ "$QLAUDE_AUTH" = "bearer" ]; then st=0; else st=1; fi
t "valid: auth defaults to bearer" 0 $st
if [ "$QLAUDE_CONTEXT_TOKENS" = "262144" ]; then st=0; else st=1; fi
t "valid: context defaults to 262144" 0 $st
if [ "$QLAUDE_EFFORT" = "medium" ]; then st=0; else st=1; fi
t "valid: effort defaults to medium" 0 $st

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
if [ "$QLAUDE_ENDPOINT" = "https://models.example.com" ]; then st=0; else st=1; fi
t "v1-suffix: trailing /v1 stripped" 0 $st
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
if [ "${QLAUDE_CONFDIR_RESOLVED:-}" = "${QLAUDE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/qlaude}" ]; then st=0; else st=1; fi
t "paths: CONFDIR matches spec §0" 0 $st
if [ "${QLAUDE_INSTALLDIR_RESOLVED:-}" = "${QLAUDE_INSTALL_DIR:-$HOME/.local/bin}" ]; then st=0; else st=1; fi
t "paths: INSTALLDIR matches spec §0" 0 $st

# 8b. Spec §0 override branches must be exercised too (house rule §8: a
# guard that can never go red is not a guard). Re-source the tool with each
# canonical input exported and assert the resolved value exactly.
_check_path() { # <label> <expect> <var-name> <env-assignments...>
    _lbl=$1 _exp=$2 _nm=$3
    shift 3
    # Source the tool in a clean-env sh and print the named resolved var by
    # explicit case — never eval (house rule: config/names are not code).
    # Single quotes intentional: the named-var case must run inside the
    # sourced subshell, not expand in this suite.
    # shellcheck disable=SC2016
    _got=$(env -u QLAUDE_CONFIG_DIR -u XDG_CONFIG_HOME -u QLAUDE_INSTALL_DIR \
        "$@" sh -c '
            . "$1"
            case $2 in
                QLAUDE_CONFDIR_RESOLVED) printf "%s" "$QLAUDE_CONFDIR_RESOLVED" ;;
                QLAUDE_INSTALLDIR_RESOLVED) printf "%s" "$QLAUDE_INSTALLDIR_RESOLVED" ;;
                *) printf "" ;;
            esac' _ "$root/bin/qlaude" "$_nm" 2>/dev/null)
    if [ "$_got" = "$_exp" ]; then st=0; else st=1; fi
    t "$_lbl" 0 $st
}
_check_path "paths: CONFDIR honours QLAUDE_CONFIG_DIR override" \
    /cfg-override QLAUDE_CONFDIR_RESOLVED QLAUDE_CONFIG_DIR=/cfg-override
_check_path "paths: CONFDIR honours XDG_CONFIG_HOME fallback" \
    /xdg-base/qlaude QLAUDE_CONFDIR_RESOLVED XDG_CONFIG_HOME=/xdg-base
_check_path "paths: INSTALLDIR honours QLAUDE_INSTALL_DIR override" \
    /inst-override QLAUDE_INSTALLDIR_RESOLVED QLAUDE_INSTALL_DIR=/inst-override

# 9. A corrupted line must never be echoed (it can carry a token line).
# The corrupted line itself carries the token (spaces make the key invalid).
printf 'QLAUDE_TOKEN = %s\n' "$QLAUDE_CI_TOKEN" >"$tmp/leaky"
out=$(config_parse "$tmp/leaky" 2>&1)
if printf '%s\n' "$out" | grep -qF "$QLAUDE_CI_TOKEN"; then
    t "corrupt line contents never echoed" 1 1
else
    t "corrupt line contents never echoed" 0 0
fi

# 10. A non-empty QLAUDE_* env beats the file value (spec §5.2 precedence);
# an exported empty string means unset/inherited. All keys are reset first:
# direct config_parse calls share this shell's state.
cat >"$tmp/envmodel" <<'CFG'
QLAUDE_ENDPOINT=https://models.example.com
QLAUDE_MODEL=my-model
CFG
QLAUDE_ENDPOINT='' QLAUDE_MODEL='env-override' QLAUDE_AUTH='' \
    QLAUDE_CONTEXT_TOKENS='' QLAUDE_EFFORT='' QLAUDE_CLAUDE_BIN='' QLAUDE_TOKEN=''
config_parse "$tmp/envmodel" >/dev/null 2>&1
st=$?
t "env precedence: parse ok" 0 $st
[ "$QLAUDE_MODEL" = "env-override" ]; st=$?
t "env precedence: exported env beats file value" 0 $st

exit "$fail"
