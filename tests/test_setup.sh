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
    # on the SAME line (no newline emitted after a prompt).
    if tr -d '\r' <"$tmp/pty.out" | grep -q 'route to): qlaude: token'; then
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
    if [ "$_rc" -ne 0 ] && grep -q 'break every launch' "$tmp/pty2.out"; then st=0; else st=1; fi
    t "empty model refused (no empty-model config saved)" 0 $st
    if [ ! -f "$tmp/pconf2/config.env" ]; then st=0; else st=1; fi
    t "empty model: config.env NOT written (anti-vacuous)" 0 $st
else
    echo "SKIP interactive pty tests (python3 missing)"
fi

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
