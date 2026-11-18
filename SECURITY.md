# Security policy

## How to report

Please do **not** open a public issue. Report vulnerabilities privately via
[GitHub private vulnerability reporting](https://github.com/randomm/qlaude/security/advisories/new)
(Security tab → *Report a vulnerability*). This project is maintained by one
person on a best-effort basis — no response-time SLA is promised, but
reports are read and acknowledged as promptly as life allows.

Include, redacted as you see fit: the exact command you ran, your OS, the
commit you installed from (`QLAUDE_REF` or `git rev-parse` if pinned), and
output with tokens and private hostnames removed.

## What this project runs, and from where

The one-paste installer fetches **two payloads plus a same-origin
manifest** — `bin/qlaude` and `SYSTEM-PROMPT.md`, verified against
`install.sha256` — from one HTTPS origin (default
`https://raw.githubusercontent.com/randomm/qlaude`, overridable via
`QLAUDE_BASE_URL`), and executes only `bin/qlaude`. The manifest arrives
over the same HTTPS channel as the payloads: this is drift and corruption
protection, **not** first-run authentication — the supply chain is TLS plus
the host (design spec §5.6). A `QLAUDE_BASE_URL` using plain `http` is
accepted only for `127.0.0.1`/`localhost` (the offline test suite), never
follows redirects, and any other non-HTTPS source is refused outright.

The access token is read from hidden input or stdin only — never command-line
arguments, never echoed, never printed; on macOS it goes to a `0600` config
file in interactive runs (a headless-only keychain write with read-back
verification otherwise). Config is stored mode `0600`. Nothing phones home:
no telemetry, no analytics, no update pings, no third-party requests from
the launcher.

## Supported versions

`main` is the supported version. Pin what you run with
`QLAUDE_REF=<40-char-commit-sha>` (no releases are tagged yet; the CI pins
its fetch to the PR commit).

## Out of scope

Findings that only matter when you point `QLAUDE_BASE_URL` at a source you
chose yourself are not vulnerabilities. Model-server behaviour belongs to
vLLM (or your server's project), and Claude Code behaviour belongs to
Anthropic.
