#!/bin/sh
# qlaude installer (spec §5.6): curl-only, checksum-verified, BSD-safe.
# Needs only /bin/sh, curl and standard tools — no git, no python, no GNU
#-only flags on any user path (C2/C3). The same-origin checksum guards
# truncation/corruption, NOT the supply chain: that is TLS + the host's
# authentication of raw.githubusercontent.com. Documented honestly.
set -u

# audit a9: never write through a planted link — a symlink/hardlink at a
# destination gave any local actor arbitrary-file overwrite + arbitrary chmod
# as the installer's uid (root under sudo); checksums cannot catch that — the
# payload is honest, the DESTINATION was redirected. Refuse non-regular, unlink first.
install_file() { # $1=src $2=dest $3=mode
    if [ -L "$2" ] || { [ -e "$2" ] && [ ! -f "$2" ]; }; then
        err "refusing: $2 exists and is not a regular file"; exit "$EXIT_TOOL"
    fi
    rm -f "$2" 2>/dev/null || { err "cannot replace $2"; exit "$EXIT_PREREQ"; }
    cp "$1" "$2" || { err "cannot write $2"; exit "$EXIT_PREREQ"; }
    chmod "$3" "$2"
}
say() { printf 'qlaude install: %s\n' "$*"; }
err() { printf 'qlaude install: %s\n' "$*" >&2; }

EXIT_USAGE=1  # spec §5.5 exit map (shared with bin/qlaude)
EXIT_PREREQ=2
EXIT_TOOL=5

