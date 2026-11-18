#!/bin/sh
# Audit minors a4, a5, a17, a18 (setup/hidden-read surface):
#  a4  — endpoint echoed RAW in the re-setup preview and the token prompt
#        (escape-injection right where the token is about to be typed).
#  a5  — hidden read with stty missing swallows the failure and reads with
#        ECHO ON: the secret lands in the transcript with no warning.
#  a17 — under dash, Ctrl-C during the hidden read falls through to the
#        'no token' message, blaming the user for interrupting.
#  a18 — --token-stdin on a tty blocks on a hidden read with NO prompt:
#        keyboard-only/AT users see a silent hang.
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

[ -n "${QLAUDE_STUB_PORT:-}" ] || { echo "hidden-read test: harness must export QLADE_STUB_PORT" >&2; exit 2; }
[ -n "${QLAUDE_CI_TOKEN:-}" ] || { echo "hidden-read test: harness must export QLADE_CI_TOKEN" >&2; exit 2; }
base="http://127.0.0.1:$QLAUDE_STUB_PORT"
_dash=$(command -v dash 2>/dev/null) || { echo "SKIP hidden-read tests (dash missing — a17 needs it)"; exit 0; }

tmp=$(mktemp -d) || { echo "hidden-read test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
printf '#!/bin/sh\ncase "$*" in\n *QLAUDE_TOOL_OK*) echo QLADE_TOOL_OK ;;\n *) echo OK\nesac\n' >"$tmp/bin/claude"
chmod +x "$tmp/bin/claude"

_esc=$(printf '\033')
_esc_strip() { # remove qlaude's OWN color codes — ESC there is legitimate;
# the a4 defect is ESC bytes coming from DATA (the endpoint value).
    LC_ALL=C sed "s/$(printf '\033')\[[0-9;]*m//g" "$1" >"$1.clean"
}
_pty() { # feed=$1 feedfile cmd... — child gets a pty; feed written after a
# settle delay regardless of output (hidden reads print NOTHING); child is
# killed if it outlives the capture window so the suite cannot hang.
    _ff=$1; shift
    python3 -c '
import os, pty, sys, time, select, signal
feed = open(sys.argv[1], "rb").read()
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[2], sys.argv[2:])
ready = os.environ.get("QLAUDE_READY_FILE", "")
if ready:
    t0 = time.time()
    while not os.path.exists(ready) and time.time() - t0 < 6:
        time.sleep(0.05)
time.sleep(0.6)
try:
    os.write(fd, feed)
except OSError:
    pass
log = b""
t0 = time.time()
dead = False
while time.time() - t0 < 8 and not dead:
    r, _, _ = select.select([fd], [], [], 0.3)
    if r:
        try:
            b = os.read(fd, 4096)
        except OSError:
            break
        if not b:
            break
        log += b
    else:
        try:
            if os.waitpid(pid, os.WNOHANG)[0]:
                dead = True
        except ChildProcessError:
            dead = True
try:
    os.kill(pid, signal.SIGKILL)
except (ProcessLookupError, PermissionError):
    pass
try:
    os.waitpid(pid, 0)
except ChildProcessError:
    pass
sys.stdout.buffer.write(log)
sys.stdout.buffer.flush()
' "$_ff" "$@" >"$tmp/pty.out" 2>&1 || true
}

# --- a4: ESC bytes in a config endpoint must never reach the terminal raw.
conf="$tmp/conf"
mkdir -p "$conf"
printf 'appended prompt body\n' >"$conf/SYSTEM-PROMPT.md"
printf 'QLAUDE_ENDPOINT=%s ] 0 ; pwned\x07\n' "$_esc" >"$conf/config.env"
printf 'QLAUDE_MODEL=stub-model\nQLAUDE_TOKEN=%s\nQLAUDE_CLAUDE_BIN=%s/claude\n' \
    "$QLAUDE_CI_TOKEN" "$tmp/bin" >>"$conf/config.env"
