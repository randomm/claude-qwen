#!/bin/sh
# wiz (real macOS run 2026-11-18): security add-generic-password -w reads its
# password via getpass on /dev/tty — the piped token is NEVER consumed while a
# controlling tty exists, so interactive setup used to stall the user on blind
# 'password data for new item:' / retype prompts (Enter-Enter stored an EMPTY
# item, rc 0 — token_source then lied). Ruling (noni
# wizard-input-picker-keychain-composite): interactive => announced structural
# skip, ZERO security invocations; headless => double-line stdin, read-back
# equality is the only success gate, mismatches scrubbed via delete-generic-
# password. PATH-shims only — never the real security(1), never the network.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
tool="$root/bin/qlaude"

fail=0
t() { if [ "$3" -eq 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

[ -n "${QLAUDE_STUB_PORT:-}" ] || { echo "keychain-mac: harness must export QLAUDE_STUB_PORT" >&2; exit 2; }
[ -n "${QLAUDE_CI_TOKEN:-}" ] || { echo "keychain-mac: harness must export QLAUDE_CI_TOKEN" >&2; exit 2; }
base="http://127.0.0.1:$QLAUDE_STUB_PORT"

tmp=$(mktemp -d) || { echo "keychain-mac: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
printf '#!/bin/sh\ncase "$*" in --version) echo fake-claude 0.0.0;; *) echo OK; esac\n' >"$tmp/bin/claude"
chmod +x "$tmp/bin/claude"
_real_uname=$(command -v uname)

# shims: uname->Darwin; security logs every call, add persists stdin,
# find answers from the persisted value (ok) or a WRONG value (mismatch).
mk_shim_dir() { # $1=dir $2=ok|bad
    mkdir -p "$1"
    printf '#!/bin/sh\ncase "$*" in "") echo Darwin;; *) exec %s "$@";; esac\n' \
        "$_real_uname" >"$1/uname"
    if [ "$2" = ok ]; then
        # shellcheck disable=SC2016  # shim body quotes intentional (runtime vars)
        printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >> "$SEC_CALLS"' \
            'case "$1" in' \
            'add-generic-password) cat >> "$SEC_STDIN"; exit 0;;' \
            'find-generic-password) [ -f "$SEC_STDIN" ] && head -1 "$SEC_STDIN"; exit 0;;' \
            'delete-generic-password) exit 0;;' \
            'esac' 'exit 0' >"$1/security"
    else
        # shellcheck disable=SC2016
        printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >> "$SEC_CALLS"' \
            'case "$1" in' \
            'add-generic-password) : >"$SEC_BADITEM"; exit 0;;' \
            'find-generic-password) [ -f "$SEC_BADITEM" ] && echo NOT-THE-TOKEN; exit 0;;' \
            'delete-generic-password) rm -f "$SEC_BADITEM"; exit 0;;' \
            'esac' 'exit 0' >"$1/security"
    fi
    chmod +x "$1/uname" "$1/security"
}
mk_shim_dir "$tmp/macok" ok
mk_shim_dir "$tmp/macbad" bad

# gauntlet step0 pins SYSTEM-PROMPT.md — the installer writes it, fixtures must too.
mkdir -p "$tmp/cbad" "$tmp/cint"
printf 'appended prompt body\n' >"$tmp/cbad/SYSTEM-PROMPT.md"
printf 'appended prompt body\n' >"$tmp/cint/SYSTEM-PROMPT.md"

# --- headless (setsid: no controlling tty): read-back MISMATCH must scrub the
# half-written item and fall back to the 0600 file, with a printed note.
: >"$tmp/calls.bad"; rm -f "$tmp/sec.stdin"
out=$(printf '%s\n' "$QLAUDE_CI_TOKEN" | setsid -w \
    env -i PATH="$tmp/macbad:$tmp/bin:/usr/bin:/bin" HOME="$tmp" QLAUDE_STUB=1 \
    QLAUDE_CONFIG_DIR="$tmp/cbad" QLAUDE_INSTALL_DIR="$tmp/bin" \
    SEC_CALLS="$tmp/calls.bad" SEC_STDIN="$tmp/sec.stdin" SEC_BADITEM="$tmp/baditem" \
    sh "$tool" setup -y --token-stdin --endpoint "$base" --model m1 --claude-bin "$tmp/bin/claude" 2>&1); _rc=$?
if [ "$_rc" -eq 0 ] && grep -qF "$QLAUDE_CI_TOKEN" "$tmp/cbad/config.env"; then st=0; else st=1; fi
t "headless mismatch: exit 0 + token in the 0600 file (honest fallback)" 0 $st
if grep -q '^delete-generic-password' "$tmp/calls.bad"; then st=0; else st=1; fi
t "headless mismatch: half-written keychain item SCRUBBED (delete called)" 0 $st
if printf '%s\n' "$out" | grep -qiE 'keychain unavailable|fall.?back'; then st=0; else st=1; fi
t "headless mismatch: printed the fallback note (never silent)" 0 $st
if printf '%s\n' "$out" | grep -q 'stored in the macOS Keychain'; then st=1; else st=0; fi
t "  anti-vacuous: mismatch never claims keychain storage" 0 $st
# token never reached argv of security (G4)
if ! grep -qF "$QLAUDE_CI_TOKEN" "$tmp/calls.bad"; then st=0; else st=1; fi
t "headless mismatch: token never in security argv (G4)" 0 $st

# --- interactive (pty => /dev/tty opens): ZERO security invocations, and the
# user is TOLD where the token went and why the keychain is skipped.
command -v python3 >/dev/null 2>&1 || { echo "SKIP interactive-skip pty test (python3 missing)"; exit "$fail"; }
: >"$tmp/calls.int"
printf '%s\n%s\nmymodel\n\n\n' "$base" "$QLAUDE_CI_TOKEN" | \
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
' env -i PATH="$tmp/macok:$tmp/bin:/usr/bin:/bin" HOME="$tmp" QLAUDE_STUB=1 \
    QLAUDE_CONFIG_DIR="$tmp/cint" QLAUDE_INSTALL_DIR="$tmp/bin" \
    SEC_CALLS="$tmp/calls.int" SEC_STDIN="$tmp/sec.stdin2" \
    sh "$tool" setup >"$tmp/int.out" 2>&1 || true
if ! grep -qE '^(add|delete)-generic-password' "$tmp/calls.int"; then st=0; else st=1; fi
t "interactive: ZERO add/delete security invocations (the only prompting calls)" 0 $st
# (read-only find-generic-password prints, never prompts — panel (d) — allowed
# for token_resolve; the blind getpass path lives ONLY in add ... -w.)
if tr -d '\r' <"$tmp/int.out" | grep -qi 'Keychain'; then st=0; else st=1; fi
t "interactive: user is told about the Keychain decision (never a mystery)" 0 $st
if grep -qF "$QLAUDE_CI_TOKEN" "$tmp/cint/config.env" \
    && [ "$(stat -c '%a' "$tmp/cint/config.env" 2>/dev/null || stat -f '%Lp' "$tmp/cint/config.env")" = 600 ]; then st=0; else st=1; fi
t "interactive: token landed in the announced 0600 config file" 0 $st

exit "$fail"
