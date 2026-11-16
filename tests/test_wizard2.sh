#!/bin/sh
# Wizard suite 2 (final-review fix round, spec §5.4): the interactive wizard
# must ASK context window + effort (showing defaults), --token-stdin must
# keep a newline-less token, and must never echo one when stdin is a tty.
# Separate file: test_setup.sh sits at its 400-line hard cap.
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

[ -n "${QLAUDE_STUB_PORT:-}" ] || { echo "wizard2 test: harness must export QLAUDE_STUB_PORT" >&2; exit 2; }
[ -n "${QLAUDE_CI_TOKEN:-}" ] || { echo "wizard2 test: harness must export QLAUDE_CI_TOKEN" >&2; exit 2; }
base="http://127.0.0.1:$QLAUDE_STUB_PORT"

tmp=$(mktemp -d) || { echo "wizard2 test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat >"$tmp/bin/claude" <<'SHIM'
#!/bin/sh
case "$*" in
    *QLAUDE_TOOL_OK*) echo "QLAUDE_TOOL_OK" ;;
    *) echo "OK"
esac
SHIM
chmod +x "$tmp/bin/claude"
real_curl=$(command -v curl)
mkdir -p "$tmp/curlshim"
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" >> "$SHIM_LOG"' \
    "exec $real_curl \"\$@\"" >"$tmp/curlshim/curl"
chmod +x "$tmp/curlshim/curl"

mkdir -p "$tmp/pconf" "$tmp/pconf2" "$tmp/pconf3"
printf 'appended prompt body\n' >"$tmp/pconf/SYSTEM-PROMPT.md"
printf 'appended prompt body\n' >"$tmp/pconf2/SYSTEM-PROMPT.md"
printf 'appended prompt body\n' >"$tmp/pconf3/SYSTEM-PROMPT.md"

_run() { # confdir argv... — isolated env, stub-reachable, claude shim on PATH
    _cd=$1; shift
    env -i PATH="$tmp/bin:$tmp/curlshim:/usr/bin:/bin" HOME="$tmp" \
        QLAUDE_CONFIG_DIR="$_cd" QLAUDE_INSTALL_DIR="$tmp/bin" \
        SHIM_LOG="$tmp/curl.argv" sh "$tool" setup "$@"
}

