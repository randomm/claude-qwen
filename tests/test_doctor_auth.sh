#!/bin/sh
# Audit a3-doctor-auth (important): config_parse + launcher support
# QLAUDE_AUTH=api-key (hand-edited config.env — documented bypass since C7
# makes setup bearer-only), but doctor's step1 and probe_models hardcoded
# 'Authorization: Bearer', so a WORKING api-key profile always failed
# doctor with exit 3 and an unfixedable 'run qlaude setup' hint. Spec §5.8
# requires style-adherent probing.
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

[ -n "${QLAUDE_STUB_PORT:-}" ] || { echo "doctor-auth test: harness must export QLAUDE_STUB_PORT" >&2; exit 2; }
tmp=$(mktemp -d) || { echo "doctor-auth test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
printf '#!/bin/sh\ncase "$*" in\n *QLAUDE_TOOL_OK*) echo QLADE_TOOL_OK ;;\n *) echo OK\nesac\n' >"$tmp/bin/claude"
chmod +x "$tmp/bin/claude"

# a second stub instance enforcing x-api-key style
mkdir -p "$tmp/conf"
printf 'appended prompt body\n' >"$tmp/conf/SYSTEM-PROMPT.md"
AKTOK='SEKRET-tok-42'
QLAUDE_STUB_PORTFILE="$tmp/p2" QLAUDE_CI_TOKEN="$AKTOK" QLAUDE_AUTH=api-key \
    python3 "$root/tests/stub_server.py" &
sp=$!
i=0; while [ $i -lt 50 ] && [ ! -s "$tmp/p2" ]; do i=$((i + 1)); sleep 0.1; done
[ -s "$tmp/p2" ] || { echo "doctor-auth test: api-key stub failed to start" >&2; exit 2; }
abase="http://127.0.0.1:$(cat "$tmp/p2")"

printf 'QLAUDE_ENDPOINT=%s\nQLAUDE_MODEL=stub-model\nQLAUDE_AUTH=api-key\nQLAUDE_TOKEN=%s\n' "$abase" "$AKTOK" >"$tmp/conf/config.env"
chmod 600 "$tmp/conf/config.env"

out=$(env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" QLAUDE_CONFIG_DIR="$tmp/conf" QLAUDE_STUB=1 \
    sh "$tool" doctor 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'PASS 1 messages'; then st=0; else st=1; fi
t "doctor honors QLAUDE_AUTH=api-key (x-api-key probe passes, exit 0)" 0 $st

# anti-vacuous: the SAME stub rejects a Bearer-style probe — the stub really
# enforces style, so PASS above is proof of style adherence, not a lax stub.
printf 'QLAUDE_ENDPOINT=%s\nQLAUDE_MODEL=stub-model\nQLAUDE_TOKEN=%s\n' "$abase" "$AKTOK" >"$tmp/conf/config.env"
out=$(env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" QLAUDE_CONFIG_DIR="$tmp/conf" QLAUDE_STUB=1 \
    sh "$tool" doctor 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'FAIL 1 messages'; then st=0; else st=1; fi
t "  anti-vacuous: api-key stub rejects Bearer probe (style is enforced)" 0 $st

# §5.2: launcher must warn when an api-key profile is active (hand-edited
# bypass of C7's bearer-only setup — some servers treat x-api-key as account login).
out=$(env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" QLAUDE_CONFIG_DIR="$tmp/conf" QLAUDE_STUB=1     sh "$tool" launch 2>&1)
printf 'QLAUDE_ENDPOINT=%s\nQLAUDE_MODEL=stub-model\nQLAUDE_AUTH=api-key\nQLAUDE_TOKEN=%s\n' "$abase" "$AKTOK" >"$tmp/conf/config.env"
chmod 600 "$tmp/conf/config.env"
out=$(env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" QLAUDE_CONFIG_DIR="$tmp/conf" QLAUDE_STUB=1     sh "$tool" launch 2>&1)
if printf '%s\n' "$out" | grep -q 'x-api-key'; then st=0; else st=1; fi
t "launch warns when QLAUDE_AUTH=api-key (spec §5.2)" 0 $st
printf 'QLAUDE_ENDPOINT=%s\nQLAUDE_MODEL=stub-model\nQLAUDE_TOKEN=%s\n' "$abase" "$AKTOK" >"$tmp/conf/config.env"
chmod 600 "$tmp/conf/config.env"
out=$(env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" QLAUDE_CONFIG_DIR="$tmp/conf" QLAUDE_STUB=1     sh "$tool" launch 2>&1)
if printf '%s\n' "$out" | grep -q 'x-api-key'; then st=1; else st=0; fi
t "  anti-vacuous: no warning on the bearer (default) path" 0 $st

kill $sp 2>/dev/null; wait $sp 2>/dev/null
exit "$fail"
