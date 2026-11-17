#!/bin/sh
# Dogfood (2026-11-17, live gateway): typing the endpoint with a trailing /v1
# (the natural form — the API path is /v1/messages) made the SETUP model probe
# GET .../v1/v1/models → 404 → "model probe unreachable" on a HEALTHY server,
# and saved the raw value. config_parse strips trailing /v1 only at parse time;
# cmd_setup probed and saved the raw input. Setup must normalize before the
# token prompt, the probe and the save. Offline stub only.
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

[ -n "${QLAUDE_STUB_PORT:-}" ] || { echo "setup-v1 test: harness must export QLAUDE_STUB_PORT" >&2; exit 2; }
[ -n "${QLAUDE_CI_TOKEN:-}" ] || { echo "setup-v1 test: harness must export QLAUDE_CI_TOKEN" >&2; exit 2; }
base="http://127.0.0.1:$QLAUDE_STUB_PORT"

tmp=$(mktemp -d) || { echo "setup-v1 test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/curlshim" "$tmp/conf"
cat >"$tmp/bin/claude" <<'SHIM'
#!/bin/sh
case "$*" in
    *QLAUDE_TOOL_OK*) echo "QLAUDE_TOOL_OK" ;;
    *) echo "OK"
esac
SHIM
chmod +x "$tmp/bin/claude"
real_curl=$(command -v curl)
# curl shim: logs argv AND the stdin config body (the probe URL lives in the body)
cat >"$tmp/curlshim/curl" <<SHIM
#!/bin/sh
printf 'ARGV %s\n' "\$*" >> "\$SHIM_LOG"
_b="\$SHIM_LOG.body"
cat > "\$_b"
printf 'BODY ' >> "\$SHIM_LOG"
tr '\n' ' ' < "\$_b" >> "\$SHIM_LOG"
printf '\n' >> "\$SHIM_LOG"
"$real_curl" "\$@" < "\$_b"
SHIM
chmod +x "$tmp/curlshim/curl"
printf 'appended prompt body\n' >"$tmp/conf/SYSTEM-PROMPT.md"
: >"$tmp/curl.log"

out=$(printf '%s' "$QLAUDE_CI_TOKEN" | env -i PATH="$tmp/bin:$tmp/curlshim:/usr/bin:/bin" \
    HOME="$tmp" QLAUDE_CONFIG_DIR="$tmp/conf" QLAUDE_INSTALL_DIR="$tmp/bin" \
    SHIM_LOG="$tmp/curl.log" \
    sh "$tool" setup -y --endpoint "$base/v1" --model stub-model --token-stdin 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then st=0; else st=1; fi
t "setup -y with trailing /v1: exit 0" 0 $st

if [ -s "$tmp/curl.log" ]; then st=0; else st=1; fi
t "anti-vacuous: curl shim saw requests" 0 $st

if grep -qF "url = \"$base/v1/v1/models\"" "$tmp/curl.log"; then st=1; else st=0; fi
t "no doubled /v1/v1/models probe path" 0 $st

if printf '%s\n' "$out" | grep -q 'discovered models from'; then st=0; else st=1; fi
t "discovery succeeded on the healthy server (was falsely 'unreachable')" 0 $st

if grep -qxF "QLAUDE_ENDPOINT=$base" "$tmp/conf/config.env"; then st=0; else st=1; fi
t "saved endpoint is normalized (no trailing /v1)" 0 $st

exit "$fail"