# --- coordinates (spec §5.6): CI pins REF to the PR commit; users pin tags.
QLAUDE_BASE_URL=${QLAUDE_BASE_URL:-https://raw.githubusercontent.com/randomm/qlaude}
QLAUDE_REF=${QLAUDE_REF:-main}
INSTALLDIR=${QLAUDE_INSTALL_DIR:-$HOME/.local/bin}
# audit a10: a relative install dir lands in PATH as a relative entry — every
# future shell resolves it against its own cwd. Absolute only, checked pre-fetch.
case $INSTALLDIR in
    /*) ;;
    *) err "QLAUDE_INSTALL_DIR must be an absolute path, got '$INSTALLDIR'"; exit "$EXIT_USAGE" ;;
esac
CONFDIR=${QLAUDE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/qlaude}

# --- OS check
os=$(uname 2>/dev/null || echo unknown)
case $os in
    Linux | Darwin) ;;
    *) err "unsupported OS '$os' (need Linux or Darwin)"; exit "$EXIT_PREREQ" ;;
esac

if ! command -v curl >/dev/null 2>&1; then
    err "prerequisite missing: curl is required"
    exit "$EXIT_PREREQ"
fi

# --- fetch: HTTPS always, except an explicitly chosen loopback test server
# (an override only — the default above is never loopback). No silent http.
# The loopback check parses the AUTHORITY, never prefix-matches the whole
# URL: http://127.0.0.1:9@evil.com is evil.com as far as curl is concerned,
# and any userinfo in an http URL is refused outright (spec C3 bounds with -m).
fetch() { # fetch <url> <out>
    _url=$1 _out=$2
    _scheme=${_url%%://*}
    case $_scheme in
        https)
            curl --proto '=https' --tlsv1.2 -m 30 -fsSL -o "$_out" "$_url"
            ;;
        http)
            _auth=${_url#*://}
            _auth=${_auth%%/*}
            case $_auth in
                *@*)
                    err "refusing non-HTTPS source (userinfo in URL): $_url"
                    return "$EXIT_PREREQ"
                    ;;
                127.0.0.1 | 127.0.0.1:* | localhost | localhost:*)
                    # audit a11: a loopback peer (or port-race winner) must not be able to
                    # redirect the test install elsewhere: no -L (302 fails -f), --proto pins http.
                    curl -m 30 -fsS --proto '=http' -o "$_out" "$_url"
                    ;;
                *)
                    err "refusing non-HTTPS source: $_url"
                    return "$EXIT_PREREQ"
                    ;;
            esac
            ;;
        *)
            err "refusing non-HTTPS source: $_url"
            return "$EXIT_PREREQ"
            ;;
    esac
}

# --- hasher ladder (C3): sha256sum -> shasum -> openssl. Status from the
# hasher itself, never from a pipe tail.
hash_one() {
    if command -v sha256sum >/dev/null 2>&1; then
        _out=$(sha256sum "$1" 2>/dev/null) || return 2
        printf '%s\n' "${_out%% *}"
    elif command -v shasum >/dev/null 2>&1; then
        _out=$(shasum -a 256 "$1" 2>/dev/null) || return 2
        printf '%s\n' "${_out%% *}"
    elif command -v openssl >/dev/null 2>&1; then
        _out=$(openssl dgst -sha256 "$1" 2>/dev/null) || return 2
        printf '%s\n' "${_out##* }"
    else
        err "no sha256 tool found (need sha256sum, shasum or openssl)"
        return 2
    fi
}

verify() { # verify <shafile> <payload-file> <payload-name>
    # '|' delimiter: the payload name carries '/' (bin/qlaude).
    _exp=$(sed -n "s|^\([0-9a-f]\{64\}\)  $3\$|\1|p" "$1" | sed -n 1p)
    case $_exp in
        '' | *[!0-9a-f]*) return 1 ;;
    esac
    _got=$(hash_one "$2") || return 1
    [ "$_got" = "$_exp" ]
}

work=$(mktemp -d) || { err "mktemp -d failed (TMPDIR unusable?)"; exit "$EXIT_PREREQ"; }
# Invoked indirectly via the EXIT trap below.
# shellcheck disable=SC2329
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
# audit a12: dash need NOT run the EXIT trap on SIGINT/SIGTERM (POSIX allows
# skipping) — Ctrl-C mid-fetch would leak the work dir (payload copies).
trap 'cleanup; exit 130' INT TERM

# --- fetch the payload trio into the work dir; nothing installed yet
base="$QLAUDE_BASE_URL/$QLAUDE_REF"
say "fetching from $base"
if ! fetch "$base/bin/qlaude" "$work/qlaude"; then
    err "download failed: $base/bin/qlaude"
    exit "$EXIT_TOOL"
fi
if ! fetch "$base/SYSTEM-PROMPT.md" "$work/SYSTEM-PROMPT.md"; then
    err "download failed: $base/SYSTEM-PROMPT.md"
    exit "$EXIT_TOOL"
fi
if ! fetch "$base/install.sha256" "$work/install.sha256"; then
    err "download failed: $base/install.sha256"
    exit "$EXIT_TOOL"
fi

# --- verify before touching anything (no half-install, spec §5.6)
if ! verify "$work/install.sha256" "$work/qlaude" bin/qlaude || \
   ! verify "$work/install.sha256" "$work/SYSTEM-PROMPT.md" SYSTEM-PROMPT.md; then
    err "download corrupt or truncated — nothing was installed; re-run, and if it persists report it"
    exit "$EXIT_TOOL"
fi
say "checksums verified (truncation/corruption guard; supply chain = TLS + the host)"

# --- install: idempotent update on re-run
if ! mkdir -p "$INSTALLDIR"; then
    err "cannot create $INSTALLDIR"
    exit "$EXIT_PREREQ"
fi
if ! mkdir -p "$CONFDIR"; then
    err "cannot create $CONFDIR"
    exit "$EXIT_PREREQ"
fi
install_file "$work/qlaude" "$INSTALLDIR/qlaude" 755
install_file "$work/SYSTEM-PROMPT.md" "$CONFDIR/SYSTEM-PROMPT.md" 600
say "installed $INSTALLDIR/qlaude"

# --- PATH guidance only; rc files are never touched (C4). ensure-path is
# the consent-based path to a permanent change.
case ":$PATH:" in
    *":$INSTALLDIR:"*) ;;
    *)
        say "PATH note: $INSTALLDIR is not on PATH — copy-paste now: export PATH=\"$INSTALLDIR:\$PATH\" (then: $INSTALLDIR/qlaude ensure-path)"
        ;;
esac

# §5.6 'offer qlaude setup if TTY', realized as the interview itself (#82):
# under a terminal the installer runs the existing wizard, re-attached to
# /dev/tty — piped stdin is the drained script, so the child takes the
# terminal instead (rustup pattern). Scripts, CI and QLAUDE_NO_SETUP keep the
# printed next line; no branch can hang an install. The wizard is the only
# config writer — the installer never reads the runtime QLAUDE_* bypass set.
if [ -t 1 ] && [ -z "${CI:-}" ] && [ -z "${QLAUDE_NO_SETUP:-}" ] \
    && : >/dev/tty 2>/dev/null; then
    say "next: guided configuration — answer the prompts (Ctrl-C skips; resume any time: $INSTALLDIR/qlaude setup)"
    "$INSTALLDIR/qlaude" setup </dev/tty \
        || say "setup did not finish green — rerun when ready: $INSTALLDIR/qlaude setup"
else
    say "next: $INSTALLDIR/qlaude setup (guided configuration)"
fi
exit 0
