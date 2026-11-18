#!/bin/sh
# #84 (audit 2026-11-18): AGENTS.md §10 promises line budgets are "enforced
# by the gate scripts (single source for the numbers); ratchet-only" — but no
# gate script existed, so budgets lived only in prose and the merge helper's
# honor system. This suite IS that gate: run_tests.sh globs tests/test_*.sh,
# so an over-budget file now fails the pre-push suite, not CI folklore.
# Every physical line counts, comments included — the guard exists so files
# stay agent-operable; bloat is the failure mode.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
gate="$root/tools/line_budget.sh"

fail=0
t() {
    if [ "$3" -eq 0 ]; then
        echo "PASS $1"
    else
        echo "FAIL $1"
        fail=1
    fi
}

# 1. The real tree passes the gate: every budgeted file at or under its cap.
out=$(sh "$gate" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then st=0; else st=1; printf '%s\n' "$out" >&2; fi
t "line budget: real tree within all caps" 0 $st

# 2+3+4. The gate is not vacuous: on a private pristine copy it passes; it
#      rejects a file grown past its cap (comments padded, proving comments
#      count); and it obeys a lowered cap (ratchet-only: a shrunken budget
#      may never be raised back — the table is the ratchet ledger). The real
#      tree is never modified.
tmp=$(mktemp -d) || { echo "line budget test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/tests" "$tmp/tools"
mkdir -p "$tmp/tests"
cp "$root/bin/qlaude" "$tmp/bin/qlaude"
cp "$root/install.sh" "$tmp/install.sh"
cp "$root/tests/stub_server.py" "$tmp/tests/stub_server.py"
cp "$root/tools/line_budget.sh" "$tmp/tools/line_budget.sh"
# tests glob needs at least the runner-visible budgeted files
for f in "$here"/test_*.sh; do cp "$f" "$tmp/tests/"; done
out=$(sh "$tmp/tools/line_budget.sh" "$tmp" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then st=0; else st=1; printf '%s\n' "$out" >&2; fi
t "  anti-vacuous A: pristine copy passes the gate" 0 $st

# over-cap: pad install.sh past its cap, one comment per line — behavior-
# neutral padding is exactly what the gate must refuse.
n=$(wc -l < "$tmp/install.sh")
i=1
while [ "$i" -le $((201 - n)) ]; do printf '# pad\n' >> "$tmp/install.sh"; i=$((i + 1)); done
out=$(sh "$tmp/tools/line_budget.sh" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'install.sh'; then st=0; else st=1; printf '%s\n' "$out" >&2; fi
t "  anti-vacuous B: file over its cap is rejected by name" 0 $st

# ratchet semantics: with the install.sh cap lowered to 150 in the table, the
# honest 176-line file already fails — once lowered, no growth back.
sed -i 's/^CAP_INSTALL=200$/CAP_INSTALL=150/' "$tmp/tools/line_budget.sh"
cp "$root/install.sh" "$tmp/install.sh"
out=$(sh "$tmp/tools/line_budget.sh" "$tmp" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'install.sh'; then st=0; else st=1; printf '%s\n' "$out" >&2; fi
t "  anti-vacuous C: lowered cap is honored (ratchet-only)" 0 $st

exit "$fail"
