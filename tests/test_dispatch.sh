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

# 4c. Owner ruling (noni 2026-11-18-nocolor-empty-equals-unset, supersedes
# the presence-only reading): an EMPTY NO_COLOR equals unset — colour is
# still emitted on a real TTY. Only a NON-EMPTY NO_COLOR suppresses.
# Exercised under a pty so the non-TTY branch cannot mask either direction.
pty_run() { # run <cmd> with all its stdio on a fresh pty (python3 is a suite prerequisite)
    python3 -c 'import pty,sys; pty.spawn(sys.argv[1:])' "$@"
}
err=$(TERM=xterm pty_run sh "$tool" frobnicate 2>/dev/null)
if printf '%s' "$err" | grep -q "$(printf '\033')"; then st=0; else st=1; fi
t "colour: real-TTY run emits ANSI diagnostics" 0 $st
# shellcheck disable=SC1007
err=$(NO_COLOR= TERM=xterm pty_run sh "$tool" frobnicate 2>/dev/null)
if printf '%s' "$err" | grep -q "$(printf '\033')"; then st=0; else st=1; fi
t "NO_COLOR empty: colour STILL emitted on TTY (empty equals unset)" 0 $st
err=$(NO_COLOR=1 TERM=xterm pty_run sh "$tool" frobnicate 2>/dev/null)
if printf '%s' "$err" | grep -q "$(printf '\033')"; then st=1; else st=0; fi
t "NO_COLOR=1 on real TTY: colour suppressed (the real gate)" 0 $st

# 5. Known verbs are dispatched, not rejected as unknown: setup routes to
# the wizard (non-TTY without inputs it refuses with its own usage, C9).
# Review finding: 'no token' is NOT wizard-specific — the launcher's
# missing-token error says the same thing, so misrouting setup to
# cmd_launch kept the old assertion green. Pin a string only the wizard
# prints ('usage: qlaude setup') plus its refusal exit code.
# Isolated HOME/CONFDIR: the wizard's refusal must not depend on whether
# the machine running the suite happens to have a qlaude config.
err=$(env -i PATH=/usr/bin:/bin HOME=/nonexistent-qlaude-test \
    sh "$tool" setup </dev/null 2>&1)
st=$?
if [ "$st" -eq 1 ] && printf '%s\n' "$err" | grep -qi 'usage: qlaude setup'; then
    t "setup verb is dispatched (reaches the wizard)" 0 0
else
    t "setup verb is dispatched (reaches the wizard)" 1 1
fi
# 5b. Config-present companion: with a full config on disk, cmd_launch
# would NOT fall through to the wizard — so the wizard's own refusal of a
# bogus flag (usage + exit 1) is a routing signal misrouting cannot fake.
_home5b=$(mktemp -d)
mkdir -p "$_home5b/.config/qlaude"
printf 'QLAUDE_ENDPOINT=https://models.example.com\nQLAUDE_MODEL=m\nQLAUDE_TOKEN=t\n' \
    >"$_home5b/.config/qlaude/config.env"
err5b=$(env -i PATH=/usr/bin:/bin HOME="$_home5b" \
    sh "$tool" setup --definitely-not-a-flag </dev/null 2>&1)
st5b=$?
rm -rf "$_home5b"
if [ "$st5b" -eq 1 ] && printf '%s\n' "$err5b" | grep -qi 'usage: qlaude setup'; then
    t "setup verb is dispatched even with config present" 0 0
else
    t "setup verb is dispatched even with config present" 1 1
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
