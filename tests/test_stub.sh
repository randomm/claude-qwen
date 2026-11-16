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

# --- T7 polish: remaining §5.8 negative matrix + QLAUDE_AUTH=api-key mode.
# models-route negatives (T1 pinned only the messages route):
if [ "$(code GET /v1/models '-' 2023-06-01)" = 401 ]; then st=0; else st=1; fi
t "models: missing token -> 401 (route parity)" 0 $st
if [ "$(code GET /v1/models wrongtoken-9x 2023-06-01)" = 401 ]; then st=0; else st=1; fi
t "models: wrong token -> 401" 0 $st
if [ "$(code GET /v1/models "$tok" -)" = 401 ]; then st=0; else st=1; fi
t "models: missing anthropic-version -> 401 (route parity)" 0 $st
if [ "$(code POST /v1/messages "$tok" -)" = 401 ]; then st=0; else st=1; fi
t "messages: missing anthropic-version, token present -> 401 (repeat pin)" 0 $st

# T7 ground truth (live claude 2.1.325 probe): the CLI requests
# /v1/messages?beta=true — query strings must route like the bare path,
# and the response must be a complete Message (id/type/role), not just
# content+stop_reason, or claude rejects it as "not a Message".
_beta=$(curl -s -m 5 -o /dev/null -w '%{http_code}' --config - <<EOF
url = "$base/v1/messages?beta=true"
request = "POST"
header = "content-type: application/json"
header = "anthropic-version: 2023-06-01"
header = "Authorization: Bearer $tok"
data-raw = "{\"model\":\"stub-model\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"beta-ping\"}]}"
EOF
)
if [ "$_beta" = 200 ]; then st=0; else st=1; fi
t "messages: ?beta=true query routes like the bare path (claude CLI form)" 0 $st
_msg=$(curl -s -m 5 --config - <<EOF
url = "$base/v1/messages"
request = "POST"
header = "content-type: application/json"
header = "anthropic-version: 2023-06-01"
header = "Authorization: Bearer $tok"
data-raw = "{\"model\":\"stub-model\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"shape\"}]}"
EOF
)
for _f in '"type":"message"' '"role":"assistant"' '"id":' '"stop_reason":"end_turn"' '"usage":' '"stop_sequence":'; do
    if printf '%s' "$_msg" | grep -qF "$_f"; then st=0; else st=1; break; fi
done
t "messages: response is a complete Message (claude-SDK-strict fields)" 0 $st
# claude's SDK needs a request-id header or it files the server as "other".
_hd=$(curl -s -m 5 -D - -o /dev/null --config - <<EOF
url = "$base/v1/models"
header = "anthropic-version: 2023-06-01"
header = "Authorization: Bearer $tok"
EOF
)
if printf '%s\n' "$_hd" | grep -qi '^request-id:'; then st=0; else st=1; fi
t "response carries request-id header (SDK classification)" 0 $st

# api-key style: a SEPARATE stub instance with QLAUDE_AUTH=api-key —
# Bearer must be rejected there, x-api-key accepted (spec §5.8 style rule).
aport_file=$(mktemp -u /tmp/qlaude-ak-XXXX.port)
QLAUDE_CI_TOKEN=alt-ak-token QLAUDE_AUTH=api-key QLAUDE_STUB_PORTFILE="$aport_file" \
    python3 "$(dirname "$0")/stub_server.py" &
ak_pid=$!
_i=0
while [ "$_i" -lt 50 ] && [ ! -s "$aport_file" ]; do _i=$((_i + 1)); sleep 0.1; done
if [ -s "$aport_file" ]; then
    ak_base="http://127.0.0.1:$(cat "$aport_file")"
    _akcode() { # <hdrname> <token> — GET /v1/models with anthropic-version + one cred header
        curl -s -m 5 -o /dev/null -w '%{http_code}' --config - <<EOF
url = "$ak_base/v1/models"
header = "anthropic-version: 2023-06-01"
header = "$1: $2"
EOF
    }
    if [ "$(_akcode x-api-key alt-ak-token)" = 200 ]; then st=0; else st=1; fi
    t "api-key mode: x-api-key accepted -> 200" 0 $st
    if [ "$(_akcode Authorization 'Bearer alt-ak-token')" = 401 ]; then st=0; else st=1; fi
    t "api-key mode: Bearer rejected -> 401 (style enforced)" 0 $st
    if [ "$(_akcode x-api-key wrong-ak)" = 401 ]; then st=0; else st=1; fi
    t "api-key mode: wrong key -> 401" 0 $st
else
    t "api-key mode: stub started" 1 1
    t "api-key mode: stub started (pair)" 1 1
    t "api-key mode: stub started (pair2)" 1 1
fi
kill "$ak_pid" 2>/dev/null
wait "$ak_pid" 2>/dev/null
rm -f "$aport_file"

exit "$fail"
