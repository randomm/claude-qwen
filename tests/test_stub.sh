#!/bin/sh
# Stub-contract suite (plan T1 gap resolution: auth enforcement must be
# proven in T1, not deferred to T7). The harness exports QLAUDE_STUB_PORT
# and QLAUDE_CI_TOKEN; this suite proves the stub enforces auth on both
# routes per spec §5.8: correct token + anthropic-version -> 200,
# missing/wrong -> 401.
set -u

fail=0
t() {
    if [ "$3" -eq 0 ]; then
        echo "PASS $1"
    else
        echo "FAIL $1"
        fail=1
    fi
}

base="http://127.0.0.1:${QLAUDE_STUB_PORT:?harness must export QLAUDE_STUB_PORT}"
tok="$QLAUDE_CI_TOKEN"
post_body='{"model":"stub-model","max_tokens":8,"messages":[{"role":"user","content":"OK"}]}'

code() { # code <method> <path> <token|-> <version|->
    # House rule C6: bearer credentials reach curl via stdin config
    # (--config -), never argv.
    _m=$1 _p=$2 _t=$3 _v=$4
    if [ "$_m" = POST ]; then
        # curl config values are quote-parsed: the JSON's own double quotes
        # must be backslash-escaped before they enter the config stream.
        _d=$(printf '%s' "$post_body" | sed 's/"/\\"/g')
        curl -s -m 5 -o /dev/null -w '%{http_code}' --config - <<EOF
url = "$base$_p"
request = "POST"
header = "content-type: application/json"
$([ "$_v" != '-' ] && printf 'header = "anthropic-version: %s"\n' "$_v")
$([ "$_t" != '-' ] && printf 'header = "Authorization: Bearer %s"\n' "$_t")
data-raw = "$_d"
EOF
    else
        curl -s -m 5 -o /dev/null -w '%{http_code}' --config - <<EOF
url = "$base$_p"
$([ "$_v" != '-' ] && printf 'header = "anthropic-version: %s"\n' "$_v")
$([ "$_t" != '-' ] && printf 'header = "Authorization: Bearer %s"\n' "$_t")
EOF
    fi
}

if [ "$(code POST /v1/messages "$tok" 2023-06-01)" = 200 ]; then st=0; else st=1; fi
t "messages: correct token + version -> 200" 0 $st
if [ "$(code POST /v1/messages '-' 2023-06-01)" = 401 ]; then st=0; else st=1; fi
t "messages: missing token -> 401" 0 $st
if [ "$(code POST /v1/messages wrongtoken 2023-06-01)" = 401 ]; then st=0; else st=1; fi
t "messages: wrong token -> 401" 0 $st
if [ "$(code POST /v1/messages "$tok" -)" = 401 ]; then st=0; else st=1; fi
t "messages: missing anthropic-version -> 401" 0 $st
if [ "$(code GET /v1/models "$tok" 2023-06-01)" = 200 ]; then st=0; else st=1; fi
t "models: correct token -> 200" 0 $st
if [ "$(code GET /v1/models '-' 2023-06-01)" = 401 ]; then st=0; else st=1; fi
t "models: missing token -> 401" 0 $st

# echo contract: the response carries the last user text (spec §5.8)
resp=$(curl -s -m 5 --config - <<EOF
url = "$base/v1/messages"
header = "anthropic-version: 2023-06-01"
header = "content-type: application/json"
header = "Authorization: Bearer $tok"
data = "{\"model\":\"stub-model\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"ping-qlaude\"}]}"
write-out = "%{http_code}"
silent
EOF
)
printf '%s' "$resp" | grep -q 'ping-qlaude'
st=$?
t "messages: echoes last user text" 0 $st

# argv audit (C6/A4 idiom, deterministic): a PATH shim records every curl
# argv — the token must never appear there; curl must carry it via stdin
# config (--config -). Deterministic stand-in for a ps sampler race.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/shim"
real_curl=$(command -v curl)
# Single quotes are intentional: the shim's printf format and $@ must be
# written literally into the shim script, not expanded here.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' \
    'printf '"'"'%s\n'"'"' "$@" >> "$SHIM_LOG"' \
    "exec $real_curl \"\$@\"" >"$tmpdir/shim/curl"
chmod +x "$tmpdir/shim/curl"
: >"$tmpdir/curl.argv"
SHIM_LOG="$tmpdir/curl.argv" PATH="$tmpdir/shim:$PATH" code POST /v1/messages "$tok" 2023-06-01 >/dev/null 2>&1
SHIM_LOG="$tmpdir/curl.argv" PATH="$tmpdir/shim:$PATH" code GET /v1/models "$tok" 2023-06-01 >/dev/null 2>&1
if grep -qF "$tok" "$tmpdir/curl.argv"; then
    t "curl argv: token never in argv (stdin config only)" 1 1
else
    t "curl argv: token never in argv (stdin config only)" 0 0
fi

exit "$fail"
