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
if ! grep -q "$_esc" "$tmp/pty.out"; then st=0; else st=1; fi
t "a4 endpoint escape bytes never reach the terminal (preview+prompt filtered)" 0 $st
# anti-vacuous: the transcript really surfaced the endpoint context
if grep -q 'token for' "$tmp/pty.out"; then st=0; else st=1; fi
if grep -q 'preview: keeping' "$tmp/pty.out"; then st=0; else st=1; fi
t "  anti-vacuous: preview line (the echo surface) was captured" 0 $st
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
if ! grep -q "$_esc" "$tmp/pty.out" && grep -q 'token for' "$tmp/pty.out"; then st=0; else st=1; fi
t "a4 token-prompt path: labelled prompt printed, still zero ESC bytes" 0 $st

# --- a5: stty missing => loud refusal, never a silent echoed read.
mkdir -p "$tmp/nostty"
for _tool in mktemp sed cat chmod env uname curl; do
    p=$(command -v "$_tool" 2>/dev/null) && ln -s "$p" "$tmp/nostty/$_tool"
done
printf 'SUPERSECRETTOKEN9z\n' >"$tmp/feed2"
# shellcheck disable=SC2016  # $1/$rc/$X are child-side text, expanded in the child
_pty "$tmp/feed2" env -i PATH="$tmp/nostty" HOME="$tmp" QLAUDE_READY_FILE="$tmp/ready2" \
    "$_dash" -c '. "$1"; : >"${QLAUDE_READY_FILE:-/dev/null}"; _hidden_read X; rc=$?; if [ -n "${X:-}" ]; then echo CAPTURED; fi; echo RC=$rc' tshim "$tool"  # a5 is the dash path (bash has read -s)
# (a) loud: explicit abort message; (b) the token is never READ into a
# variable with ECHO ON (no CAPTURED marker, rc nonzero — abort, not read).
if ! grep -q 'CAPTURED' "$tmp/pty.out" && grep -q 'RC=1' "$tmp/pty.out"; then st=0; else st=1; fi
t "a5 no stty: token is never read with ECHO ON (abort rc=1, nothing captured)" 0 $st
if grep -qi 'cannot hide\|stty' "$tmp/pty.out"; then st=0; else st=1; fi
t "  no-stty path is loud (explicit warning/abort, not silence)" 0 $st

# --- a17: Ctrl-C (\\003) during the dash hidden read must KILL, not fall through.
printf '\003' >"$tmp/feed3"
# shellcheck disable=SC2016  # $1 is child-side text, expanded in the child
_pty "$tmp/feed3" env -i PATH="/usr/bin:/bin" HOME="$tmp" QLAUDE_READY_FILE="$tmp/ready3" \
    "$_dash" -c '. "$1"; : >"${QLAUDE_READY_FILE:-/dev/null}"; _hidden_read X; echo AFTERMARKER' tshim "$tool"
if ! grep -q 'AFTERMARKER' "$tmp/pty.out"; then st=0; else st=1; fi
t "a17 dash Ctrl-C during hidden read kills the script (no fall-through)" 0 $st

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
