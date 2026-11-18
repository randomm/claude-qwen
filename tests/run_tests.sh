#!/bin/sh
# Offline suite entry point (plan T1): starts the auth-enforcing stub,
# exports CI env, runs every tests/test_*.sh, prints per-test PASS/FAIL,
# exits non-zero on any failure. No real endpoints, ever.
set -u

here=$(cd "$(dirname "$0")" && pwd)

if ! command -v python3 >/dev/null 2>&1; then
    echo "qlaude: prerequisite missing: python3 is required to run the offline stub" >&2
    exit 2
fi

tmp=$(mktemp -d) || {
    echo "qlaude: prerequisite failure: mktemp -d failed (TMPDIR unusable?)" >&2
    exit 2
}
stub_pid=''
# Invoked indirectly via trap on exit.
# shellcheck disable=SC2329
cleanup() {
    if [ -n "$stub_pid" ]; then
        kill "$stub_pid" 2>/dev/null
        wait "$stub_pid" 2>/dev/null
    fi
    rm -rf "$tmp"
    return 0
}
trap cleanup EXIT

# --- start stub, wait for it to publish its port (bounded by curl -m logic)
portfile="$tmp/stub.port"
export QLAUDE_STUB_PORTFILE="$portfile"
export QLAUDE_CI_TOKEN='qlaude-ci-dummy-token-8f31'
export QLAUDE_AUTH='bearer'
export QLAUDE_STUB=1
# #82: the installer may auto-run the interview under a tty; a suite run from
# an interactive terminal must never drop into a wizard — installer tests opt
# back in explicitly with env -u QLAUDE_NO_SETUP.
export QLAUDE_NO_SETUP=1
python3 "$here/stub_server.py" &
stub_pid=$!

i=0
while [ "$i" -lt 50 ] && [ ! -s "$portfile" ]; do
    i=$((i + 1))
    sleep 0.1
done
if [ ! -s "$portfile" ]; then
    echo "FAIL stub: did not start" >&2
    exit 1
fi
QLAUDE_STUB_PORT=$(cat "$portfile")
export QLAUDE_STUB_PORT

# --- run suites
fail=0
for suite in "$here"/test_*.sh; do
    [ -e "$suite" ] || { echo "FAIL no test suites found" >&2; exit 1; }
    echo "--- $(basename "$suite")"
    if ! sh "$suite"; then
        fail=1
    fi
done

if [ "$fail" -eq 0 ]; then
    echo "ALL SUITES PASS"
else
    echo "SUITE FAILURES PRESENT" >&2
fi
exit "$fail"