chmod 600 "$conf/config.env"
printf 'tok123\n' >"$tmp/feed1"
_pty "$tmp/feed1" env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
    QLAUDE_CONFIG_DIR="$conf" QLAUDE_STUB=1 sh "$tool" setup -y </dev/null
_esc_strip "$tmp/pty.out"
if ! grep -q "$_esc" "$tmp/pty.out.clean"; then st=0; else st=1; fi
t "a4 endpoint escape bytes never reach the terminal (preview+prompt filtered)" 0 $st
# anti-vacuous: the transcript really surfaced the endpoint context
if grep -q 'token for' "$tmp/pty.out"; then st=0; else st=1; fi
if grep -q 'preview: keeping' "$tmp/pty.out"; then st=0; else st=1; fi
t "  anti-vacuous: preview line (the echo surface) was captured" 0 $st
# a4 extension (four-lens audit 2026-11-18): MODEL and CLAUDE_BIN config
# values echoed RAW by the re-setup preview / not-found message — OSC 52
# clipboard + title injection from a hostile config.env (same attacker class
# the config-is-data hardening defends against; endpoint was filtered, these
# were not).
conf4="$tmp/conf4"
mkdir -p "$conf4"
printf 'appended prompt body\n' >"$conf4/SYSTEM-PROMPT.md"
{ # SC2129: one redirect for the whole hostile-value fixture
printf 'QLAUDE_ENDPOINT=%s\n' "$base"
printf 'QLAUDE_MODEL=x\033]52;c;dGVzdA==\007pwned\n'
printf 'QLAUDE_CLAUDE_BIN=%s/claude\033]0;t\007x\n' "$tmp/bin"
printf 'QLAUDE_TOKEN=whatever\n'
} >"$conf4/config.env"
chmod 600 "$conf4/config.env"
: >/dev/null
printf '%s' "$QLAUDE_CI_TOKEN" | env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
    QLAUDE_CONFIG_DIR="$conf4" QLAUDE_INSTALL_DIR="$tmp/bin" \
    sh "$tool" setup -y --endpoint "$base" --token-stdin 2>"$tmp/a4b.err" || true
_esc_strip "$tmp/a4b.err"
if ! grep -q "$_esc" "$tmp/a4b.err.clean"; then st=0; else st=1; fi
t "a4 ext: no raw ESC from MODEL/CLAUDE_BIN echoes (OSC injection blocked)" 0 $st
if grep -q 'preview: keeping QLAUDE_MODEL' "$tmp/a4b.err.clean" \
    && grep -q 'claude bin' "$tmp/a4b.err.clean"; then st=0; else st=1; fi
t "  anti-vacuous: both echo surfaces really printed" 0 $st

# prompt-path variant: config WITHOUT a token line forces the labelled prompt.
conf3="$tmp/conf3"
mkdir -p "$conf3"
printf 'appended prompt body\n' >"$conf3/SYSTEM-PROMPT.md"
printf 'QLAUDE_ENDPOINT=%s ] 0 ; pwned\x07\nQLAUDE_MODEL=stub-model\nQLAUDE_CLAUDE_BIN=%s/claude\n' \
    "$_esc" "$tmp/bin" >"$conf3/config.env"
chmod 600 "$conf3/config.env"
printf 'tok123\n' >"$tmp/feed1b"
_pty "$tmp/feed1b" env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
    QLAUDE_CONFIG_DIR="$conf3" QLAUDE_STUB=1 sh "$tool" setup -y
_esc_strip "$tmp/pty.out"
if ! grep -q "$_esc" "$tmp/pty.out.clean" && grep -q 'token for' "$tmp/pty.out"; then st=0; else st=1; fi
t "a4 token-prompt path: labelled prompt printed, still zero ESC bytes" 0 $st

# --- a5 (retargeted to the raw-mode machinery): stty missing => loud refusal,
# never a silent echoed read. Unit: _tty_raw must FAIL when it cannot set state.
mkdir -p "$tmp/nostty"
for _tool in mktemp sed cat chmod env uname curl; do
    p=$(command -v "$_tool" 2>/dev/null) && ln -s "$p" "$tmp/nostty/$_tool"
