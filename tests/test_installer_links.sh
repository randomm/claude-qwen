#!/bin/sh
# Audit a9 (important): install.sh cp'd onto destinations without checking
# they are regular files and without unlink-before-write — a planted symlink
# (arbitrary-file overwrite + arbitrary chmod as the installer's uid; as root
# for sudo installs) or hardlink (writes through the shared inode) redirected
# the install. Fix: refuse non-regular destinations, rm -f before cp.
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

tmp=$(mktemp -d) || { echo "installer-links test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"; kill "$srv_pid" 2>/dev/null' EXIT

# --- serving tree (same harness shape as test_installer.sh)
srv="$tmp/www/main"
mkdir -p "$srv/bin"
cp "$root/bin/qlaude" "$srv/bin/qlaude"
printf 'the system prompt\n' >"$srv/SYSTEM-PROMPT.md"
mkdir -p "$tmp/tools"
cp "$root/tools/gen-checksum.sh" "$tmp/tools/"
mkdir -p "$tmp/bin"
cp "$root/bin/qlaude" "$tmp/bin/qlaude"
printf 'the system prompt\n' >"$tmp/SYSTEM-PROMPT.md"
(cd "$tmp" && sh tools/gen-checksum.sh >/dev/null) || {
    echo "installer-links test: checksum gen failed" >&2; exit 2; }
cp "$tmp/install.sha256" "$srv/install.sha256"

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
[ -s "$tmp/srv.port" ] || { echo "installer-links test: server down" >&2; exit 2; }
base="http://127.0.0.1:$(cat "$tmp/srv.port")"

victim_dir="$tmp/victims"
mkdir -p "$victim_dir"

_install() { # $1=home $2=installdir $3=confdir
    HOME="$1" QLAUDE_INSTALL_DIR="$2" QLAUDE_CONFIG_DIR="$3" \
        QLAUDE_BASE_URL="$base" QLAUDE_REF=main sh "$installer" 2>&1
}

# 1. symlink at the qlaude destination must be refused; victim untouched.
mkdir -p "$victim_dir"
printf 'victim bashrc content\n' >"$victim_dir/bashrc"
h1="$tmp/h1" ib1="$tmp/i1" ic1="$tmp/c1"
mkdir -p "$h1" "$ib1" "$ic1"
ln -s "$victim_dir/bashrc" "$ib1/qlaude"
out=$(_install "$h1" "$ib1" "$ic1"); rc=$?
: "$out"
if [ "$rc" -ne 0 ] && [ "$(cat "$victim_dir/bashrc")" = 'victim bashrc content' ]; then st=0; else st=1; fi
t "a9 symlink at \$INSTALLDIR/qlaude refused; victim file untouched" 0 $st
if [ -L "$ib1/qlaude" ] && [ "$(readlink "$ib1/qlaude")" = "$victim_dir/bashrc" ]; then
    st=0
else
    st=1
fi
t "  anti-vacuous: planted symlink left in place, not replaced or written through" 0 $st

# 2. symlink at SYSTEM-PROMPT destination refused; victim untouched, no chmod-600 escape.
printf 'victim profile content\n' >"$victim_dir/profile"
h2="$tmp/h2" ib2="$tmp/i2" ic2="$tmp/c2"
mkdir -p "$h2" "$ib2" "$ic2"
ln -s "$victim_dir/profile" "$ic2/SYSTEM-PROMPT.md"
out=$(_install "$h2" "$ib2" "$ic2"); rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$victim_dir/profile")" = 'victim profile content' ]; then st=0; else st=1; fi
t "a9 symlink at SYSTEM-PROMPT.md refused; victim untouched" 0 $st
if [ -f "$victim_dir/profile" ]; then
    if [ "$(stat -c '%a' "$victim_dir/profile")" = 644 ] || [ "$(stat -c '%a' "$victim_dir/profile")" = 664 ]; then st=0; else st=1; fi
    t "  anti-vacuous: victim mode unchanged (no arbitrary chmod)" 0 $st
fi

# 3. hardlink destination: rm-before-write means the victim inode is NOT written through.
printf 'victim hardlink target\n' >"$victim_dir/hl"
h3="$tmp/h3" ib3="$tmp/i3" ic3="$tmp/c3"
mkdir -p "$h3" "$ib3" "$ic3"
ln "$victim_dir/hl" "$ib3/qlaude"
out=$(_install "$h3" "$ib3" "$ic3"); rc=$?
if [ "$(cat "$victim_dir/hl")" = 'victim hardlink target' ]; then st=0; else st=1; fi
t "a9 hardlink destination: victim inode not written through (either refuse or unlink-first)" 0 $st
# and the install itself still succeeded (unlink-then-create, not blanket refuse of files)
if [ "$rc" -eq 0 ] && [ -x "$ib3/qlaude" ]; then st=0; else st=1; fi
t "  regular-file destinations still install (unlink-before-write, not refuse)" 0 $st

# 4. directory at destination is refused, not followed into.
h4="$tmp/h4" ib4="$tmp/i4" ic4="$tmp/c4"
mkdir -p "$h4" "$ib4/qlaude" "$ic4"
out=$(_install "$h4" "$ib4" "$ic4"); rc=$?
if [ "$rc" -ne 0 ]; then st=0; else st=1; fi
t "a9 directory planted at destination is refused" 0 $st

# 5. anti-vacuous overall: clean destinations install fine.
h5="$tmp/h5" ib5="$tmp/i5" ic5="$tmp/c5"
mkdir -p "$h5"
out=$(_install "$h5" "$ib5" "$ic5"); rc=$?
if [ "$rc" -eq 0 ] && [ -x "$ib5/qlaude" ] && [ -f "$ic5/SYSTEM-PROMPT.md" ] \
    && [ "$(stat -c '%a' "$ic5/SYSTEM-PROMPT.md")" = 600 ]; then st=0; else st=1; fi
t "  anti-vacuous: clean install succeeds with correct modes" 0 $st

exit "$fail"
