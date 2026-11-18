#!/bin/sh
# ensure-path suite (plan T6, spec §5.7): marker-block idempotency, foreign
# block refusal, --dry-run touches nothing, shell/OS target table, and the
# honest paste-now hint (bashrc caveat, audit 2026-11-18). Never writes
# outside its marker block.
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

tmp=$(mktemp -d) || { echo "ensure-path test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
# shellcheck disable=SC2016
printf '#!/bin/sh\n[ "$1" = --version ] && echo "9.9.9-mock"\nexit 0\n' >"$tmp/bin/claude"
chmod +x "$tmp/bin/claude"

run_ep() { # run_ep <args...> — ensure-path with SHELL/HOME injected
    env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp/home" \
        SHELL="${SHELL_OVERRIDE:-/bin/bash}" \
        QLAUDE_INSTALL_DIR="$tmp/bin" QLAUDE_CONFIG_DIR="$tmp/conf" \
        sh "$tool" ensure-path "$@"
}
mkdir -p "$tmp/home" "$tmp/conf"

# 1. Linux + bash → ~/.profile. Cross-target hygiene: the zsh rc must NOT
# be touched by a bash-target run (mirror case checked in case 3).
out=$(run_ep 2>&1); st=$?
if [ "$st" -eq 0 ]; then st=0; else st=1; fi
t "ensure-path: exit 0" 0 $st
if [ -f "$tmp/home/.profile" ] && grep -q '# qlaude PATH' "$tmp/home/.profile"; then
    st=0
else
    st=1
fi
t "linux+bash targets ~/.profile with the marker block" 0 $st
if [ ! -e "$tmp/home/.zprofile" ]; then st=0; else st=1; fi
t "linux+bash left the zsh rc alone" 0 $st
if grep -q "$tmp/bin" "$tmp/home/.profile"; then st=0; else st=1; fi
t "block exports the install dir on PATH" 0 $st
# audit 2026-11-18: 'open a new terminal' was a false promise on Linux+bash —
# interactive terminals read ~/.bashrc, not ~/.profile. The hint must state
# the caveat and hand over the paste-now export instead of promising pickup.
if printf '%s\n' "$out" | grep -qi 'bashrc' && printf '%s\n' "$out" | grep -q 'export PATH='; then st=0; else st=1; fi
t "success hint names the bashrc caveat and the paste-now export" 0 $st
if printf '%s\n' "$out" | grep -qi 'open a new terminal'; then st=1; else st=0; fi
t "  no false 'new terminal' promise remains" 0 $st

# 2. Idempotent: second run must leave exactly ONE block.
run_ep >/dev/null 2>&1
_n=$(grep -c '# qlaude PATH' "$tmp/home/.profile")
if [ "$_n" -eq 1 ]; then st=0; else st=1; fi
t "run twice → one marker block (idempotent)" 0 $st

# 3. Never writes anything else: file grows only inside the block.
printf 'export MY_OWN=1\n' >"$tmp/home/.zprofile"
SHELL_OVERRIDE=/bin/zsh run_ep >/dev/null 2>&1
if grep -q 'MY_OWN=1' "$tmp/home/.zprofile"; then st=0; else st=1; fi
t "existing rc content untouched" 0 $st
if grep -q '# qlaude PATH' "$tmp/home/.zprofile"; then st=0; else st=1; fi
t "zsh (Linux) targets ~/.zprofile" 0 $st
_n=$(grep -c '# qlaude PATH' "$tmp/home/.profile")
if [ "$_n" -eq 1 ]; then st=0; else st=1; fi
t "zsh run left the bash rc alone (single-target)" 0 $st

# 4. Foreign block with our markers but different body → refuse, exit 1,
# and NOTHING appended (refuse means never touch, not append-after).
# shellcheck disable=SC2016
printf '# qlaude PATH\nexport PATH=/somewhere/else:$PATH\n# end qlaude PATH\n' \
    >"$tmp/home/.profile"
out=$(run_ep 2>&1); st=$?
if [ "$st" -eq 1 ]; then st=0; else st=1; fi
t "foreign marker block: refuses (exit 1)" 0 $st
if printf '%s\n' "$out" | grep -qi 'refus\|did not write'; then st=0; else st=1; fi
t "foreign marker block: refusal message" 0 $st
if grep -q '/somewhere/else' "$tmp/home/.profile"; then st=0; else st=1; fi
t "foreign block left byte-intact (no overwrite)" 0 $st
_n=$(grep -c '# qlaude PATH' "$tmp/home/.profile")
if [ "$_n" -eq 1 ] && ! grep -q "$tmp/bin" "$tmp/home/.profile"; then st=0; else st=1; fi
t "refuse appends nothing (one block, no install dir leaked in)" 0 $st

# 5. --dry-run prints the change, touches nothing.
rm -f "$tmp/home/.profile"
out=$(run_ep --dry-run 2>&1); st=$?
if [ "$st" -eq 0 ]; then st=0; else st=1; fi
t "--dry-run: exit 0" 0 $st
if printf '%s\n' "$out" | grep -q '# qlaude PATH'; then st=0; else st=1; fi
t "--dry-run: prints the block it would write" 0 $st
if [ ! -f "$tmp/home/.profile" ]; then st=0; else st=1; fi
t "--dry-run: touched nothing" 0 $st

# 5b. Darwin + bash → ~/.zprofile (plan T6 required row, pinned locally
# via a PATH-shimmed uname — mac CI is not an excuse to leave it unpinned).
mkdir -p "$tmp/macbin"
printf '#!/bin/sh\necho Darwin\n' >"$tmp/macbin/uname"
chmod +x "$tmp/macbin/uname"
rm -f "$tmp/home/.zprofile"
env -i PATH="$tmp/macbin:$tmp/bin:/usr/bin:/bin" HOME="$tmp/home" SHELL=/bin/bash \
    QLAUDE_INSTALL_DIR="$tmp/bin" QLAUDE_CONFIG_DIR="$tmp/conf" \
    sh "$tool" ensure-path >/dev/null 2>&1
if [ -f "$tmp/home/.zprofile" ] && grep -q '# qlaude PATH' "$tmp/home/.zprofile"; then
    st=0
else
    st=1
fi
t "darwin+bash (uname shim) targets ~/.zprofile" 0 $st

# 5c. Unwritable rc dir: must fail LOUD — never print success, never exit 0
# (the append's redirect failure must be checked; no set -e here).
rm -f "$tmp/home/.profile"
chmod 500 "$tmp/home"
out=$(run_ep 2>&1); st=$?
chmod 700 "$tmp/home"
if [ "$st" -ne 0 ]; then st=0; else st=1; fi
t "unwritable rc dir: nonzero exit" 0 $st
if printf '%s\n' "$out" | grep -q 'PATH updated'; then st=1; else st=0; fi
t "unwritable rc dir: never claims success" 0 $st
if [ ! -f "$tmp/home/.profile" ]; then st=0; else st=1; fi
t "unwritable rc dir: no phantom file (anti-vacuous)" 0 $st

# 6. config (T6 full form): claude bin version row + shadowed section +
# token source label only, never the value (A4).
printf 'QLAUDE_ENDPOINT=https://models.example.com\nQLAUDE_MODEL=my-model\nQLAUDE_TOKEN=cfg-token-42\n' \
    >"$tmp/conf/config.env"
chmod 600 "$tmp/conf/config.env"
out=$(env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp/home" \
    QLAUDE_CONFIG_DIR="$tmp/conf" QLAUDE_INSTALL_DIR="$tmp/bin" \
    ANTHROPIC_MODEL=whatever CLAUDE_CODE_EFFORT_LEVEL=turbo \
    sh "$tool" config 2>&1)
st=$?
if [ "$st" -eq 0 ]; then st=0; else st=1; fi
t "config full: exit 0" 0 $st
if printf '%s\n' "$out" | grep -q '^token=file-or-env$'; then st=0; else st=1; fi
t "config: token reported as SOURCE only" 0 $st
if printf '%s\n' "$out" | grep -qF 'cfg-token-42'; then st=1; else st=0; fi
t "config: token value never printed (A4)" 0 $st
if printf '%s\n' "$out" | grep -q '^claude_version=9.9.9-mock$'; then st=0; else st=1; fi
t "config: claude_version carries the real --version output" 0 $st
if printf '%s\n' "$out" | grep -q '^shadowed-inherited=ANTHROPIC_MODEL$' && \
   printf '%s\n' "$out" | grep -q '^shadowed-inherited=CLAUDE_CODE_EFFORT_LEVEL$'; then
    st=0
else
    st=1
fi
t "config: shadowed-inherited section (both preset vars)" 0 $st

exit "$fail"
