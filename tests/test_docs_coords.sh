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

# #83 (blind-read 2026-11-18): scripted setup must stay runnable without
# reading bin/qlaude — token-stdin stays in the README quickstart.
if grep -q 'token-stdin' "$readme"; then st=0; else st=1; fi
t "README documents token-stdin" 0 $st
# shellcheck disable=SC2016  # the passthrough form is literal shell text
if grep -qF 'qlaude -- -p' "$readme"; then st=0; else st=1; fi
t "README documents the qlaude -- passthrough" 0 $st

# readme-slim (2026-11-19, owner directive): the README is a short
# what+quickstart; the canonical variable reference moved to
# docs/environment.md. Pins follow the content — the single-source rule
# survives, only its location moved. The README must carry the reassurance
# that users never set environment variables by hand.
canon="$root/docs/environment.md"
[ -f "$canon" ] || { echo "docs-coords: docs/environment.md missing" >&2; exit 2; }

for v in QLAUDE_BASE_URL QLAUDE_REF QLAUDE_INSTALL_DIR QLAUDE_CONFIG_DIR; do
    if grep -q "$v" "$canon"; then st=0; else st=1; fi
    t "environment doc documents $v" 0 $st
done
if grep -qiE '127\.0\.0\.1|localhost|loopback' "$canon"; then st=0; else st=1; fi
t "environment doc documents the loopback-only http override" 0 $st
# shellcheck disable=SC2016  # `QLAUDE_REF` is literal doc text
if grep -qE 'QLAUDE_REF=[^ ]+|`QLAUDE_REF`' "$canon" && grep -qi 'pin' "$canon"; then
    st=0
else
    st=1
fi
t "environment doc explains how to pin a release (spec §5.6)" 0 $st

# shellcheck disable=SC2016  # the backticks are literal markdown table text
n_var_rows=$(grep -c '^| `ANTHROPIC_BASE_URL`' "$canon")
if [ "$n_var_rows" -eq 1 ]; then st=0; else st=1; fi
t "  launch-variable table exists exactly once, in the environment doc" 0 $st
# shellcheck disable=SC2016  # the backticks are literal markdown table text
n_readme_rows=$(grep -c '^| `ANTHROPIC_BASE_URL`' "$readme")
if [ "$n_readme_rows" -eq 0 ]; then st=0; else st=1; fi
t "  the slim README carries no variable table (single source holds)" 0 $st
section=$(sed -n '/### Installer coordinates/,/^## /p' "$canon")
case $section in
    *ANTHROPIC_* | *CLAUDE_CODE_*) st=1 ;;
    *) st=0 ;;
esac
t "  the installer section does not duplicate launch variables" 0 $st

if grep -q 'QLAUDE_NO_SETUP' "$canon"; then st=0; else st=1; fi
t "environment doc documents QLAUDE_NO_SETUP" 0 $st
if grep -qiE 'no environment variable' "$readme"; then st=0; else st=1; fi
t "README reassures: no environment variables to set" 0 $st

# readme-accessibility (2026-11-18): the hero terminal sketch is a sketch —
# keep it labeled, and keep every relative markdown link in the user-facing
# docs resolvable (a dead link is the #1 "abandoned repo" tell; the docs/
# split must ship whole or README links die).
if grep -qF '(output sketch' "$readme"; then st=0; else st=1; fi
t "README terminal sketch stays labeled (output sketch)" 0 $st

_dead=0
_check_links() { # $1 = repo-relative markdown file
    _f=$1; _dir=$(dirname "$root/$_f")
    while IFS= read -r _l; do
        [ -n "$_l" ] || continue
        [ -f "$_dir/$_l" ] || { echo "  dead link in $_f -> $_l"; _dead=1; }
    done <<EOF2
$(grep -oE '\]\([A-Za-z0-9_./-]+\.md\)' "$root/$_f" | sed 's/^](//; s/)$//')
EOF2
}
_check_links README.md
for _d in docs/auto-mode.md docs/gateways.md docs/behavior-prompt.md \
    docs/README.md docs/prerequisites.md docs/how-it-works.md \
    docs/environment.md docs/troubleshooting.md docs/verify.md \
    docs/server-checklist.md docs/status.md; do
    _check_links "$_d"
done
t "every relative markdown link in README + docs resolves" 0 "$_dead"

exit "$fail"