done
printf 'SUPERSECRETTOKEN9z\n' >"$tmp/feed2"
# shellcheck disable=SC2016  # $1/$rc/$X are child-side text, expanded in the child
_pty "$tmp/feed2" env -i PATH="$tmp/nostty" HOME="$tmp" QLAUDE_READY_FILE="$tmp/ready2" \
    "$_dash" -c '. "$1"; : >"${QLAUDE_READY_FILE:-/dev/null}"; _tty_raw; rc=$?; echo RC=$rc' tshim "$tool"  # a5 is the dash path (bash has read -s)
# (a) unit: _tty_raw aborts (rc nonzero) instead of half-entering raw mode.
if grep -q 'RC=0' "$tmp/pty.out"; then st=1; else st=0; fi
t "a5 no stty: _tty_raw refuses (nonzero rc, no half-raw state)" 0 $st
# (b) setup-level: the interview must abort LOUDLY and never echo the typed secret.
# shellcheck disable=SC2016  # $1/$? are child-side text, expanded in the child
_pty "$tmp/feed2" env -i PATH="$tmp/nostty" HOME="$tmp" QLAUDE_READY_FILE="$tmp/ready2b" \
    "$_dash" -c '"$1" setup -y --token-stdin --endpoint http://127.0.0.1:9 --model m; echo RC=$?' x "$tool"
if grep -q 'RC=2' "$tmp/pty.out" && ! grep -qF SUPERSECRETTOKEN9z "$tmp/.config/qlaude/config.env" 2>/dev/null; then st=0; else st=1; fi
t "a5 no stty: setup aborts rc=2 — nothing read, no config written" 0 $st
if grep -qi 'cannot hide\|stty' "$tmp/pty.out"; then st=0; else st=1; fi
t "  no-stty path is loud (explicit warning/abort, not silence)" 0 $st

# --- a17 (retargeted): Ctrl-C (\\003) during a _read_line must KILL, not fall
# through into the next prompt with a half-typed value.
printf '\003' >"$tmp/feed3"
# shellcheck disable=SC2016  # $1 is child-side text, expanded in the child
_pty "$tmp/feed3" env -i PATH="/usr/bin:/bin" HOME="$tmp" QLAUDE_READY_FILE="$tmp/ready3" \
    "$_dash" -c '. "$1"; : >"${QLAUDE_READY_FILE:-/dev/null}"; _tty_raw; _read_line 1; echo AFTERMARKER' tshim "$tool"
if ! grep -q 'AFTERMARKER' "$tmp/pty.out"; then st=0; else st=1; fi
t "a17 dash Ctrl-C during _read_line kills the script (no fall-through)" 0 $st

# --- wiz (real-run UX, noni wizard-input-picker-keychain-composite): the
# per-char editor must give feedback — stars for secrets, real echo for
# visible fields, working backspace — and _tty_restore must hand back a
# NORMAL terminal (claude must never inherit a blind non-canonical tty).
# wiz-1 starred secret: '******' on screen, bytes only in the result marker.
printf 'tok123\n' >"$tmp/feedw1"
# shellcheck disable=SC2016  # $1 is child-side text, expanded in the child
_pty "$tmp/feedw1" env -i PATH="/usr/bin:/bin" HOME="$tmp" QLAUDE_READY_FILE="$tmp/readyw1" \
    "$_dash" -c '. "$1"; : >"${QLAUDE_READY_FILE:-/dev/null}"; _tty_raw; _read_line 1; echo RL=[$_rl_out]' tshim "$tool"
_pre=$(sed 's/RL=.*//' "$tmp/pty.out")
if printf '%s' "$_pre" | grep -q '\*\*\*\*\*\*' && ! printf '%s' "$_pre" | grep -q 'tok123' \
    && grep -q 'RL=\[tok123\]' "$tmp/pty.out"; then st=0; else st=1; fi
