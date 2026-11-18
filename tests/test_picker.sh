#!/bin/sh
# wiz (real-run UX fix, noni wizard-input-picker-keychain-composite): after
# the model probe lists ids, the user must not be forced to RE-TYPE them.
# Single discovery => Enter accepts; multiple => numbered menu, Enter = 1,
# out-of-range digit => visible error + falls back to 1; probe failure =>
# free-text id still works (escape hatch). Offline: a second stub instance
# with QLAUDE_STUB_MODELS (run_tests' shared stub keeps the single default).
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
tool="$root/bin/qlaude"

fail=0
t() { if [ "$3" -eq 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

[ -n "${QLAUDE_STUB_PORT:-}" ] || { echo "picker: harness must export QLAUDE_STUB_PORT" >&2; exit 2; }
[ -n "${QLAUDE_CI_TOKEN:-}" ] || { echo "picker: harness must export QLAUDE_CI_TOKEN" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP picker pty tests (python3 missing)"; exit 0; }

tmp=$(mktemp -d) || { echo "picker: mktemp -d failed" >&2; exit 2; }
mpid=''
# Invoked indirectly via the EXIT trap.
# shellcheck disable=SC2329
cleanup() { [ -n "$mpid" ] && kill "$mpid" 2>/dev/null; rm -rf "$tmp"; return 0; }
trap cleanup EXIT

# --- second stub: multi-model list (auth env inherited from run_tests)
export QLAUDE_STUB_MODELS='alpha-one, beta-two'
export QLAUDE_STUB_PORTFILE="$tmp/multi.port"
python3 "$here/stub_server.py" &
mpid=$!
i=0
while [ "$i" -lt 50 ] && [ ! -s "$tmp/multi.port" ]; do i=$((i + 1)); sleep 0.1; done
[ -s "$tmp/multi.port" ] || { echo "FAIL picker: multi-model stub did not start"; exit 1; }
mbase="http://127.0.0.1:$(cat "$tmp/multi.port")"

mkdir -p "$tmp/bin"
printf '#!/bin/sh\ncase "$*" in --version) echo fake-claude 0.0.0;; *) echo OK; esac\n' >"$tmp/bin/claude"
chmod +x "$tmp/bin/claude"

_pty_run() { # argv: cmd... — child gets a pty; our stdin is the feed (run after settle)
    python3 -c '
import os, pty, sys, time
inp = os.read(0, 65536)
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
time.sleep(0.4)
try:
    os.write(fd, inp)
except OSError:
    pass
out = b""
t0 = time.time()
while time.time() - t0 < 20:
    try:
        b = os.read(fd, 4096)
    except OSError:
        break
    if not b:
        break
    out += b
try:
    os.kill(pid, 9)
except OSError:
    pass
sys.stdout.buffer.write(out); sys.stdout.buffer.flush()
' "$@"
}
_strip_pty() { tr -d '\r' <"$1" | LC_ALL=C sed "s/$(printf '\033')\[[0-9;]*m//g"; }

# --- 1. multi: numbered menu, pick 2 => beta-two saved (no re-typing)
: >"$tmp/p1.out"
printf '%s\n%s\n2\n\n\n' "$mbase" "$QLAUDE_CI_TOKEN" | \
    _pty_run env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" QLAUDE_STUB=1 \
    QLAUDE_CONFIG_DIR="$tmp/c1" QLAUDE_INSTALL_DIR="$tmp/bin" \
    sh "$tool" setup >"$tmp/p1.out" 2>&1 || true
_strip_pty "$tmp/p1.out" >"$tmp/p1.clean"
if grep -q '1) alpha-one' "$tmp/p1.clean" && grep -q '2) beta-two' "$tmp/p1.clean"; then st=0; else st=1; fi
t "menu: discovered ids listed numbered (no re-typing required)" 0 $st
if [ -f "$tmp/c1/config.env" ] && grep -q '^QLAUDE_MODEL=beta-two$' "$tmp/c1/config.env"; then st=0; else st=1; fi
t "menu: picking '2' saves beta-two verbatim" 0 $st
# --- 2. multi: Enter (empty) accepts 1
printf '%s\n%s\n\n\n\n' "$mbase" "$QLAUDE_CI_TOKEN" | \
    _pty_run env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" QLAUDE_STUB=1 \
    QLAUDE_CONFIG_DIR="$tmp/c2" QLAUDE_INSTALL_DIR="$tmp/bin" \
    sh "$tool" setup >"$tmp/p2.out" 2>&1 || true
if [ -f "$tmp/c2/config.env" ] && grep -q '^QLAUDE_MODEL=alpha-one$' "$tmp/c2/config.env"; then st=0; else st=1; fi
t "menu: Enter with no input accepts model 1" 0 $st
# --- 3. multi: out-of-range digit => visible error, then model 1
printf '%s\n%s\n9\n\n\n' "$mbase" "$QLAUDE_CI_TOKEN" | \
    _pty_run env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" QLAUDE_STUB=1 \
    QLAUDE_CONFIG_DIR="$tmp/c3" QLAUDE_INSTALL_DIR="$tmp/bin" \
    sh "$tool" setup >"$tmp/p3.out" 2>&1 || true
_strip_pty "$tmp/p3.out" >"$tmp/p3.clean"
if grep -qiE 'not (one of|listed|a listed)|invalid' "$tmp/p3.clean" \
    && [ -f "$tmp/c3/config.env" ] && grep -q '^QLAUDE_MODEL=alpha-one$' "$tmp/c3/config.env"; then st=0; else st=1; fi
t "menu: '9' of 2 => visible complaint + falls back to 1 (no sed spam)" 0 $st
# anti-vacuous: no GNU sed 'invalid usage of line address' leaked to the user
if grep -qi 'invalid usage of line address' "$tmp/p3.clean"; then st=1; else st=0; fi
t "  anti-vacuous: digit input never reaches sed raw" 0 $st
# --- 4. single (default stub): Enter accepts the one discovered id
: >"$tmp/p4.out"
printf '%s\n%s\n\n\n\n' "http://127.0.0.1:$QLAUDE_STUB_PORT" "$QLAUDE_CI_TOKEN" | \
    _pty_run env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" QLAUDE_STUB=1 \
    QLAUDE_CONFIG_DIR="$tmp/c4" QLAUDE_INSTALL_DIR="$tmp/bin" \
    sh "$tool" setup >"$tmp/p4.out" 2>&1 || true
if [ -f "$tmp/c4/config.env" ] && grep -q '^QLAUDE_MODEL=stub-model$' "$tmp/c4/config.env"; then st=0; else st=1; fi
t "single: Enter accepts the only discovered id (the transcript complaint)" 0 $st
# --- 5. probe unreachable: free-text id still entered, saved verbatim
printf 'http://127.0.0.1:1\n%s\ncustom-model-x\n\n\n' "$QLAUDE_CI_TOKEN" | \
    _pty_run env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" QLAUDE_STUB=1 \
    QLAUDE_CONFIG_DIR="$tmp/c5" QLAUDE_INSTALL_DIR="$tmp/bin" \
    sh "$tool" setup >"$tmp/p5.out" 2>&1 || true
if [ -f "$tmp/c5/config.env" ] && grep -q '^QLAUDE_MODEL=custom-model-x$' "$tmp/c5/config.env"; then st=0; else st=1; fi
t "escape hatch: unreachable probe still takes a typed id" 0 $st
# --- 6. the discovered/401 notes stay UNCONDITIONAL (print even with --model)
out=$(printf '%s\n' "$QLAUDE_CI_TOKEN" | env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
    QLAUDE_STUB=1 QLAUDE_CONFIG_DIR="$tmp/c6" QLAUDE_INSTALL_DIR="$tmp/bin" \
    sh "$tool" setup -y --token-stdin --endpoint http://127.0.0.1:1 --model m1 \
    --claude-bin "$tmp/bin/claude" 2>&1) || true
if printf '%s\n' "$out" | grep -q 'model probe unreachable'; then st=0; else st=1; fi
t "note: probe-unreachable printed even though --model was supplied" 0 $st

exit "$fail"
