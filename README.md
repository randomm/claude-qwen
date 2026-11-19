# qlaude — Claude Code against your own model server

[![CI](https://github.com/randomm/qlaude/actions/workflows/ci.yml/badge.svg)](https://github.com/randomm/qlaude/actions/workflows/ci.yml)
[![Apache-2.0 licensed](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

Run [Claude Code](https://code.claude.com), Anthropic's terminal coding
agent, against your own model server. Claude Code is a command-line tool
that reads your code, edits files and runs commands. One paste and five
setup questions get you running. You need no Anthropic subscription or
account, and you do not have to own a GPU or run a server to try it: a
hosted provider that offers an Anthropic-compatible API endpoint can
stand in for your own vLLM — see [Prerequisites](docs/prerequisites.md).

Works on Linux and macOS. Windows is not supported.

Verified November 2026 on Linux and macOS: Claude Code 2.1.325 + vLLM
0.33 on the `POST /v1/messages` route, plus a llama-swap + llama.cpp
stack serving a Gemma MoE — what exactly was tested, and where, is in
[Status](docs/status.md).

The reference server is [vLLM](https://docs.vllm.ai), the open-source
LLM inference server: since v0.11.1 it answers Anthropic's Messages API
(`POST /v1/messages`) itself, so Claude Code connects directly, without
a translation server in between — vLLM's
[official Claude Code integration](https://docs.vllm.ai/en/stable/serving/integrations/claude_code/).
Anything that speaks the same route works.

## Quickstart

You need three things: a model server that is already running (or a
hosted provider), its URL, and its access token. This repo does not run
a server for you — if you don't have one yet, read
[Prerequisites](docs/prerequisites.md) first.

`qlaude` is the launcher this repo ships: a single POSIX-sh script
(POSIX sh is the most portable shell dialect). It stores your
endpoint/model/token in `~/.config/qlaude/config.env` (mode 0600 —
readable only by your user), runs the self-checks below as
`qlaude doctor`, and launches Claude Code with every setting wired for
you.

```bash
curl -fsSL https://raw.githubusercontent.com/randomm/qlaude/main/install.sh | sh
```

That paste installs `~/.local/bin/qlaude` plus
`~/.config/qlaude/SYSTEM-PROMPT.md` (mode `0600`, the optional behavior
prompt — see [Behavior prompt](docs/behavior-prompt.md)). Nothing else:
no daemon, and no shell-rc edits — the only command that ever touches rc
files is `qlaude ensure-path`, and only with your consent. Every
downloaded file is verified against `install.sha256` before running —
corruption/drift protection, not first-run authentication (the checksum
list arrives over the same HTTPS connection; trust here is TLS plus the
host). The token is never echoed, never printed, never a command-line
argument.

In a terminal the installer prints the PATH line to copy, if needed,
then runs the setup interview. It asks five questions:

1. Endpoint URL — the address of your server; no trailing `/v1` needed,
   it normalizes.
2. Token — shown as `*` while you type, stored `0600`.
3. Model — picked from the models the server lists; Enter accepts a single
   discovered id. If the listing is unavailable, the interview lets you
   type the id yourself.
4. Context — how many tokens the model can see at once.
5. Reasoning effort — how hard the model thinks before answering.

The interview ends with the five checks below. A successful run looks
like this (output sketch — your server URL and model names will differ):

```text
$ curl -fsSL https://raw.githubusercontent.com/randomm/qlaude/main/install.sh | sh
qlaude install: fetching from https://raw.githubusercontent.com/randomm/qlaude/main
qlaude install: checksums verified (truncation/corruption guard; supply chain = TLS + the host)
qlaude install: installed ~/.local/bin/qlaude
qlaude install: PATH note: ~/.local/bin is not on PATH — copy-paste now: export PATH="$HOME/.local/bin:$PATH" (then: ~/.local/bin/qlaude ensure-path)
qlaude install: next: guided configuration — answer the prompts (Ctrl-C skips; resume any time: ~/.local/bin/qlaude setup)
qlaude: endpoint URL (the Anthropic-compatible server qlaude will route to — type or paste, it echoes back): https://models.example.com
qlaude: token for https://models.example.com — paste it (shown as *, stored 0600 in config.env, never printed), Enter when done: **********
qlaude: model — 1 discovered; Enter accepts my-model (or type another id):
qlaude: context window tokens (= your server's --max-model-len; Enter = 262144):
qlaude: reasoning effort low/medium/xhigh ('high' is mapped for you; Enter = medium):
PASS 0 prereqs: all found
PASS 1 messages: 200 with content text
PASS 2 claude: echoed OK
PASS 3 tools: tool call round-tripped
PASS 4 info: no informational issues
```

And that is the whole setup: you set **no environment variables** by
hand. The launcher exports everything Claude Code needs at launch; the
full reference for each one is
[Environment variables](docs/environment.md), which you only need when
debugging or running `claude` without `qlaude`.

Daily use: plain `qlaude` opens Claude Code against your endpoint —
just type what you want done. `qlaude doctor` repeats the five checks
any time; `qlaude config` shows your saved settings (never the token).
To hand arguments straight to Claude Code — a `-p` probe, `--resume`,
anything after `--`:

```bash
qlaude -- -p "Reply with exactly: OK" --max-turns 1
```

Skipped or Ctrl-C'd the interview? Rerun with `~/.local/bin/qlaude setup`.
In scripts and CI the installer only installs; configure explicitly,
feeding the token over stdin — never as an argument (in CI, from your
secret store, not shell history):

```bash
curl -fsSL https://raw.githubusercontent.com/randomm/qlaude/main/install.sh | sh
printf '%s' "$YOUR_TOKEN" | ~/.local/bin/qlaude setup -y --token-stdin \
  --endpoint https://models.example.com --model my-model
```

### Uninstall

No subcommand. Three lines. The last one is macOS only and removes the
keychain entry:

```bash
rm "$HOME/.local/bin/qlaude"
rm -rf "$HOME/.config/qlaude"
security delete-generic-password -s qlaude   # macOS only
```

If you installed with `QLAUDE_INSTALL_DIR`/`QLAUDE_CONFIG_DIR` set, drop
those files from wherever they went instead. If you ran
`qlaude ensure-path`, delete the `# qlaude PATH` … `# end qlaude PATH`
marker block from the file it named (`~/.profile` by default,
`~/.zprofile` for zsh and macOS).

## If something goes wrong

Run `qlaude doctor` first — it names the failing check. Then:

- [Troubleshooting](docs/troubleshooting.md) — known symptoms, real
  causes and fixes (including the misleading "model may not exist"
  error, which is almost always a trailing `/v1`).
- [Verify, in this order](docs/verify.md) — two commands that split
  server problems from environment problems.
- [Server-side checklist](docs/server-checklist.md) — the vLLM flags
  that make tools work (`--tool-call-parser`, `--served-model-name`,
  `--max-model-len`).

## Read on

- [Prerequisites](docs/prerequisites.md) — Claude Code install, your
  own vLLM or a hosted provider, and where the token lives.
- [How it works](docs/how-it-works.md) — the Messages route, and the
  two details behind almost every failure people hit.
- [Environment variables](docs/environment.md) — the canonical
  reference for every variable (the normal path sets none).
- [Auto mode and the safety classifier](docs/auto-mode.md) — why the
  launcher exports `CLAUDE_CODE_AUTO_MODE_SERVER=0`, and when to opt
  back in.
- [Gateways](docs/gateways.md) — direct is the default; when a proxy
  earns its keep, and which to avoid.
- [Behavior prompt](docs/behavior-prompt.md) — what the optional
  `SYSTEM-PROMPT.md` rules prevent, and what deliberately is not in it.
- [Status](docs/status.md) — exactly what has been verified live.
- Design and rationale: [the spec](docs/superpowers/specs/2026-11-16-qlaude-design.md).

## Getting help

- Questions and bugs: [open an issue](https://github.com/randomm/qlaude/issues) —
  include what you ran, what came back, your OS, and which commit you
  installed from (your `QLAUDE_REF` value; if you left it on `main`, the
  install date helps too — the installer fetches single files, so there is
  no local clone to query with `git rev-parse`).
- Security issues: please do not open a public issue — report privately
  via [SECURITY.md](SECURITY.md) (GitHub's *Report a vulnerability* form).
- Contributions: [CONTRIBUTING.md](CONTRIBUTING.md) — the offline test suite,
  the shellcheck/dash gates, the line budgets (hard per-file size caps CI
  enforces), and the README rules.

Licensed under the [Apache License 2.0](LICENSE) — use it, fork it, ship it
in your company.
