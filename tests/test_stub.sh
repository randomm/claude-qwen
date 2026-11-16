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
    _m=$1 _p=$2 _t=$3 _v=$4
    _hdrs=''
    [ "$_t" != '-' ] && _hdrs="Authorization: Bearer $_t"
    _v2=''
    [ "$_v" != '-' ] && _v2="anthropic-version: $_v"
    if [ "$_m" = POST ]; then
        curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "$base$_p" \
            ${_hdrs:+-H} ${_hdrs:+"$_hdrs"} ${_v2:+-H} ${_v2:+"$_v2"} \
            -H 'content-type: application/json' -d "$post_body"
    else
        curl -s -m 5 -o /dev/null -w '%{http_code}' "$base$_p" \
            ${_hdrs:+-H} ${_hdrs:+"$_hdrs"} ${_v2:+-H} ${_v2:+"$_v2"}
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
resp=$(curl -s -m 5 -X POST "$base/v1/messages" -H "Authorization: Bearer $tok" \
    -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
    -d '{"model":"stub-model","max_tokens":8,"messages":[{"role":"user","content":"ping-qlaude"}]}')
printf '%s' "$resp" | grep -q 'ping-qlaude'
st=$?
t "messages: echoes last user text" 0 $st

exit "$fail"
