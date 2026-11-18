#!/bin/sh
# Installer suite (plan T2): install.sh against a local loopback file
# server (explicit QLAUDE_BASE_URL is the only non-HTTPS source the
# installer may ever contact; the default stays HTTPS-only). Proves:
# modes, PATH guidance iff needed, zero rc-file mutation, dash run,
# checksum-abort on a corrupt payload, idempotency (spec §5.6).
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
installer="$root/install.sh"

fail=0
t() {
    if [ "$3" -eq 0 ]; then
        echo "PASS $1"
    else
        echo "FAIL $1"
        fail=1
    fi
}

tmp=$(mktemp -d) || { echo "installer test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"; kill "$srv_pid" 2>/dev/null' EXIT

# --- build a serving tree from the real payload pair
srv="$tmp/www/main"
mkdir -p "$srv/bin"
cp "$root/bin/qlaude" "$srv/bin/qlaude"
printf 'the system prompt\n' >"$srv/SYSTEM-PROMPT.md"
mkdir -p "$tmp/tools" "$tmp/bin"
cp "$root/tools/gen-checksum.sh" "$tmp/tools/"
cp "$root/bin/qlaude" "$tmp/bin/qlaude"
printf 'the system prompt\n' >"$tmp/SYSTEM-PROMPT.md"
(cd "$tmp" && sh tools/gen-checksum.sh >/dev/null) || {
    echo "installer test: could not generate checksums" >&2; exit 2; }
cp "$tmp/install.sha256" "$srv/install.sha256"

# --- loopback file server (port 0 + portfile, stub-style handshake)
srv_pid=''
python3 - "$tmp/www" "$tmp/srv.port" <<'PY' &
import http.server, socketserver, sys, functools
root, portfile = sys.argv[1], sys.argv[2]
h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
srv = socketserver.TCPServer(("127.0.0.1", 0), h)
open(portfile, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
srv_pid=$!
i=0
while [ "$i" -lt 50 ] && [ ! -s "$tmp/srv.port" ]; do i=$((i + 1)); sleep 0.1; done
if [ ! -s "$tmp/srv.port" ]; then
    echo "FAIL server: did not start" >&2
    exit 1
fi
base="http://127.0.0.1:$(cat "$tmp/srv.port")"

# --- fake HOME pre-seeded with rc files, to prove zero rc mutation
home="$tmp/home"
mkdir -p "$home"
for rc in .profile .zprofile .bashrc .zshrc; do
    printf '# pristine\n' >"$home/$rc"
done
rcs_before=$( (cd "$home" && ls -la .profile .zprofile .bashrc .zshrc) \
    | sed 's/[0-9][0-9]:[0-9][0-9]//; s/ \+/ /g' )

run_install() { # env-args... ; runs installer with isolated HOME/dirs
    env -u QLAUDE_MODEL -u QLAUDE_ENDPOINT -u QLAUDE_AUTH \
        HOME="$home" QLAUDE_BASE_URL="$base" QLAUDE_REF=main \
        QLAUDE_INSTALL_DIR="$tmp/bin-i" QLAUDE_CONFIG_DIR="$tmp/conf-i" \
        PATH="$tmp/emptybin:/usr/bin:/bin" \
        "$@" sh "$installer"
}

_pty_installer() { # installer under a pty — tty-only 'next' line becomes observable
    python3 -c '
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
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
    os.waitpid(pid, 0)
except ChildProcessError:
    pass
sys.stdout.buffer.write(out)
sys.stdout.buffer.flush()
' env -u QLAUDE_MODEL -u QLAUDE_ENDPOINT -u QLAUDE_AUTH \
      HOME="$home" QLAUDE_BASE_URL="$base" QLAUDE_REF=main \
      QLAUDE_INSTALL_DIR="$tmp/bin-i" QLAUDE_CONFIG_DIR="$tmp/conf-i" \
      PATH="$tmp/emptybin:/usr/bin:/bin" sh "$installer"
}

# 1. Happy path.
out=$(run_install 2>&1); st=$?
t "install: exit 0" 0 $st
if [ "$(printf '%s' "$out" | grep -c .)" -ge 1 ]; then st=0; else st=1; fi
t "install: prints progress lines" 0 $st

# 2. Modes: 755 on the tool, 600 on the config piece (spec §5.6).
# Fixed, known-safe filenames: ls parsing here is deliberate.
# shellcheck disable=SC2012
if [ -f "$tmp/bin-i/qlaude" ] && [ "$(ls -l "$tmp/bin-i/qlaude" | cut -c2-10)" = "rwxr-xr-x" ]; then st=0; else st=1; fi
t "install: bin/qlaude mode 755" 0 $st
# shellcheck disable=SC2012
if [ -f "$tmp/conf-i/SYSTEM-PROMPT.md" ] && [ "$(ls -l "$tmp/conf-i/SYSTEM-PROMPT.md" | cut -c2-10)" = "rw-------" ]; then st=0; else st=1; fi
t "install: SYSTEM-PROMPT.md mode 600" 0 $st

# 3. PATH guidance printed iff INSTALLDIR missing from PATH.
printf '%s\n' "$out" | grep -qi 'PATH'
t "install: PATH guidance when not on PATH" 0 $?
out2=$(run_install PATH="$tmp/bin-i:/usr/bin:/bin" 2>&1)
if printf '%s\n' "$out2" | grep -qi 'PATH'; then st=1; else st=0; fi
t "install: no PATH guidance when already on PATH" 0 $st
# audit 2026-11-18: the very next command a first-timer copies must run in the
# SAME shell — guidance carries the absolute install path.
if printf '%s\n' "$out" | grep -qE 'PATH.*'"$tmp/bin-i/qlaude"; then st=0; else st=1; fi
t "install: PATH note carries the absolute ensure-path command" 0 $st
if command -v python3 >/dev/null 2>&1; then
    _pty_next=$(_pty_installer 2>&1) || true
    if printf '%s\n' "$_pty_next" | tr -d '\r' | grep -q "$tmp/bin-i/qlaude setup"; then st=0; else st=1; fi
    t "install (tty): 'next' line is copy-paste runnable (absolute path)" 0 $st
fi

# 4. Zero rc-file mutation (C4).
rcs_after=$( (cd "$home" && ls -la .profile .zprofile .bashrc .zshrc) \
    | sed 's/[0-9][0-9]:[0-9][0-9]//; s/ \+/ /g' )
if [ "$rcs_before" = "$rcs_after" ] && ! grep -q qlaude "$home"/.profile "$home"/.zprofile "$home"/.bashrc "$home"/.zshrc 2>/dev/null; then
    st=0
else
    st=1
fi
t "install: rc files untouched (C4)" 0 $st

# 5. Runs clean under dash.
env -u QLAUDE_MODEL HOME="$home" QLAUDE_BASE_URL="$base" QLAUDE_REF=main \
    QLAUDE_INSTALL_DIR="$tmp/bin-d" QLAUDE_CONFIG_DIR="$tmp/conf-d" \
    dash "$installer" >/dev/null 2>&1
t "install: clean run under dash" 0 $?

# 6. Checksum negative: corrupt payload aborts, no half-install (spec §5.6).
printf 'tampered' >>"$srv/bin/qlaude"
out=$(run_install 2>&1); st=$?
if [ "$st" -eq 0 ]; then st=1; else st=0; fi
t "corrupt payload: install fails" 0 $st
printf '%s\n' "$out" | grep -qiE 'corrupt|truncat'
t "corrupt payload: truncation/corruption message" 0 $?
if [ ! -f "$tmp/bin-i/qlaude" ] || [ "$(cat "$tmp/bin-i/qlaude" | tail -c 8)" != "tampered" ]; then st=0; else st=1; fi
t "corrupt payload: no half-install" 0 $st

# 7. Idempotent re-run after fixing the payload.
cp "$root/bin/qlaude" "$srv/bin/qlaude"
run_install >/dev/null 2>&1
t "re-run: idempotent exit 0" 0 $?

# 8. Installed bytes must equal the served payload (no empty/wrong file).
if cmp -s "$tmp/bin-i/qlaude" "$srv/bin/qlaude" && \
   cmp -s "$tmp/conf-i/SYSTEM-PROMPT.md" "$srv/SYSTEM-PROMPT.md"; then st=0; else st=1; fi
t "install: installed bytes match served payload" 0 $st

# 9. QLAUDE_REF is honored: a second ref tree carries distinguishable content.
mkdir -p "$tmp/www/v9.9.9/bin"
cp "$root/bin/qlaude" "$tmp/www/v9.9.9/bin/qlaude"
printf 'ref-pin-marker-prompt\n' >"$tmp/www/v9.9.9/SYSTEM-PROMPT.md"
# the ref tree's checksum must cover its own bytes, not main's
_h1=$(sha256sum "$tmp/www/v9.9.9/bin/qlaude" | cut -d' ' -f1)
_h2=$(sha256sum "$tmp/www/v9.9.9/SYSTEM-PROMPT.md" | cut -d' ' -f1)
{ printf '%s  bin/qlaude\n' "$_h1"; printf '%s  SYSTEM-PROMPT.md\n' "$_h2"; } \
    >"$tmp/www/v9.9.9/install.sha256"
run_install QLAUDE_REF=v9.9.9 \
    QLAUDE_INSTALL_DIR="$tmp/bin-r" QLAUDE_CONFIG_DIR="$tmp/conf-r" >/dev/null 2>&1
st=$?
if [ "$st" -eq 0 ] && grep -q 'ref-pin-marker-prompt' "$tmp/conf-r/SYSTEM-PROMPT.md"; then
    st=0
else
    st=1
fi
t "QLAUDE_REF honored: installed content follows the ref" 0 $st

# 10. Loopback exception must parse the authority, not prefix-match: a
# userinfo URL (http://127.0.0.1:PORT@127.0.0.1:PORT/...) is NOT loopback-safe
# and must be refused outright (userinfo is exactly how the prefix match was
# defeated — curl connects to the host after @).
_hp=${base#http://}
out=$(run_install QLAUDE_BASE_URL="http://${_hp}@${_hp}" \
    QLAUDE_INSTALL_DIR="$tmp/bin-u" QLAUDE_CONFIG_DIR="$tmp/conf-u" 2>&1)
st=$?
if [ "$st" -ne 0 ] && ! [ -f "$tmp/bin-u/qlaude" ]; then st=0; else st=1; fi
t "userinfo loopback URL refused, nothing installed" 0 $st

# 11. curl flags on the HTTPS branch are observable (C3): a PATH shim
# records argv so --proto pinning and -m bounds can be asserted without
# a live TLS server. The shim exits 22 (like a curl 404) after logging.
shim="$tmp/shimbin"
mkdir -p "$shim"
real_curl=$(command -v curl)
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" >> "$SHIM_LOG"' \
    'exec '"$real_curl"' --connect-timeout 1 -o /dev/null https://127.0.0.1:1/ || exit 22' >"$shim/curl"
chmod +x "$shim/curl"
: >"$tmp/https.argv"
SHIM_LOG="$tmp/https.argv" run_install QLAUDE_BASE_URL=https://qlaude.example.invalid \
    PATH="$shim:/usr/bin:/bin" >/dev/null 2>&1
if grep -qxF -- '--proto' "$tmp/https.argv" && grep -qxF -- '=https' "$tmp/https.argv"; then st=0; else st=1; fi
t "https fetch passes --proto pinning" 0 $st
if grep -qx -- '-m' "$tmp/https.argv" || grep -qxF -- '--max-time' "$tmp/https.argv" \
   || grep -qE '^(-m|--max-time)$' "$tmp/https.argv"; then st=0; else st=1; fi
t "https fetch passes a curl -m bound (spec C3)" 0 $st
if grep -qE '^ftp:' "$tmp/https.argv" || grep -qE '^http://' "$tmp/https.argv"; then st=1; else st=0; fi
t "no plain-HTTP/ftp request reaches curl on https base" 0 $st

# 12. Non-HTTPS, non-loopback scheme is refused before curl runs.
out=$(run_install QLAUDE_BASE_URL=ftp://127.0.0.1:21/x \
    QLAUDE_INSTALL_DIR="$tmp/bin-f" QLAUDE_CONFIG_DIR="$tmp/conf-f" 2>&1)
st=$?
if [ "$st" -ne 0 ] && printf '%s\n' "$out" | grep -qiE 'refus|non-https'; then st=0; else st=1; fi
t "ftp base URL refused with a named refusal" 0 $st

# 13-16 (#82, spec §5.6 'offer qlaude setup if TTY' + owner directive one-paste):
# under a TTY the installer runs the existing interview itself via /dev/tty
# (rustup pattern — piped stdin is drained, so the child re-attaches to the
# terminal). Gated off for CI (CI set), for scripts (QLAUDE_NO_SETUP=1) and
# for any non-tty run, which keep the printed 'next' line instead.
_pty_feed() { # feed=$1 extra-env KEY=VAL... ; installer under a pty, answers
# written after a settle; child killed at the window so the suite cannot hang.
    _ff=$1; shift
    python3 -c '
import os, pty, sys, time, select, signal
feed = open(sys.argv[1], "rb").read()
argv = sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
time.sleep(0.6)
try:
    os.write(fd, feed)
except OSError:
    pass
log = b""
t0 = time.time()
dead = False
while time.time() - t0 < 35 and not dead:
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
' "$_ff" env -u QLAUDE_MODEL -u QLAUDE_ENDPOINT -u QLAUDE_AUTH \
      HOME="$home" QLAUDE_BASE_URL="$base" QLAUDE_REF=main \
      QLAUDE_INSTALL_DIR="$tmp/bin-p" QLAUDE_CONFIG_DIR="$tmp/conf-p" \
      QLAUDE_STUB=1 PATH="$tmp/bin-p:/usr/bin:/bin" "$@" \
      sh "$installer" >"$tmp/pty_p.out" 2>&1 || true
}

mkdir -p "$tmp/bin-p"
cat >"$tmp/bin-p/claude" <<'SHIMP'
#!/bin/sh
case "$*" in
    --version) echo "fake-claude 0.0.0" ;;
    *) echo "OK"
esac
SHIMP
chmod +x "$tmp/bin-p/claude"
printf 'http://127.0.0.1:%s\n%s\nstub-model\n\nxhigh\n' \
    "$QLAUDE_STUB_PORT" "$QLAUDE_CI_TOKEN" >"$tmp/feed_p"

[ -n "${QLAUDE_STUB_PORT:-}" ] || { echo "installer test: harness must export QLAUDE_STUB_PORT" >&2; exit 2; }
_pty_feed "$tmp/feed_p" env -u QLAUDE_NO_SETUP -u CI
if tr -d '\r' <"$tmp/pty_p.out" | grep -q 'endpoint URL'; then st=0; else st=1; printf '%s\n' "$(tail -5 "$tmp/pty_p.out")" >&2; fi
t "#82 (tty): installer runs the guided interview itself" 0 $st
if [ -f "$tmp/conf-p/config.env" ] \
    && grep -qxF 'QLAUDE_MODEL=stub-model' "$tmp/conf-p/config.env" \
    && grep -qxF 'QLAUDE_EFFORT=xhigh' "$tmp/conf-p/config.env"; then st=0; else st=1; fi
t "#82 single paste: the fed interview saved a real config.env" 0 $st

# anti-vacuous 1: the documented script escape must keep the installer silent.
_pty_feed "$tmp/feed_p" env -u CI QLAUDE_NO_SETUP=1
if tr -d '\r' <"$tmp/pty_p.out" | grep -q 'endpoint URL'; then st=1; else st=0; fi
t "#82 QLAUDE_NO_SETUP=1: no wizard under a tty (printed next-line only)" 0 $st

# anti-vacuous 2: CI-like environments never get an interactive surprise.
_pty_feed "$tmp/feed_p" env CI=true
if tr -d '\r' <"$tmp/pty_p.out" | grep -q 'endpoint URL'; then st=1; else st=0; fi
t "#82 CI=1: no wizard under a tty" 0 $st

exit "$fail"
