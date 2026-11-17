#!/bin/sh
# Auto-mode classifier billing (docs 2026-11, auto-mode-classifier-billing):
# an OpenAI-compatible endpoint can never return safeguard_results, so the
# launcher opts the session out of server-side checks (CLAUDE_CODE_AUTO_MODE_SERVER=0)
# and the classifier becomes Claude Code's own — pinned to the user's model.
# QLAUDE_AUTO_MODE_SERVER=on is the pass-through-gateway opt-in (keeps checks
# on so a capable gateway can reach them). Stand-in claude, env-capture only.
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

tmp=$(mktemp -d) || { echo "auto-mode test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat >"$tmp/bin/claude" <<'SHIM'
#!/bin/sh
env >"$SHIM_ENV"
SHIM
chmod +x "$tmp/bin/claude"

conf="$tmp/conf"
mkdir -p "$conf"
cat >"$conf/config.env" <<'CFG'
QLAUDE_ENDPOINT=https://models.example.com
QLAUDE_MODEL=my-model
QLAUDE_TOKEN=launch-token-9f2e
CFG
chmod 600 "$conf/config.env"
printf 'appended prompt body\n' >"$conf/SYSTEM-PROMPT.md"

run_q() { # run_q [EXTRA=VAL...] — launcher, isolated env; caller sets $@ in env
    env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
        QLAUDE_CONFIG_DIR="$conf" QLAUDE_INSTALL_DIR="$tmp/bin" \
        SHIM_ARGV="$tmp/argv" SHIM_ENV="$tmp/env" \
        QLAUDE_DEBUG= \
        "$@" \
        sh "$tool"
}

rm -f "$tmp/env"
run_q QLAUDE_DEBUG=
# anti-vacuous: the child env was captured and carries the contract exports
if grep -q '^CLAUDE_CODE_AUTO_MODE_MODEL=my-model$' "$tmp/env"; then st=0; else st=1; fi
t "anti-vacuous: child env captured with contract exports" 0 $st

# 1. Default: the launcher opts the session out of server-side checks.
if grep -qxF 'CLAUDE_CODE_AUTO_MODE_SERVER=0' "$tmp/env"; then st=0; else st=1; fi
t "default: child gets CLAUDE_CODE_AUTO_MODE_SERVER=0" 0 $st

# 2. The old degradation warning is gone (docs say =0 keeps Claude's own
# classifier; the "approval for every action" claim was wrong).
rm -f "$tmp/ams.err"
run_q QLAUDE_DEBUG= 2>"$tmp/ams.err" || true
if grep -qiE 'degrade|no local fallback|every checked action' "$tmp/ams.err"; then st=1; else st=0; fi
t "no 'degrades to approval-per-action' warning anymore" 0 $st

# 3. qlaude-always-wins: a pre-set CLAUDE_CODE_AUTO_MODE_SERVER=1 is overridden
# to 0 (the endpoint cannot do server checks; contract beats ambient env).
rm -f "$tmp/env"
run_q QLAUDE_DEBUG= CLAUDE_CODE_AUTO_MODE_SERVER=1
if grep -qxF 'CLAUDE_CODE_AUTO_MODE_SERVER=0' "$tmp/env"; then st=0; else st=1; fi
t "pre-set CLAUDE_CODE_AUTO_MODE_SERVER=1: still 0 for the child" 0 $st

# 4. Opt-in (pass-through gateway): env flag on => the switch is left alone.
rm -f "$tmp/env"
run_q QLAUDE_DEBUG= QLAUDE_AUTO_MODE_SERVER=on
if grep -q '^CLAUDE_CODE_AUTO_MODE_SERVER=' "$tmp/env"; then st=1; else st=0; fi
t "QLAUDE_AUTO_MODE_SERVER=on: switch absent for the child" 0 $st

# 5. config.env carries the flag too (file path).
conf2="$tmp/conf2"
mkdir -p "$conf2"
cp "$conf/SYSTEM-PROMPT.md" "$conf2/"
cp "$conf/config.env" "$conf2/config.env"
printf 'QLAUDE_AUTO_MODE_SERVER=on\n' >>"$conf2/config.env"
chmod 600 "$conf2/config.env"
rm -f "$tmp/env"
env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
    QLAUDE_CONFIG_DIR="$conf2" QLAUDE_INSTALL_DIR="$tmp/bin" \
    SHIM_ARGV="$tmp/argv" SHIM_ENV="$tmp/env" QLAUDE_DEBUG= \
    sh "$tool"
if grep -q '^CLAUDE_CODE_AUTO_MODE_SERVER=' "$tmp/env"; then st=1; else st=0; fi
t "config.env QLAUDE_AUTO_MODE_SERVER=on: switch absent" 0 $st

# 6. Precedence: an explicitly-set env QLAUDE_AUTO_MODE_SERVER=off beats the
# file's on (flags>env>file>default, §5.2).
rm -f "$tmp/env"
env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
    QLAUDE_CONFIG_DIR="$conf2" QLAUDE_INSTALL_DIR="$tmp/bin" \
    SHIM_ARGV="$tmp/argv" SHIM_ENV="$tmp/env" QLAUDE_DEBUG= \
    QLAUDE_AUTO_MODE_SERVER=off \
    sh "$tool"
if grep -qxF 'CLAUDE_CODE_AUTO_MODE_SERVER=0' "$tmp/env"; then st=0; else st=1; fi
t "env off beats file on: child gets 0" 0 $st

# 7. Only on|off tolerated: a junk value is not silently read as off-intent —
# the launcher treats anything but on as default-off, and doctor keeps quiet.
rm -f "$tmp/env"
run_q QLAUDE_DEBUG= QLAUDE_AUTO_MODE_SERVER=maybe
if grep -qxF 'CLAUDE_CODE_AUTO_MODE_SERVER=0' "$tmp/env"; then st=0; else st=1; fi
t "junk value is not 'on': default 0 still exported" 0 $st

exit "$fail"
