#!/bin/sh
# Four-lens audit (security, 2026-11-18): the a1 class (quote/newline rejected
# from ANY source before a sink) was fixed for config_parse but NOT for the
# setup probe path — cmd_setup probed with the RAW endpoint before the late
# validation. A crafted --endpoint carrying quote+newline+`url = "http://evil`
# renders TWO url directives into the curl --config heredoc and curl sends the
# Authorization: Bearer <real token> to BOTH — silent token exfiltration
# before any rejection. The validator must run BEFORE the first byte leaves
# the process. Offline loopback only; the curl shim must see ZERO requests.
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

[ -n "${QLAUDE_STUB_PORT:-}" ] || { echo "probe-guard test: harness must export QLAUDE_STUB_PORT" >&2; exit 2; }
[ -n "${QLAUDE_CI_TOKEN:-}" ] || { echo "probe-guard test: harness must export QLAUDE_CI_TOKEN" >&2; exit 2; }

tmp=$(mktemp -d) || { echo "probe-guard test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/curlshim" "$tmp/conf"
cat >"$tmp/bin/claude" <<'SHIM'
#!/bin/sh
echo "OK"
SHIM
chmod +x "$tmp/bin/claude"
: >"$tmp/curl.log"
# shim records EVERY invocation (argv + stdin config body) and fails hard —
# if the probe reaches curl at all, the anti-vacuous log check catches it.
cat >"$tmp/curlshim/curl" <<SHIM
#!/bin/sh
printf 'ARGV %s\n' "\$*" >> "\$SHIM_LOG"
printf 'BODY ' >> "\$SHIM_LOG"
tr '\n' ' ' >> "\$SHIM_LOG"
exit 0
SHIM
chmod +x "$tmp/curlshim/curl"
printf 'appended prompt body\n' >"$tmp/conf/SYSTEM-PROMPT.md"

# Hostile endpoint: quote + newline + injected url directive (the a1 payload
# class), built via printf so no $'..' escape is needed (POSIX sh suites).
hostile=$(printf 'http://127.0.0.1:%s/ok" \nurl = "http://127.0.0.1:%s/evil' \
    "$QLAUDE_STUB_PORT" "$QLAUDE_STUB_PORT")

out=$(printf '%s' "$QLAUDE_CI_TOKEN" | env -i PATH="$tmp/bin:$tmp/curlshim:/usr/bin:/bin" \
    HOME="$tmp" QLAUDE_CONFIG_DIR="$tmp/conf" QLAUDE_INSTALL_DIR="$tmp/bin" \
    SHIM_LOG="$tmp/curl.log" \
    sh "$tool" setup -y --endpoint "$hostile" --model stub-model --token-stdin 2>&1)
rc=$?

if [ "$rc" -eq 1 ]; then st=0; else st=1; fi
t "hostile endpoint: setup exits 1 (was probing first)" 0 $st
if [ ! -s "$tmp/curl.log" ]; then st=0; else st=1; fi
t "ZERO curl requests before validation (token never leaves the box)" 0 $st
if printf '%s\n' "$out" | grep -qiE 'quote|line break'; then st=0; else st=1; fi
t "  error names the offending character class" 0 $st
if printf '%s\n' "$out" | grep -qF "$QLAUDE_CI_TOKEN"; then st=1; else st=0; fi
t "  token value never echoed (A4)" 0 $st

# Twin via inherited env (second unvalidated source).
out=$(printf '%s' "$QLAUDE_CI_TOKEN" | env -i PATH="$tmp/bin:$tmp/curlshim:/usr/bin:/bin" \
    HOME="$tmp" QLAUDE_CONFIG_DIR="$tmp/conf" QLAUDE_INSTALL_DIR="$tmp/bin" \
    QLAUDE_ENDPOINT="$hostile" SHIM_LOG="$tmp/curl.log" \
    sh "$tool" setup -y --model stub-model --token-stdin 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && [ ! -s "$tmp/curl.log" ]; then st=0; else st=1; fi
t "hostile QLAUDE_ENDPOINT env: refused, zero requests" 0 $st

# Sanity twin: a clean endpoint must still probe (anti-vacuous guard).
: >"$tmp/curl.log"
out=$(printf '%s' "$QLAUDE_CI_TOKEN" | env -i PATH="$tmp/bin:$tmp/curlshim:/usr/bin:/bin" \
    HOME="$tmp" QLAUDE_CONFIG_DIR="$tmp/conf" QLAUDE_INSTALL_DIR="$tmp/bin" \
    SHIM_LOG="$tmp/curl.log" \
    sh "$tool" setup -y --endpoint "http://127.0.0.1:$QLAUDE_STUB_PORT" \
    --model stub-model --token-stdin 2>&1)
if [ -s "$tmp/curl.log" ]; then st=0; else st=1; fi
t "anti-vacuous: clean endpoint still probes (guard is not blanket-block)" 0 $st

exit "$fail"
