#!/bin/sh
# Audit a13 (minor): the README — the project's declared single source of
# truth — did not document the installer coordinates (QLAUDE_BASE_URL,
# QLAUDE_REF, QLAUDE_INSTALL_DIR, QLAUDE_CONFIG_DIR) although spec §5.6
# claims they are documented ("users pin tags by putting the tag in the URL
# (documented)"). Users could not pin a release tag without reading source,
# and the loopback-http override was invisible in user-facing docs.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
readme="$root/README.md"

fail=0
t() {
    if [ "$3" -eq 0 ]; then
        echo "PASS $1"
    else
        echo "FAIL $1"
        fail=1
    fi
}

[ -f "$readme" ] || { echo "docs-coords: README.md missing" >&2; exit 2; }

for v in QLAUDE_BASE_URL QLAUDE_REF QLAUDE_INSTALL_DIR QLAUDE_CONFIG_DIR; do
    if grep -q "$v" "$readme"; then st=0; else st=1; fi
    t "README documents $v" 0 $st
done
if grep -qiE '127\.0\.0\.1|localhost|loopback' "$readme"; then st=0; else st=1; fi
t "README documents the loopback-only http override" 0 $st
# shellcheck disable=SC2016  # `QLAUDE_REF` is literal README text
if grep -qE 'QLAUDE_REF=[^ ]+|`QLAUDE_REF`' "$readme" && grep -qi 'pin' "$readme"; then
    st=0
else
    st=1
fi
t "README explains how to pin a release (spec §5.6)" 0 $st

# Source-of-truth guard: the new installer section must NOT restate the
# launch-variable table (ANTHROPIC_*/CLAUDE_CODE_* rows live in exactly one
# place — 'Why each variable matters').
# shellcheck disable=SC2016  # the backticks are literal markdown table text
n_tables=$(grep -c '^| `ANTHROPIC_BASE_URL`' "$readme")
if [ "$n_tables" -eq 1 ]; then st=0; else st=1; fi
t "  anti-vacuous: launch-variable table still exists exactly once" 0 $st
section=$(sed -n '/### Installer coordinates/,/^## /p' "$readme")
case $section in
    *ANTHROPIC_* | *CLAUDE_CODE_*) st=1 ;;
    *) st=0 ;;
esac
t "  the installer section does not duplicate launch variables" 0 $st

exit "$fail"
