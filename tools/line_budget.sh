#!/bin/sh
# AGENTS.md §10 line budgets — the gate script §10 promises ("enforced by the
# gate scripts, single source for the numbers"). Filed as #84 after the
# 2026-11-18 audit found the promise had no implementation: budgets lived
# only in prose, so nothing stopped a silent over-budget merge.
#
# Ratchet-only: a cap may be LOWERED here (shrinking is a feature, §10), but
# once lowered it may never be raised back — treat changes to these numbers
# as reviewable policy, enforced mechanically by tests/test_line_budget.sh.
# Every physical line counts, comments included: padding comments must obey
# the same budget as code, or the cap is a no-op.
set -u

# Single source of the numbers. bin/qlaude staying one file is deliberate
# shape (§10); the 400-per-test cap keeps suites agent-readable.
CAP_BIN_QLAUDE=600
CAP_INSTALL=200
CAP_STUB=200
CAP_TEST=400

root=${1:-$(cd "$(dirname "$0")/.." && pwd)}
fail=0

chk() { # $1=repo-relative path  $2=cap
    [ -f "$root/$1" ] || { echo "line budget: missing budgeted file $1" >&2; fail=1; return; }
    n=$(wc -l < "$root/$1")
    if [ "$n" -gt "$2" ]; then
        echo "line budget: $1 is $n lines, cap $2 (ratchet-only — shrink it, §10)" >&2
        fail=1
    fi
}

chk bin/qlaude "$CAP_BIN_QLAUDE"
chk install.sh "$CAP_INSTALL"
chk tests/stub_server.py "$CAP_STUB"

# every shell suite under tests/ is capped individually
for f in "$root"/tests/test_*.sh; do
    [ -e "$f" ] || continue
    chk "tests/$(basename "$f")" "$CAP_TEST"
done

exit "$fail"
