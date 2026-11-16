#!/bin/sh
# Wizard suite (plan T4, spec §5.4): non-TTY etiquette (C9), -y full run,
# atomic 0600 save, token stdin hygiene (never echoed/never argv), authed
# model probe against the enforcing stub, context warning, re-setup preview.
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

[ -n "${QLAUDE_STUB_PORT:-}" ] || { echo "setup test: harness must export QLAUDE_STUB_PORT" >&2; exit 2; }
[ -n "${QLAUDE_CI_TOKEN:-}" ] || { echo "setup test: harness must export QLAUDE_CI_TOKEN" >&2; exit 2; }
base="http://127.0.0.1:$QLAUDE_STUB_PORT"

tmp=$(mktemp -d) || { echo "setup test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

# stand-in claude: answers --version and the gauntlet's -p probes (the
# setup tail runs the real gauntlet since T5); a curl shim logs argv
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

wconf="$tmp/wconf"
mkdir -p "$wconf"
# gauntlet step 0 requires a non-empty SYSTEM-PROMPT.md in CONFDIR
printf 'appended prompt body\n' >"$wconf/SYSTEM-PROMPT.md"

run_setup() { # isolated env; curl shim on PATH records every curl argv
    env -i PATH="$tmp/bin:$tmp/curlshim:/usr/bin:/bin" HOME="$tmp" \
        QLAUDE_CONFIG_DIR="$wconf" QLAUDE_INSTALL_DIR="$tmp/bin" \
        SHIM_LOG="$tmp/curl.argv" \
        sh "$tool" setup "$@"
}

# 1. Non-TTY, no inputs, no -y: exit 1 + usage, never hang (EOF-safe reads).
out=$(run_setup </dev/null 2>&1)
st=$?
if [ "$st" -eq 1 ]; then st=0; else st=1; fi
t "non-TTY bare setup: exit 1" 0 $st
printf '%s\n' "$out" | grep -qi 'usage'
t "non-TTY bare setup: usage printed" 0 $?

# 2. -y with incomplete inputs (no model, probe cannot decide it): exit 1.
out=$(run_setup -y --endpoint "$base" --token-stdin </dev/null 2>&1)
st=$?
if [ "$st" -eq 1 ]; then st=0; else st=1; fi
t "-y incomplete inputs: exit 1, never hang" 0 $st

# 3. Full -y run: saves 0600 config with every key; gauntlet exit passes.
printf '%s\n' "$QLAUDE_CI_TOKEN" | run_setup -y --endpoint "$base" \
    --token-stdin --model my-model --context 8192 --effort high \
    --claude-bin "$tmp/bin/claude" >"$tmp/setup.out" 2>"$tmp/setup.err"
st=$?
t "-y full run: exit 0" 0 $st
# shellcheck disable=SC2012  # fixed known filename
if [ -f "$wconf/config.env" ] && [ "$(ls -l "$wconf/config.env" | cut -c2-10)" = "rw-------" ]; then
    st=0
else
    st=1
fi
# shellcheck disable=SC2012
t "-y full run: config.env written at mode 600" 0 $st
for _k in QLAUDE_ENDPOINT QLAUDE_MODEL QLAUDE_TOKEN QLAUDE_CONTEXT_TOKENS QLAUDE_EFFORT QLAUDE_CLAUDE_BIN; do
    grep -q "^$_k=" "$wconf/config.env" || { st=1; break; }
    st=0
done
t "-y full run: all keys persisted" 0 $st
# atomic write: no temp leftovers in CONFDIR
if find "$wconf" -name '*.tmp*' | grep -q .; then st=1; else st=0; fi
t "-y full run: atomic save (no temp leftovers)" 0 $st

# 4. Token never echoed by setup, never in curl argv (C6/A4).
if grep -qF "$QLAUDE_CI_TOKEN" "$tmp/setup.out" "$tmp/setup.err"; then st=1; else st=0; fi
t "token never echoed in setup output" 0 $st
if grep -qF "$QLAUDE_CI_TOKEN" "$tmp/curl.argv"; then st=1; else st=0; fi
t "token never in curl argv (probe via stdin config)" 0 $st

# 5. Authed model probe: the enforcing stub answered (its model id listed),
# proving the /v1/models request carried the auth header.
if grep -q 'stub-model' "$tmp/setup.out" "$tmp/setup.err"; then st=0; else st=1; fi
t "model probe carried auth (stub listed its id)" 0 $st
# anti-vacuous: the probe must have actually gone through the curl shim
if [ -s "$tmp/curl.argv" ]; then st=0; else st=1; fi
t "probe went through the curl shim (argv log non-empty)" 0 $st

# 6. -y without --context: max-model-len warning (plan T4).
rm -f "$wconf/config.env"
out=$(printf '%s\n' "$QLAUDE_CI_TOKEN" | run_setup -y --endpoint "$base" \
    --token-stdin --model my-model --claude-bin "$tmp/bin/claude" 2>&1)
if printf '%s\n' "$out" | grep -qiE 'context|max-model-len'; then st=0; else st=1; fi
t "-y without --context: warning printed" 0 $st

# 7. Re-setup previews existing values (kept, not silently rewritten).
out=$(printf '%s\n' "$QLAUDE_CI_TOKEN" | run_setup -y --endpoint "$base" \
    --token-stdin --claude-bin "$tmp/bin/claude" 2>&1)
if printf '%s\n' "$out" | grep -q 'my-model'; then st=0; else st=1; fi
t "re-setup previews existing model value" 0 $st

# 8. Unknown flag: usage + exit 1 (C9).
out=$(run_setup --frobnicate </dev/null 2>&1)
st=$?
if [ "$st" -eq 1 ] && printf '%s\n' "$out" | grep -qi 'usage'; then st=0; else st=1; fi
t "unknown flag: usage + exit 1" 0 $st

# 8b (owner UX feedback): the wizard must INTRODUCE itself and ask the
# endpoint BEFORE the token — a blind "token?" with zero context is a bug.
# Non-TTY case pins the intro line (printed before the token gate).
out=$(run_setup </dev/null 2>&1)
if printf '%s\n' "$out" | grep -q 'config.env'; then st=0; else st=1; fi
t "wizard intro names the config file" 0 $st
if printf '%s\n' "$out" | grep -q '0600'; then st=0; else st=1; fi
t "wizard intro states 0600 storage (A4 promise)" 0 $st
# PTY case pins the prompt ORDER: endpoint URL before the token prompt.
# script(1) if present, else a python3 pty driver (python3 is already a
# hard harness prerequisite), else honest SKIP — never a silent pass.
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
if command -v python3 >/dev/null 2>&1; then
    printf 'http://127.0.0.1:1\nptytoken-9x\nmymodel\n' | \
        _pty_run env -i PATH=/usr/bin:/bin HOME="$tmp" \
            QLAUDE_CONFIG_DIR="$tmp/pconf" QLAUDE_INSTALL_DIR="$tmp/bin" \
            sh "$tool" setup >"$tmp/pty.out" 2>&1 || true
    _e=$(grep -n 'endpoint URL' "$tmp/pty.out" | head -1 | cut -d: -f1)
    _tk=$(grep -n 'token for http://127.0.0.1:1' "$tmp/pty.out" | head -1 | cut -d: -f1)
    # -le: with the cursor-preserving prompts both can land on ONE line;
    # endpoint must never come AFTER the token prompt.
    if [ -n "$_e" ] && [ -n "$_tk" ] && [ "$_e" -le "$_tk" ]; then st=0; else st=1; fi
    t "interactive: endpoint asked BEFORE token, token prompt names it" 0 $st
    # cursor UX, proven structurally: with no input pending between the
    # two reads, the NEXT qlaude output must follow the endpoint prompt
    # on the SAME line (no newline emitted after a prompt). Colour is
    # shell-dependent under a pty (dash emits ANSI even with TERM unset),
    # so strip escape sequences before matching, on every host.
    if _strip_pty "$tmp/pty.out" | grep -q 'route to): qlaude: token'; then
        st=0
    else
        st=1
    fi
    t "endpoint prompt keeps the cursor on its own line" 0 $st
    # empty model at the model prompt: must refuse to save, not write a
    # QLAUDE_MODEL= empty value (guard is a new T7-adjacent fix).
    printf 'http://127.0.0.1:1\nptytoken-9x\n\n' | \
        _pty_run env -i PATH=/usr/bin:/bin HOME="$tmp" \
            QLAUDE_CONFIG_DIR="$tmp/pconf2" QLAUDE_INSTALL_DIR="$tmp/bin" \
            sh "$tool" setup >"$tmp/pty2.out" 2>&1
    _rc=$?
    if [ "$_rc" -ne 0 ] && _strip_pty "$tmp/pty2.out" | grep -q 'break every launch'; then
        st=0
    else
        st=1
    fi
    t "empty model refused (no empty-model config saved)" 0 $st
    if [ ! -f "$tmp/pconf2/config.env" ]; then st=0; else st=1; fi
    t "empty model: config.env NOT written (anti-vacuous)" 0 $st
else
    echo "SKIP interactive pty tests (python3 missing)"
fi
# 8c: the hidden token read under DASH explicitly. `read -s` is NOT POSIX —
# dash rejects -s ("Illegal option -s", proven on ubuntu-latest CI where
# /bin/sh IS dash; the host /bin/sh being bash hid this until T8). Pin the
# stty-fallback path on every host: same pty scenario with child = dash.
if command -v python3 >/dev/null 2>&1 && command -v dash >/dev/null 2>&1; then
    printf 'http://127.0.0.1:1\nptytoken-9x\nmymodel\n' | \
        _pty_run env -i PATH=/usr/bin:/bin HOME="$tmp" \
            QLAUDE_CONFIG_DIR="$tmp/dconf" QLAUDE_INSTALL_DIR="$tmp/bin" \
            dash "$tool" >"$tmp/dpty.out" 2>&1
    # rc deliberately NOT asserted: the gauntlet tail exits 2 without a
    # claude binary on PATH (same as 8b's bash case — token-in-config below
    # is the real proof the wizard ran to the save).
    _dp=$(_strip_pty "$tmp/dpty.out")
    if printf '%s\n' "$_dp" | grep -q 'Illegal option'; then st=1
    elif printf '%s\n' "$_dp" | grep -q 'route to): qlaude: token' \
        && printf '%s\n' "$_dp" | grep -q 'qlaude: model'; then st=0
    else st=1; fi
    t "dash wizard: hidden read works (no Illegal option), cursor kept" 0 $st
    # the token must have reached the config (the hidden read got real input)
    if [ -f "$tmp/dconf/config.env" ] \
        && grep -q 'ptytoken-9x' "$tmp/dconf/config.env"; then st=0; else st=1; fi
    t "dash wizard: token actually read into config (anti-vacuous)" 0 $st
else
    echo "SKIP dash pty tests (python3 or dash missing)"
fi
# 8d: hidden-ness proper. The eager-feed driver above can prove flow but not
# concealment (all bytes land while ECHO is still on). This driver feeds each
# line only when its prompt has appeared, so a broken stty -echo / read -s
# leaves the token visibly echoed by the tty. Anti-vacuous: the endpoint line
# IS echoed, proving tty echo is live when the token line goes in unechoed.
# The settle sleep lets stty -echo land after the prompt print but before the
# bytes arrive (sub-ms in practice; 150 ms covers any scheduler).
_pty_seq() { # argv: cmd... — sequential prompt-driven feed, transcript out
    python3 -c '
import os, pty, sys, time, select
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
log = b""
def rd(until, limit=10.0):
    global log
    mark = len(log)
    while until not in log[mark:]:
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            limit -= 0.2
            if limit <= 0:
                return
            continue
        try:
            b = os.read(fd, 4096)
        except OSError:
            return
        if not b:
            return
        log += b
os.write(fd, b"http://127.0.0.1:1\n")
rd(b"token for")
time.sleep(0.15)
os.write(fd, b"ptytoken-9x\n")
rd(b"qlaude: model")
os.write(fd, b"mymodel\n")
rd(b"saved")
sys.stdout.buffer.write(log)
sys.stdout.buffer.flush()
try:
    os.waitpid(pid, 0)
except ChildProcessError:
    pass
' "$@"
}
if command -v python3 >/dev/null 2>&1; then
    for _ch in sh dash; do
        if [ "$_ch" = dash ] && ! command -v dash >/dev/null 2>&1; then
            echo "SKIP sequential echo test (dash child: dash missing)"
            continue
        fi
        _pty_seq env -i PATH=/usr/bin:/bin HOME="$tmp" \
            QLAUDE_CONFIG_DIR="$tmp/seq_$_ch" QLAUDE_INSTALL_DIR="$tmp/bin" \
            "$_ch" "$tool" setup >"$tmp/seq_$_ch.out" 2>&1
        if grep -qF 'ptytoken-9x' "$tmp/seq_$_ch.out"; then st=1; else st=0; fi
        t "hidden token never echoed by the tty ($_ch child)" 0 $st
        if grep -qF 'http://127.0.0.1:1' "$tmp/seq_$_ch.out"; then st=0; else st=1; fi
        t "  anti-vacuous: endpoint line WAS echoed ($_ch, echo is live)" 0 $st
    done
else
    echo "SKIP sequential echo tests (python3 missing)"
fi

# 10. macOS keychain WRITE (spec C6 §5.4): setup on Darwin must store the
# token via `security add-generic-password -U ... -w` with the token on
# STDIN (never argv — G4), keep it out of config.env, and degrade to the
# file with a printed note when the keychain write fails. PATH-shims:
# uname->Darwin + a security shim that persists stdin (round-trip: its
# find-generic-password answers back from that file, so the gauntlet
# tail passes exactly as it would on a real Mac).
mkdir -p "$tmp/macok" "$tmp/macfail"
_real_uname=$(command -v uname)
for _d in "$tmp/macok" "$tmp/macfail"; do
    printf '#!/bin/sh\ncase "$*" in "") echo Darwin;; *) exec %s "$@";; esac\n' \
        "$_real_uname" >"$_d/uname"
done
# shellcheck disable=SC2016  # shim body quotes are intentional (runtime vars)
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" >> "$SEC_ARGV"' \
    'case "$1" in' \
    'add-generic-password) cat >> "$SEC_STDIN"; exit 0;;' \
    'find-generic-password) [ -f "$SEC_STDIN" ] && cat "$SEC_STDIN"; exit 0;;' \
    'esac' 'exit 0' >"$tmp/macok/security"
# shellcheck disable=SC2016  # shim body quotes are intentional (runtime vars)
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" >> "$SEC_ARGV"' \
    'case "$1" in' \
    'add-generic-password) exit 1;;' \
    'find-generic-password) [ -f "$SEC_STDIN" ] && cat "$SEC_STDIN"; exit 0;;' \
    'esac' 'exit 0' >"$tmp/macfail/security"
chmod +x "$tmp"/macok/* "$tmp"/macfail/*
run_mac() { # $1 = shim dir; rest = setup args; token on our stdin
    _shim=$1; shift
    env -i PATH="$_shim:$tmp/bin:$tmp/curlshim:/usr/bin:/bin" HOME="$tmp" \
        QLAUDE_CONFIG_DIR="$wconf" QLAUDE_INSTALL_DIR="$tmp/bin" \
        SEC_ARGV="$tmp/sec.argv" SEC_STDIN="$tmp/sec.stdin" \
        SHIM_LOG="$tmp/curl.argv3" \
        sh "$tool" setup "$@"
}
: >"$tmp/sec.argv"; : >"$tmp/sec.stdin"; rm -f "$wconf/config.env"
out=$(printf '%s\n' "$QLAUDE_CI_TOKEN" | run_mac "$tmp/macok" -y \
    --endpoint "$base" --token-stdin --model my-model \
    --claude-bin "$tmp/bin/claude" 2>&1); _kcrc=$?
if [ "$_kcrc" -eq 0 ]; then st=0; else st=1; fi
t "mac keychain: setup -y exits 0 (round-trip gauntlet passed)" 0 $st
if printf '%s\n' "$out" | grep -q 'Keychain'; then st=0; else st=1; fi
t "mac keychain: printed the keychain note" 0 $st
if [ -f "$wconf/config.env" ] \
    && ! grep -qF "$QLAUDE_CI_TOKEN" "$wconf/config.env"; then st=0; else st=1; fi
t "mac keychain: token NOT left in config.env when keychain holds it" 0 $st
if grep -qF "$QLAUDE_CI_TOKEN" "$tmp/sec.stdin"; then st=0; else st=1; fi
t "mac keychain: token was piped on security stdin (round-trip real)" 0 $st
if ! grep -qF "$QLAUDE_CI_TOKEN" "$tmp/sec.argv"; then st=0; else st=1; fi
t "mac keychain: token NEVER in security argv (C6/G4)" 0 $st
# locked/odd keychain: add fails -> file fallback WITH a printed note.
: >"$tmp/sec.argv"; rm -f "$wconf/config.env" "$tmp/sec.stdin"
out=$(printf '%s\n' "$QLAUDE_CI_TOKEN" | run_mac "$tmp/macfail" -y \
    --endpoint "$base" --token-stdin --model my-model \
    --claude-bin "$tmp/bin/claude" 2>&1); _frc=$?
if [ "$_frc" -eq 0 ] && grep -qF "$QLAUDE_CI_TOKEN" "$wconf/config.env"; then
    st=0
else
    st=1
fi
t "mac keychain: write failure degrades to 0600 file, still exits 0" 0 $st
if printf '%s\n' "$out" | grep -qiE 'fall.?back|file'; then st=0; else st=1; fi
t "mac keychain: degradation printed a note (never silent, never hard-fail)" 0 $st

# 9. Terminal escape injection (security review): a hostile endpoint's
# model ids are SERVER-CONTROLLED — the discovered-models line must not
# carry raw ESC/CR/LF into the terminal. A dedicated shim answers the
# models request with an id containing ESC[31m, without touching the stub.
mkdir -p "$tmp/hostileshim"
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" >> "$SHIM_LOG"' '_in=$(cat)' \
    "case \$_in in *'/v1/models'*) printf '{\"data\":[{\"id\":\"esc\033[31mX\"}]}200'; exit 0;; esac" \
    "printf '%s' \"\$_in\" | exec $real_curl \"\$@\"" >"$tmp/hostileshim/curl"
chmod +x "$tmp/hostileshim/curl"
# token arrives via --token-stdin BEFORE the probe (spec order) — without
# it setup exits at the token gate and the print path never runs.
# The endpoint also arrives hostile (ESC inside QLAUDE_ENDPOINT env): both
# server-controlled id text and the echoed endpoint must be sanitized.
_esc_host=$(printf 'http://hostile\033[31m.invalid')
out=$(printf '%s\n' "$QLAUDE_CI_TOKEN" | \
    env -i PATH="$tmp/bin:$tmp/hostileshim:/usr/bin:/bin" HOME="$tmp" \
    QLAUDE_CONFIG_DIR="$tmp/hconf" QLAUDE_INSTALL_DIR="$tmp/bin" \
    SHIM_LOG="$tmp/hostile.argv" QLAUDE_ENDPOINT="$_esc_host" \
    sh "$tool" setup -y --token-stdin \
    2>&1)
if printf '%s' "$out" | grep -q "$(printf '\033')"; then st=1; else st=0; fi
t "hostile model id: no raw escape byte reaches the terminal" 0 $st
# anti-vacuous: the probe did print (sanitized), so the assertion above
# tested a real print path, not a skipped probe.
if printf '%s\n' "$out" | grep -q 'discovered models'; then st=0; else st=1; fi
t "hostile model id: discovery line was printed (path exercised)" 0 $st

exit "$fail"
