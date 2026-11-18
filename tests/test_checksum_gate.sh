#!/bin/sh
# Audit 2026-11-18 (#60): run_tests.sh printed "ALL SUITES PASS" with an
# install.sha256 that did not match the payload — the --check gate lived only
# in CI's lint job, and eleven push branches shipped stale manifests before
# CI caught it. The suite IS the pre-push gate (AGENTS.md §1), so manifest
# drift must fail here too. This file runs automatically: run_tests.sh globs
# tests/test_*.sh.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

fail=0
t() {
    if [ "$3" -eq 0 ]; then
        echo "PASS $1"
    else
        echo "FAIL $1"
        fail=1
    fi
}

# 1. The real tree: committed install.sha256 must match the payload. A stale
#    manifest now fails the suite (this is what run_tests.sh lacked).
out=$(sh "$root/tools/gen-checksum.sh" --check 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then st=0; else st=1; printf '%s\n' "$out" >&2; fi
t "checksum gate: committed install.sha256 matches the payload" 0 $st

# 2+3. The detector is not vacuous: on a private copy, the pristine payload
#      passes and a behavior-neutral tamper is rejected as stale. (The real
#      tree is never modified here.)
tmp=$(mktemp -d) || { echo "checksum gate test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/tools"
cp "$root/bin/qlaude" "$tmp/bin/qlaude"
cp "$root/SYSTEM-PROMPT.md" "$tmp/SYSTEM-PROMPT.md"
cp "$root/install.sha256" "$tmp/install.sha256"
cp "$root/tools/gen-checksum.sh" "$tmp/tools/gen-checksum.sh"
out=$(sh "$tmp/tools/gen-checksum.sh" --check 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then st=0; else st=1; printf '%s\n' "$out" >&2; fi
t "  anti-vacuous A: pristine copy passes the gate" 0 $st
printf '\n# tamper\n' >> "$tmp/bin/qlaude"
out=$(sh "$tmp/tools/gen-checksum.sh" --check 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qi stale; then st=0; else st=1; printf '%s\n' "$out" >&2; fi
t "  anti-vacuous B: tampered payload rejected as stale" 0 $st

exit "$fail"
