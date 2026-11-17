#!/bin/sh
# Audit a2-probe-env-scrub (important): the _probe_claude comment promises
# "ANTHROPIC_*/CLAUDE_CODE_* scrubbed (C7)" but only two vars were unset.
# A user with CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_CUSTOM_HEADERS exported
# leaked credentials into the probe child that talks to the (possibly
# shared third-party) qlaude endpoint, and stale EFFORT/MAX_CONTEXT pins
# perturbed probe determinism. Test: dump the probe child's env, assert no
# foreign credentials/pins, anti-vacuously assert the curated token IS there.
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

[ -n "${QLAUDE_STUB_PORT:-}" ] || { echo "probe-env test: harness must export QLAUDE_STUB_PORT" >&2; exit 2; }
[ -n "${QLAUDE_CI_TOKEN:-}" ] || { echo "probe-env test: harness must export QLAUDE_CI_TOKEN" >&2; exit 2; }
base="http://127.0.0.1:$QLAUDE_STUB_PORT"

tmp=$(mktemp -d) || { echo "probe-env test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT
conf="$tmp/conf"
mkdir -p "$conf" "$tmp/bin"
# env-dumping shim: records EVERY spawned probe child's environment
# dump ONLY probe-style spawns (-p prompts): _probe_claude's contract scope
# shellcheck disable=SC2016  # $* / $PROBE_DUMP are literal shim-source text
printf '#!/bin/sh\ncase "$*" in\n -p\ *) env >> "$PROBE_DUMP"\nesac\ncase "$*" in\n *QLAUDE_TOOL_OK*) echo QLADE_TOOL_OK ;;\n *) echo OK\nesac\n' >"$tmp/bin/claude"
chmod +x "$tmp/bin/claude"

printf 'QLAUDE_ENDPOINT=%s\nQLAUDE_MODEL=stub-model\nQLAUDE_TOKEN=%s\n' "$base" "$QLAUDE_CI_TOKEN" >"$conf/config.env"
chmod 600 "$conf/config.env"
printf 'appended prompt body\n' >"$conf/SYSTEM-PROMPT.md"

: >"$tmp/dump"
env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" QLAUDE_CONFIG_DIR="$conf" \
    QLAUDE_STUB=1 PROBE_DUMP="$tmp/dump" \
    CLAUDE_CODE_OAUTH_TOKEN=OAUTH-SECRET-xyz \
    ANTHROPIC_CUSTOM_HEADERS='x-trace: secret-header' \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS=999999 \
    CLAUDE_CODE_EFFORT_LEVEL=garbage \
    ANTHROPIC_DEFAULT_SONNET_MODEL=stray-sonnet \
    sh "$tool" doctor >/dev/null 2>&1

if ! grep -q 'OAUTH-SECRET-xyz' "$tmp/dump"; then st=0; else st=1; fi
t "probe child never sees CLAUDE_CODE_OAUTH_TOKEN" 0 $st
if ! grep -q 'x-trace: secret-header' "$tmp/dump"; then st=0; else st=1; fi
t "probe child never sees ANTHROPIC_CUSTOM_HEADERS" 0 $st
if ! grep -q 'MAX_CONTEXT_TOKENS=999999' "$tmp/dump"; then st=0; else st=1; fi
t "stale CLAUDE_CODE_MAX_CONTEXT_TOKENS not inherited by probe" 0 $st
if ! grep -q 'EFFORT_LEVEL=garbage' "$tmp/dump"; then st=0; else st=1; fi
t "stale CLAUDE_CODE_EFFORT_LEVEL not inherited by probe" 0 $st
if ! grep -q 'stray-sonnet' "$tmp/dump"; then st=0; else st=1; fi
t "stray ANTHROPIC_DEFAULT_*_MODEL not inherited by probe" 0 $st
if grep -q "ANTHROPIC_AUTH_TOKEN=$QLAUDE_CI_TOKEN" "$tmp/dump"; then st=0; else st=1; fi
t "  anti-vacuous: curated token IS exported to the probe child" 0 $st
if grep -q "ANTHROPIC_BASE_URL=$base" "$tmp/dump"; then st=0; else st=1; fi
t "  anti-vacuous: probe child env dump captured (shim ran)" 0 $st

exit "$fail"
