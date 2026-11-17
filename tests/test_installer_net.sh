#!/bin/sh
# Audit a11 + a12 (minor, install.sh):
#  a11  — the loopback http fetch used curl -L with no --proto restriction:
#         a process on the loopback port (or a port-binding race) could
#         REDIRECT the 'loopback-only' test install to any other origin.
#         Fix: no redirect-following on the http branch + --proto '=http'.
#  a12  — dash does not run the EXIT trap on SIGTERM/SIGINT (POSIX allows
#         this), so Ctrl-C during the 30s fetch leaks the mktemp work dir
#         (with fetched payload copies) in TMPDIR forever.
#         Fix: trap 'cleanup; exit 130' INT TERM alongside EXIT.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
installer="$root/install.sh"
command -v dash >/dev/null 2>&1 || { echo "SKIP installer-net (dash missing — a12 needs it)"; exit 0; }

fail=0
t() {
    if [ "$3" -eq 0 ]; then
        echo "PASS $1"
    else
        echo "FAIL $1"
        fail=1
    fi
}

tmp=$(mktemp -d) || { echo "installer-net test: mktemp -d failed" >&2; exit 2; }
trap 'kill $(cat "$tmp/pids" 2>/dev/null) 2>/dev/null; rm -rf "$tmp"' EXIT
: >"$tmp/pids"

# --- a11: redirector A (loopback) 302s everything to evil B (loopback, other port).
mkdir -p "$tmp/www/main"
python3 - "$tmp/www" "$tmp/A.port" "$tmp/A.hits" "$tmp/B.port" "$tmp/B.hits" <<'PY' &
import http.server, socketserver, sys, functools, threading, os
www, pa, ha, pb, hb = sys.argv[1:6]
class Evil(http.server.BaseHTTPRequestHandler):
    # serves a self-consistent EVIL trio on /test/...
    def do_GET(self):
        with open(hb, "a") as f: f.write("x\n")
        body = {"qlaude": "#!/bin/sh\necho EVIL_PWNED\n",
                "SYSTEM-PROMPT.md": "evil\n"}.get(self.path.rsplit("/", 1)[-1])
        if body is None:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body.encode())
    def log_message(self, *a): pass
class Redirector(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(ha, "a") as f: f.write("x\n")
        self.send_response(302)
        with open(pb) as f:
            real = f.read().strip()
        self.send_header("Location", "http://127.0.0.1:%s%s" % (real, self.path))
        self.end_headers()
    def log_message(self, *a): pass
srvb = socketserver.TCPServer(("127.0.0.1", 0), Evil)
open(pb, "w").write(str(srvb.server_address[1]))
srva = socketserver.TCPServer(("127.0.0.1", 0), Redirector)
open(pa, "w").write(str(srva.server_address[1]))
threading.Thread(target=srvb.serve_forever, daemon=True).start()
srva.serve_forever()
PY
echo $! >>"$tmp/pids"
i=0
while [ "$i" -lt 50 ] && { [ ! -s "$tmp/A.port" ] || [ ! -s "$tmp/B.port" ]; }; do i=$((i + 1)); sleep 0.1; done
[ -s "$tmp/A.port" ] && [ -s "$tmp/B.port" ] || { echo "installer-net: servers down" >&2; exit 2; }
baseA="http://127.0.0.1:$(cat "$tmp/A.port")"

h="$tmp/home"; mkdir -p "$h"
out=$(HOME="$h" QLAUDE_INSTALL_DIR="$h/bin" QLAUDE_CONFIG_DIR="$h/conf" \
    QLAUDE_BASE_URL="$baseA" QLAUDE_REF=test sh "$installer" 2>&1)
rc=$?
: "$out"
bseen=$(wc -l <"$tmp/B.hits" 2>/dev/null || echo 0)
if [ "$rc" -ne 0 ] && [ "$bseen" -eq 0 ] && ! grep -rqs EVIL_PWNED "$h" 2>/dev/null; then
    st=0
else
    st=1
fi
t "a11 loopback 302 to another origin: install fails, evil origin never contacted" 0 $st
# anti-vacuous: the redirector WAS reached (the refusal is at the 302, not a connection failure)
if [ "$(wc -l <"$tmp/A.hits" 2>/dev/null || echo 0)" -gt 0 ]; then st=0; else st=1; fi
t "  anti-vacuous: honest loopback server was contacted (refusal is redirect-specific)" 0 $st

# --- a12: SIGTERM mid-fetch under dash must not leak the work dir.
mkdir -p "$tmp/www2/test/bin"
cp "$root/bin/qlaude" "$tmp/www2/test/bin/qlaude"
printf 'prompt\n' >"$tmp/www2/test/SYSTEM-PROMPT.md"
cp "$root/install.sha256" "$tmp/www2/test/install.sha256" 2>/dev/null || {
    mkdir -p "$tmp/gen/bin" "$tmp/gen/tools"
    cp "$root/bin/qlaude" "$tmp/gen/bin/"; cp "$root/tools/gen-checksum.sh" "$tmp/gen/tools/"
    printf 'prompt\n' >"$tmp/gen/SYSTEM-PROMPT.md"
    (cd "$tmp/gen" && sh tools/gen-checksum.sh >/dev/null)
    cp "$tmp/gen/install.sha256" "$tmp/www2/test/install.sha256"; }
python3 - "$tmp/www2" "$tmp/C.port" <<'PY' &
import http.server, socketserver, sys, functools, time
root, pc = sys.argv[1], sys.argv[2]
class Slow(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        time.sleep(8)
        super().do_GET()
    def log_message(self, *a): pass
srv = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Slow, directory=root))
open(pc, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
echo $! >>"$tmp/pids"
i=0
while [ "$i" -lt 50 ] && [ ! -s "$tmp/C.port" ]; do i=$((i + 1)); sleep 0.1; done
[ -s "$tmp/C.port" ] || { echo "installer-net: slow server down" >&2; exit 2; }
baseC="http://127.0.0.1:$(cat "$tmp/C.port")"
mkdir -p "$tmp/tt" "$tmp/h2"
# Ctrl-C fidelity: installer runs as its own process GROUP (python preexec
# setsid — reliable where shell setsid/kill-% semantics differ); TERM hits
# installer AND curl together; the work dir must then be gone.
python3 - "$root" "$installer" "$baseC" "$tmp/h2" "$tmp/tt" <<'PYX'
import os, signal, subprocess, sys, time, pathlib
root, installer, base, h2, tt = sys.argv[1:6]
os.makedirs(h2, exist_ok=True)
env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": h2,
       "TMPDIR": tt, "QLAUDE_INSTALL_DIR": h2 + "/bin",
       "QLAUDE_CONFIG_DIR": h2 + "/conf", "QLAUDE_BASE_URL": base,
       "QLAUDE_REF": "test"}
p = subprocess.Popen(["dash", installer], cwd=root, env=env,
                     preexec_fn=os.setsid,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1.5)
try:
    os.killpg(p.pid, signal.SIGTERM)
except ProcessLookupError:
    pass
time.sleep(0.5)
try:
    os.killpg(p.pid, signal.SIGKILL)
except ProcessLookupError:
    pass
p.wait()
sys.exit(0 if not any(pathlib.Path(tt).iterdir()) else 1)
PYX
_st=$?
st=$_st
t "a12 dash+SIGTERM mid-fetch: no work dir left in TMPDIR" 0 $st

exit "$fail"