_strip_pty() { # pty transcript -> plain text (CR gone, SGR colours gone)
    tr -d '\r' <"$1" | LC_ALL=C sed "s/$(printf '\033')\[[0-9;]*m//g"
}
_pty_run() { # argv: cmd... — child gets a pty; our stdin is fed to it
    python3 -c '
import os, pty, sys
inp = os.read(0, 65536)
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
try:
    os.write(fd, inp)
except OSError:
    pass
out = b""
while True:
    try:
        b = os.read(fd, 4096)
    except OSError:
        break
    if not b:
        break
    out += b
try:
    st = os.waitpid(pid, 0)[1]
except ChildProcessError:
    sys.stdout.buffer.write(out); sys.stdout.buffer.flush(); sys.exit(0)
sys.stdout.buffer.write(out)
sys.stdout.buffer.flush()
sys.exit(st >> 8 if (st & 0xFF) == 0 else 1)
' "$@"
}

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP wizard2 pty tests (python3 missing)"
else
    # 1. Fully interactive (no flags, no -y): spec §5.4 enumerates the
    # questions — endpoint, token, model, CONTEXT WINDOW (shows default),
    # EFFORT. Enter on context must persist the documented 262144 default.
    printf 'http://127.0.0.1:1\nptytoken-9x\nmymodel\n\nxhigh\n' | \
        _pty_run env -i PATH="$tmp/bin:$tmp/curlshim:/usr/bin:/bin" HOME="$tmp" \
            QLAUDE_CONFIG_DIR="$tmp/pconf" QLAUDE_INSTALL_DIR="$tmp/bin" \
            SHIM_LOG="$tmp/curl.argv" sh "$tool" setup \
            >"$tmp/pty.out" 2>&1 || true
    if _strip_pty "$tmp/pty.out" | grep -q 'context window'; then st=0; else st=1; fi
    t "interactive: asks context window (spec §5.4)" 0 $st
    if _strip_pty "$tmp/pty.out" | grep -q 'effort'; then st=0; else st=1; fi
    t "interactive: asks effort (spec §5.4)" 0 $st
    _c=$(grep -n 'context window' "$tmp/pty.out" | head -1 | cut -d: -f1)
    _f=$(grep -n 'effort' "$tmp/pty.out" | head -1 | cut -d: -f1)
    if [ -n "$_c" ] && [ -n "$_f" ] && [ "$_c" -le "$_f" ]; then st=0; else st=1; fi
    t "  questions in spec order (context before effort)" 0 $st
    if [ -f "$tmp/pconf/config.env" ] \
        && grep -qx 'QLAUDE_CONTEXT_TOKENS=262144' "$tmp/pconf/config.env"; then st=0; else st=1; fi
    t "context: Enter accepts the documented 262144 default" 0 $st
    if [ -f "$tmp/pconf/config.env" ] \
        && grep -qx 'QLAUDE_EFFORT=xhigh' "$tmp/pconf/config.env"; then st=0; else st=1; fi
    t "effort: answer persisted to config.env" 0 $st

    # 2. --token-stdin with NO trailing newline (vault/pipeline idiom): the
    # last line must survive EOF (contrast config_parse's || [ -n "$_line" ]).
    printf '%s' "$QLAUDE_CI_TOKEN" | _run "$tmp/pconf2" -y --endpoint "$base" \
        --token-stdin --model my-model --context 8192 --effort high \
        --claude-bin "$tmp/bin/claude" >"$tmp/s2.out" 2>"$tmp/s2.err"
    st=$?
    t "--token-stdin, no trailing newline: run completes" 0 $st
    if [ -f "$tmp/pconf2/config.env" ] \
        && grep -qxF "QLAUDE_TOKEN=$QLAUDE_CI_TOKEN" "$tmp/pconf2/config.env"; then st=0; else st=1; fi
    t "  newline-less token reaches config.env (anti-vacuous)" 0 $st

    # 3. --token-stdin while stdin IS a tty: the terminal echoes typed
    # bytes, so this must route through the hidden read. Anti-vacuous: the
    # intro line proves the transcript was captured, the saved token proves
    # the read actually consumed the typed bytes.
    # Prompt-driven feed (8d lesson): bytes typed before the child reaches
    # the hidden read are echoed by the line discipline no matter what the
    # child does. Wait for the intro, let the read settle, then type.
    python3 -c '
import os, pty, sys, time, select
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
log = b""
mark = 0
while b"qlaude setup:" not in log[mark:]:
    r, _, _ = select.select([fd], [], [], 0.2)
    if not r:
        break
    try:
        log += os.read(fd, 4096)
    except OSError:
        break
time.sleep(0.3)
try:
    os.write(fd, b"ptytok-4f\n")
except OSError:
    pass
while True:
    r, _, _ = select.select([fd], [], [], 5.0)
    if not r:
        break
    try:
        b = os.read(fd, 4096)
    except OSError:
        break
    if not b:
        break
    log += b
sys.stdout.buffer.write(log)
sys.stdout.buffer.flush()
try:
    os.waitpid(pid, 0)
except ChildProcessError:
    pass
' env -i PATH="$tmp/bin:$tmp/curlshim:/usr/bin:/bin" HOME="$tmp" \
        QLAUDE_CONFIG_DIR="$tmp/pconf3" QLAUDE_INSTALL_DIR="$tmp/bin" \
        SHIM_LOG="$tmp/curl.argv" sh "$tool" setup -y --endpoint "$base" \
        --token-stdin --model my-model --context 8192 --effort high \
        --claude-bin "$tmp/bin/claude" >"$tmp/pty3.out" 2>&1 || true
    if ! grep -qF 'ptytok-4f' "$tmp/pty3.out"; then st=0; else st=1; fi
    t "--token-stdin on a tty: token never echoed" 0 $st
    if _strip_pty "$tmp/pty3.out" | grep -q 'qlaude setup:'; then st=0; else st=1; fi
    t "  anti-vacuous: transcript captured (echo surface live)" 0 $st
    if [ -f "$tmp/pconf3/config.env" ] \
        && grep -qxF 'QLAUDE_TOKEN=ptytok-4f' "$tmp/pconf3/config.env"; then st=0; else st=1; fi
    t "  hidden stdin read still captured the token" 0 $st
fi

exit "$fail"
