#!/bin/sh
# Audit a7 + a10 (important): cmd_ensure_path interpolated
# QLAUDE_INSTALL_DIR into the appended rc line with no escaping (a `"; cmd; #`
# value = code execution on every future login, breaking the §5.7/C4 consent
# model), and a relative QLAUDE_INSTALL_DIR was accepted everywhere — a
# relative PATH entry resolves against each future shell's cwd (attacker-writable
# dir + cd + login shell = arbitrary execution). Fix: escape the rc line;
# require absolute paths in ensure-path AND in install.sh.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
tool="$root/bin/qlaude"
inst="$root/install.sh"

fail=0
t() {
    if [ "$3" -eq 0 ]; then
        echo "PASS $1"
    else
        echo "FAIL $1"
        fail=1
    fi
}

tmp=$(mktemp -d) || { echo "ensure-path test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

_home() { # $1=home dir name — fresh home with a benign profile
    mkdir -p "$tmp/$1"
    printf 'alias x=1\n' >"$tmp/$1/.profile"
    printf '%s' "$tmp/$1"
}

# 1. a7: quote+newline-free injection attempt must be inert when sourced.
h=$(_home h1)
QLAUDE_INSTALL_DIR="/a\"; /usr/bin/touch $tmp/R1_PWNED; #" \
    HOME="$h" SHELL=/bin/sh sh "$tool" ensure-path >/dev/null 2>&1
sh -c '. "'"$h"'/.profile"; true' 2>/dev/null
if ! [ -e "$tmp/R1_PWNED" ]; then st=0; else st=1; fi
t "a7 injection value: appended line is inert when .profile is sourced" 0 $st
# anti-vacuous: the line WAS appended (else the test above proves nothing)
if grep -q '^# qlaude PATH$' "$h/.profile"; then st=0; else st=1; fi
t "  anti-vacuous: block actually appended" 0 $st

# 2. a7: command substitution and backticks must also be inert.
h=$(_home h2)
QLAUDE_INSTALL_DIR='/x$(/usr/bin/touch '"$tmp"'/R2_PWNED)`/usr/bin/touch '"$tmp"'/R2B_PWNED`' \
    HOME="$h" SHELL=/bin/sh sh "$tool" ensure-path >/dev/null 2>&1
sh -c '. "'"$h"'/.profile"; true' 2>/dev/null
if [ ! -e "$tmp/R2_PWNED" ] && [ ! -e "$tmp/R2B_PWNED" ]; then st=0; else st=1; fi
t "a7 \$() and backtick payloads inert at login" 0 $st

# 3. a7 anti-vacuous on the payload side: the UNSAFE pattern would pwn —
# simulate old behaviour by sourcing a hand-written line (proves the probe
# in tests 1-2 can actually detect a hit).
h=$(_home h3)
# shellcheck disable=SC2016  # literal \$PATH on purpose — pre-fix shape
printf 'export PATH="a"; /usr/bin/touch %s/R3_PWNED; #:$PATH\n' "$tmp" >"$h/.profile"
sh -c '. "'"$h"'/.profile"; true' 2>/dev/null
if [ -e "$tmp/R3_PWNED" ]; then st=0; else st=1; fi
t "  probe is live: unescaped line (pre-fix shape) DOES execute" 0 $st

# 4. a7 happy path preserved: absolute dir appears in PATH after sourcing.
h=$(_home h4)
QLAUDE_INSTALL_DIR="$tmp/tools/bin" HOME="$h" SHELL=/bin/sh \
    sh "$tool" ensure-path >/dev/null 2>&1
got=$(sh -c '. "'"$h"'/.profile"; printf %s "$PATH"')
case $got in "$tmp/tools/bin:"*) st=0 ;; *) st=1 ;; esac
t "absolute dir still lands first in PATH (consent model intact)" 0 $st

# 5. a10: ensure-path must REFUSE a relative dir (rc 1) and write nothing.
h=$(_home h5)
before=$(cat "$h/.profile")
QLAUDE_INSTALL_DIR=tools/bin HOME="$h" SHELL=/bin/sh \
    sh "$tool" ensure-path >/dev/null 2>&1
rc=$?
after=$(cat "$h/.profile")
if [ "$rc" -eq 1 ] && [ "$before" = "$after" ]; then st=0; else st=1; fi
t "a10 ensure-path refuses relative QLAUDE_INSTALL_DIR (exit 1, file untouched)" 0 $st
# anti-vacuous: same run with an absolute value succeeds (guard is the RELATIVE check)
QLAUDE_INSTALL_DIR="$tmp/tools/bin" HOME="$h" SHELL=/bin/sh \
    sh "$tool" ensure-path >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^# qlaude PATH$' "$h/.profile"; then st=0; else st=1; fi
t "  anti-vacuous: absolute value passes the same code path" 0 $st

# 6. a10: install.sh must reject a relative INSTALL_DIR BEFORE any fetch.
out=$(cd "$tmp" && QLAUDE_INSTALL_DIR=bin HOME="$tmp/h6" \
    QLAUDE_BASE_URL=http://127.0.0.1:1 QLAUDE_REF=x sh "$inst" 2>&1)
rc=$?
case $out in *absolute*) st=0 ;; *) st=1 ;; esac
if [ "$rc" -ne 0 ] && [ "$st" -eq 0 ]; then st=0; else st=1; fi
t "a10 install.sh rejects relative QLAUDE_INSTALL_DIR pre-fetch" 0 $st
# anti-vacuous: an absolute dir gets PAST validation (fails later, on fetch)
out=$(cd "$tmp" && QLAUDE_INSTALL_DIR="$tmp/h7/bin" HOME="$tmp/h7" \
    QLAUDE_BASE_URL=http://127.0.0.1:1 QLAUDE_REF=x sh "$inst" 2>&1)
rc=$?
case $out in *absolute*) st=1 ;; *) st=0 ;; esac
if [ "$rc" -ne 0 ] && [ "$st" -eq 0 ]; then st=0; else st=1; fi
t "  anti-vacuous: absolute dir is not rejected by the new check" 0 $st

exit "$fail"
