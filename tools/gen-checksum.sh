#!/bin/sh
# Regenerate install.sha256: sha256 over the shipped payload pair
# bin/qlaude + SYSTEM-PROMPT.md (spec §5.1, §5.6). CI's lint job runs
# --check and fails on drift (spec §5.8). Hasher ladder per spec C3.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)

hash_one() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        echo "gen-checksum: no sha256 tool (need sha256sum, shasum or openssl)" >&2
        return 2
    fi
}

gen() {
    _h=$(hash_one "$root/bin/qlaude") || return $?
    printf '%s  %s\n' "$_h" bin/qlaude
    _h=$(hash_one "$root/SYSTEM-PROMPT.md") || return $?
    printf '%s  %s\n' "$_h" SYSTEM-PROMPT.md
}

case ${1:-write} in
    write)
        gen >"$root/install.sha256"
        ;;
    --check)
        if [ ! -f "$root/install.sha256" ]; then
            echo "gen-checksum --check: install.sha256 is missing" >&2
            exit 1
        fi
        _tmp=$(mktemp) || exit 1
        if ! gen >"$_tmp"; then
            rm -f "$_tmp"
            exit 1
        fi
        if cmp -s "$root/install.sha256" "$_tmp"; then
            rm -f "$_tmp"
            exit 0
        fi
        echo "gen-checksum --check: install.sha256 is stale — run tools/gen-checksum.sh and commit" >&2
        rm -f "$_tmp"
        exit 1
        ;;
    *)
        echo "usage: gen-checksum.sh [write|--check]" >&2
        exit 1
        ;;
esac
