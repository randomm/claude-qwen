#!/bin/sh
# gen-checksum suite: the checksum generator must fail LOUDLY, never write an
# empty-hash line (spec §5.8 checksum-drift gate is worthless if it can be
# rubber-stamped by a missing payload).
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

fail=0
t() {
    if [ "$3" -eq 0 ]; then
        echo "PASS $1"
    else
        echo "FAIL $1"
        fail=1
    fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkrepo() { # fresh isolated repo shape under tmp
    rm -rf "$tmp/repo"
    mkdir -p "$tmp/repo/bin" "$tmp/repo/tools"
    cp "$root/tools/gen-checksum.sh" "$tmp/repo/tools/"
    cp "$root/bin/qlaude" "$tmp/repo/bin/"
    printf 'prompt body\n' >"$tmp/repo/SYSTEM-PROMPT.md"
}

# 1. Happy path: write produces two 64-hex entries.
mkrepo
sh "$tmp/repo/tools/gen-checksum.sh"
st=$?
t "write: exit 0" 0 $st
if [ -f "$tmp/repo/install.sha256" ] &&
   [ "$(grep -Ec '^[0-9a-f]{64}  (bin/qlaude|SYSTEM-PROMPT\.md)$' "$tmp/repo/install.sha256")" = 2 ]; then
    t "write: two 64-hex lines for the payload pair" 0 0
else
    t "write: two 64-hex lines for the payload pair" 1 1
fi

# 2. --check on fresh output passes; after payload edit it flags drift.
sh "$tmp/repo/tools/gen-checksum.sh" --check
t "check: fresh output passes" 0 $?
printf 'changed\n' >>"$tmp/repo/bin/qlaude"
sh "$tmp/repo/tools/gen-checksum.sh" --check 2>/dev/null
st=$?
if [ "$st" -eq 0 ]; then st=1; else st=0; fi
t "check: drift after payload change is detected" 0 $st

# 3. Missing payload: must fail, never write an empty hash (audit finding).
mkrepo
rm -f "$tmp/repo/SYSTEM-PROMPT.md"
sh "$tmp/repo/tools/gen-checksum.sh" 2>/dev/null
st=$?
if [ "$st" -eq 0 ]; then st=1; else st=0; fi
t "missing payload: write fails (no empty-hash line)" 0 $st

# 4. An empty-hash install.sha256 must never pass --check.
printf '  bin/qlaude\n  SYSTEM-PROMPT.md\n' >"$tmp/repo/install.sha256"
mkrepo
printf '  bin/qlaude\n  SYSTEM-PROMPT.md\n' >"$tmp/repo/install.sha256"
sh "$tmp/repo/tools/gen-checksum.sh" --check 2>/dev/null
st=$?
if [ "$st" -eq 0 ]; then st=1; else st=0; fi
t "check: empty-hash file is refused" 0 $st

exit "$fail"
