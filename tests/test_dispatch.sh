#!/bin/sh
# Dispatch / etiquette suite: subcommand routing + CLI etiquette (spec C9).
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

# 1. --version prints the version on stdout, exit 0.
out=$(sh "$tool" --version 2>/dev/null)
st=$?
t "version: exit 0" 0 $st
printf '%s\n' "$out" | grep -Eq '[0-9]+\.[0-9]+'
t "version: prints a dotted version on stdout" 0 $?

# 2. --help prints usage on stdout, exit 0.
out=$(sh "$tool" --help 2>/dev/null)
st=$?
t "help: exit 0" 0 $st
printf '%s\n' "$out" | grep -qi 'usage'
t "help: usage text on stdout" 0 $?

# 2b. Pipe form (spec C5/C9: curl ... | sh -s -- --help) must dispatch too:
# with -s there is no $0 path, so an execute guard keyed on basename $0
# silently no-ops the documented install-pipe invocation.
out=$(sh -s -- --help <"$tool" 2>/dev/null)
st=$?
t "pipe form: --help exit 0" 0 $st
printf '%s\n' "$out" | grep -qi 'usage'
t "pipe form: --help prints usage" 0 $?
sh -s -- frobnicate <"$tool" >/dev/null 2>&1
st=$?
t "pipe form: unknown verb exits 1" 1 $((st != 1))

# 3. Unknown subcommand: usage on stderr, exit 1 (non-TTY: never a prompt).
err=$(sh "$tool" frobnicate 2>&1 >/dev/null)
st=$?
t "unknown verb: exit 1" 1 $((st != 1))
printf '%s\n' "$err" | grep -qi 'usage'
t "unknown verb: usage on stderr" 0 $?
if sh "$tool" frobnicate 2>/dev/null | grep -q .; then
    t "unknown verb: stdout stays empty" 1 1
else
    t "unknown verb: stdout stays empty" 0 0
fi

# 4. NO_COLOR: no ANSI escapes in diagnostics.
err=$(NO_COLOR=1 sh "$tool" frobnicate 2>&1 >/dev/null)
if printf '%s' "$err" | grep -q "$(printf '\033')"; then
    t "NO_COLOR: no escape codes when NO_COLOR set" 1 1
else
    t "NO_COLOR: no escape codes when NO_COLOR set" 0 0
fi

# 4c. clig.dev presence rule (spec C9 baseline): colour is suppressed
# whenever NO_COLOR is PRESENT — even empty — and is emitted on a real TTY.
# Exercised under a pty (script) so the non-TTY branch cannot mask it;
# skipped with a visible SKIP line where 'script' does not exist.
pty_run() { # run <cmd> with all its stdio on a fresh pty (python3 is a suite prerequisite)
    python3 -c 'import pty,sys; pty.spawn(sys.argv[1:])' "$@"
}
err=$(TERM=xterm pty_run sh "$tool" frobnicate 2>/dev/null)
if printf '%s' "$err" | grep -q "$(printf '\033')"; then st=0; else st=1; fi
t "colour: real-TTY run emits ANSI diagnostics" 0 $st
# NO_COLOR= is intentional: the presence rule must honour the empty value.
# shellcheck disable=SC1007
err=$(NO_COLOR= TERM=xterm pty_run sh "$tool" frobnicate 2>/dev/null)
if printf '%s' "$err" | grep -q "$(printf '\033')"; then st=1; else st=0; fi
t "NO_COLOR present-but-empty: colour suppressed on TTY" 0 $st

# 5. Known verbs are dispatched, not rejected as unknown: setup routes to
# the wizard (non-TTY without inputs it refuses with its own usage, C9 —
# not the launcher's unknown-verb message).
err=$(sh "$tool" setup </dev/null 2>&1)
if printf '%s\n' "$err" | grep -qi 'unknown command'; then
    t "setup verb is dispatched (reaches the wizard)" 1 1
elif printf '%s\n' "$err" | grep -qi 'no token'; then
    t "setup verb is dispatched (reaches the wizard)" 0 0
else
    t "setup verb is dispatched (reaches the wizard)" 1 1
fi

# 4b. Colour branch forced: with colour enabled, err() emits the escape.
# Sourced by path — it is the tool under test.
# shellcheck disable=SC1090
# C_ERR/C_RESET are consumed by the sourced err() implementation.
# shellcheck disable=SC2034
err_out=$( . "$tool" >/dev/null 2>&1
    C_ERR=$(printf '\033[31m'); C_RESET=$(printf '\033[0m')
    err probe 2>&1 )
if printf '%s' "$err_out" | grep -q "$(printf '\033')"; then
    t "colour branch: err() emits escapes when enabled" 0 0
else
    t "colour branch: err() emits escapes when enabled" 1 1
fi

exit "$fail"