t "wiz-1 token read: every char echoes as '*' (>=6 stars), bytes never shown" 0 $st
# wiz-2 visible typing: chars appear live, BEFORE the result marker.
printf 'hello17\n' >"$tmp/feedw2"
# shellcheck disable=SC2016
_pty "$tmp/feedw2" env -i PATH="/usr/bin:/bin" HOME="$tmp" QLAUDE_READY_FILE="$tmp/readyw2" \
    "$_dash" -c '. "$1"; : >"${QLAUDE_READY_FILE:-/dev/null}"; _tty_raw; _read_line 0; echo RL=[$_rl_out]' tshim "$tool"
_pre=$(sed 's/RL=.*//' "$tmp/pty.out")
if printf '%s' "$_pre" | grep -q 'hello17' && grep -q 'RL=\[hello17\]' "$tmp/pty.out"; then st=0; else st=1; fi
t "wiz-2 visible read: typed chars echo live on the prompt line" 0 $st
# wiz-3 backspace truly erases: a b DEL c Enter -> value 'ac'.
printf 'ab\177c\n' >"$tmp/feedw3"
# shellcheck disable=SC2016
_pty "$tmp/feedw3" env -i PATH="/usr/bin:/bin" HOME="$tmp" QLAUDE_READY_FILE="$tmp/readyw3" \
    "$_dash" -c '. "$1"; : >"${QLAUDE_READY_FILE:-/dev/null}"; _tty_raw; _read_line 1; echo RL=[$_rl_out]' tshim "$tool"
if grep -q 'RL=\[ac\]' "$tmp/pty.out"; then st=0; else st=1; fi
t "wiz-3 DEL erases a starred char (value is 'ac', not 'ab<c>')" 0 $st
# wiz-4 restore returns the tty to canonical echo (the exec contract).
printf 'x\n' >"$tmp/feedw4"
# shellcheck disable=SC2016
_pty "$tmp/feedw4" env -i PATH="/usr/bin:/bin" HOME="$tmp" QLAUDE_READY_FILE="$tmp/readyw4" \
    "$_dash" -c '. "$1"; : >"${QLAUDE_READY_FILE:-/dev/null}"; _tty_raw; _tty_restore; stty -a; echo DONE' tshim "$tool"
if grep -q 'DONE' "$tmp/pty.out" \
    && ! grep -qE '(^|[[:space:]])-echo([[:space:]]|$)' "$tmp/pty.out" \
    && ! grep -qE '(^|[[:space:]])-icanon([[:space:]]|$)' "$tmp/pty.out"; then st=0; else st=1; fi
t "wiz-4 _tty_restore: stty -a shows echo+icanon back (no blind tty for claude)" 0 $st

# --- a18: --token-stdin on a tty must LABEL the hidden read.
conf4="$tmp/conf4"
mkdir -p "$conf4"
printf 'appended prompt body\n' >"$conf4/SYSTEM-PROMPT.md"
printf 'tok456\n' >"$tmp/feed4"
_pty "$tmp/feed4" env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
    QLAUDE_CONFIG_DIR="$conf4" QLAUDE_INSTALL_DIR="$tmp/bin" QLAUDE_STUB=1 \
    sh "$tool" setup -y --endpoint "$base" --token-stdin --model stub-model \
    --context 8192 --effort medium --claude-bin "$tmp/bin/claude"
if grep -qi 'token via stdin' "$tmp/pty.out"; then st=0; else st=1; fi
t "a18 --token-stdin on a tty: hidden read is labelled by a prompt" 0 $st
# anti-vacuous: transcript captured (setup header present)
if grep -q 'qlaude setup:' "$tmp/pty.out"; then st=0; else st=1; fi
if grep -q 'qlaude setup:' "$tmp/pty.out"; then st=0; else st=1; fi
t "  anti-vacuous: transcript captured (header present)" 0 $st

exit "$fail"
