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

exit "$fail"
