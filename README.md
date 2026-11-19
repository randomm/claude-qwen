# qlaude — Claude Code against your own model server

[![CI](https://github.com/randomm/qlaude/actions/workflows/ci.yml/badge.svg)](https://github.com/randomm/qlaude/actions/workflows/ci.yml)
[![Apache-2.0 licensed](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

Run [Claude Code](https://code.claude.com), Anthropic's terminal coding
agent, against your own model server. Claude Code is a command-line tool
that reads your code, edits files and runs commands. One paste and five
setup questions get you running. You need no Anthropic subscription or
account, and the launcher sets every environment variable for you (an
environment variable is a setting a program reads from its shell instead
of a file). And you do not have to own a GPU or run a server to try it: a
hosted provider that offers an Anthropic-compatible API endpoint can stand
in for your own vLLM — see [Prerequisites](#prerequisites), item 2.

Works on Linux and macOS. Windows is not supported.

Verified November 2026 on Linux and macOS (one server, one model):
Claude Code 2.1.325 + vLLM 0.33, on the `POST /v1/messages` route with
bearer auth, interactive and `-p` modes, tool use included — full
evidence in [Status](#status).

The target server is [vLLM](https://docs.vllm.ai), the open-source LLM
inference server. Since vLLM v0.11.1 it answers Anthropic's Messages API
(`POST /v1/messages`) itself, so Claude Code connects directly, without a
translation server in between. This is vLLM's
[official Claude Code integration](https://docs.vllm.ai/en/stable/serving/integrations/claude_code/).
Anything that speaks the same route works: `<your-endpoint>`,
`<your-model-name>` and `<your-token>` below are placeholders — replace them
with your server URL, the name you passed to your server's
`--served-model-name` flag, and your server's access token.

## Quickstart (qlaude)

You need three things: a model server that is already running, its URL, and
its access token. This repo does not run a server for you — if you don't have
one yet, read [Prerequisites](#prerequisites) first.

`qlaude` is the launcher this repo ships: a single POSIX-sh script (POSIX
sh is the most portable shell dialect). It stores your endpoint/model/token
in `~/.config/qlaude/config.env` (mode 0600 — readable only by your user),
runs the self-checks below as `qlaude doctor`, and launches Claude Code
with the exports from the [Setup](#setup) block set for you. The manual path — the Setup block itself — still works and is
documented below; `qlaude` is not required.

```bash
curl -fsSL https://raw.githubusercontent.com/randomm/qlaude/main/install.sh | sh
```

That paste installs `~/.local/bin/qlaude` plus
`~/.config/qlaude/SYSTEM-PROMPT.md` (mode `0600`, the optional behavior
prompt — see [Status](#status)). Nothing else: no daemon, and no shell-rc
edits — the only command that ever touches rc files is `qlaude ensure-path`,
and only with your consent. In a terminal it
prints the PATH line to copy, if needed, then runs the setup interview.
It asks five questions:

1. Endpoint URL — the address of your server; no trailing `/v1` needed,
   it normalizes.
2. Token — shown as `*` while you type, stored `0600`.
3. Model — picked from the models the server lists; Enter accepts a single
   discovered id. If the listing is unavailable, the interview lets you
   type the id yourself.
4. Context — how many tokens the model can see at once.
5. Reasoning effort — how hard the model thinks before answering.

The interview ends with the five checks below. A successful run looks like
this (output sketch — your server URL and model names will differ):

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

Then plain `qlaude` opens Claude Code against your endpoint — just type what
you want done. Want to check what the launcher itself wired, the `qlaude`
equivalent of [Verify](#verify-in-this-order) step 2? Pass anything after
`--` straight to Claude Code:

```bash
qlaude -- -p "Reply with exactly: OK" --max-turns 1
```

- The installer prints your exact PATH line for the current shell, and the
  absolute-path command to make it permanent: `qlaude ensure-path`
  (consent-based — rc files are touched by that command only).
- Skipped or Ctrl-C'd the interview? Rerun the absolute path the installer
  printed (default `~/.local/bin/qlaude setup`).
- In scripts and CI (when the installer's output is not a terminal, or
  `CI` is set), the installer only installs. Configure explicitly instead:
  the wizard accepts every answer as a flag, and takes the token only via
  stdin, never as a command-line argument. In CI, feed the token from your
  secret store or a file mount, not from shell history:

```bash
curl -fsSL https://raw.githubusercontent.com/randomm/qlaude/main/install.sh | sh
printf '%s' "$YOUR_TOKEN" | ~/.local/bin/qlaude setup -y --token-stdin \
  --endpoint https://models.example.com --model my-model
```

  (Replace the token, path, endpoint and model; `QLAUDE_NO_SETUP=1` keeps
  the wizard from starting even in an interactive terminal.)
- The five checks above (`prereqs`, `messages`, `claude`, `tools`,
  `info`) are what `qlaude doctor` repeats any time; it mirrors
  [Verify, in this order](#verify-in-this-order) plus a real tool-use probe,
  and is what `qlaude setup` runs at the end. `qlaude` obeys the same
  prerequisites and the same server-side [checklist](#server-side-checklist-vllm)
  as the manual path.
- The installer verifies a sha256 checksum of every file it downloads
  against `install.sha256` before running anything, so a changed or
  corrupted file fails the install. This is not first-run authentication:
  the checksum list arrives over the same HTTPS connection as the files
  it describes (design spec §5.6 — link at the end of this list).
- The token is never echoed, never printed, never passed in command-line
  arguments; `qlaude config` and `qlaude doctor` show state, not the value.
- Design and rationale: [docs/superpowers/specs/2026-11-16-qlaude-design.md](docs/superpowers/specs/2026-11-16-qlaude-design.md).

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

## If something fails

Run `qlaude doctor` first — it repeats the five checks and names the failing
one. Then match the symptom:

| Symptom | Real cause | Fix |
|---|---|---|
| "issue with the selected model … may not exist" | almost always a 404: wrong path (`/v1` suffix), wrong served name, or auth | check base URL against the Setup block, then curl `/v1/messages` |
| `Invalid Authorization header value` | corrupted token or quotes introduced by copy-pasting between chat and shell | re-export with plain straight quotes (ASCII); verify with `cat -A` |
| Long sessions die with "context length exceeded" | Claude Code assumed a 1M window; the server's is smaller | `CLAUDE_CODE_MAX_CONTEXT_TOKENS` (≤ `--max-model-len`) |
| `Unexpected reasoning effort ... Supported types are ...` | effort value the server does not accept | `CLAUDE_CODE_EFFORT_LEVEL` to one of the values the error lists |
| Model "writes" files but nothing changes | server has no tool-call parser, so tool calls arrived as text | `--tool-call-parser` at vLLM start |
| "this session isn't eligible … not compatible with this update" | Auto mode is Claude Code screening every action with a safety classifier before it runs. Claude Code asked for Anthropic's server-side version of that check and the endpoint cannot answer it. The message is a billing notice, not a failure. The qlaude launcher normally prevents it entirely. | Launch through `qlaude`; it exports `CLAUDE_CODE_AUTO_MODE_SERVER=0`. If you had set `QLAUDE_AUTO_MODE_SERVER=on` in your config and your gateway (a proxy in front of your server — see [Gateways](docs/gateways.md)) cannot forward those checks, remove that setting (see [Auto mode](docs/auto-mode.md)). |
| ECONNREFUSED through a corporate or container proxy | Claude Code is a Node.js app: it ignores `*_proxy` variables unless `NODE_USE_ENV_PROXY=1`, and proxies can break its streaming responses | If the server is directly reachable: run `claude` with the proxy variables unset. If you must traverse a proxy: set `NODE_USE_ENV_PROXY=1` plus `HTTPS_PROXY`, then test streaming with `claude -p` before trusting it. |

## Prerequisites

Works on Linux and macOS — everything here is POSIX `sh` plus `curl` and
`npm`; CI parses every script with `dash -n` (`dash` is a minimal POSIX
shell, `-n` checks syntax without running) and runs the full acceptance
suite against a local fake server — no network, no real endpoints — under
`sh` and `dash`.

1. Node.js v18+ (ships `npm`), then Claude Code:
   `npm install -g @anthropic-ai/claude-code`. Check `claude --version`
   (this guide was verified against 2.1.325).
2. A model you can call — either path works:
   - **Your own server:** vLLM ≥ 0.11.1 serving one model — 0.11.1
     introduced the Anthropic route, and this guide was verified on vLLM
     0.33, a much newer release. Install the latest; releases between the
     two have the route but are untested here. Models your vLLM serves with
     a matching `--tool-call-parser` can work; this guide was verified with
     one Qwen model. Start it with the server flags from the
     [checklist](#server-side-checklist-vllm).
   - **No server of your own:** any hosted provider that offers an
     Anthropic-compatible Messages endpoint —
     [OpenRouter](https://openrouter.ai) is one example; pick whichever
     provider you like (they bill per token). Not every provider has one:
     plain OpenAI-format endpoints do not work, so check the provider's
     docs for an Anthropic-compatible `/v1/messages` route first. The
     wizard then asks for the same two things — the API base URL and the
     API key the provider gives you (for OpenRouter the base URL is
     `https://openrouter.ai/api`, per
     [their Claude Code guide](https://openrouter.ai/docs/cookbook/coding-agents/claude-code-integration)).
     One honest limit: qlaude's live verification so far covers self-hosted
     vLLM only — a hosted endpoint is untested here, so follow the
     provider's own Claude Code instructions for base URL and model ids
     (the `/v1` rule under [How it works](#how-it-works) still applies).
3. An access token: for a hosted provider, the API key it issues you; for
   vLLM, if it was started with `--api-key` (the flag is repeatable), the
   token must be one of the values passed to it; if auth is not enforced,
   no particular value is checked. `qlaude setup` always asks for a token,
   so with an unauthenticated server enter
   any non-empty value — it is still stored `0600` and sent as the bearer
   header, just not checked by the server.

Where the token lives: the launcher reads it from the macOS keychain entry
first when one exists, else from `~/.config/qlaude/config.env` (mode 0600).
You never set either by hand — `qlaude setup` writes them.

macOS detail: an *unattended* no-terminal setup writes the keychain entry
with the token on stdin only — never in a command line — and trusts it only
after reading the entry back and checking it equals the token. Interactive
setup keeps it in the file and says so, because Apple's `security` tool
blind-prompts the terminal for the secret.

## How it works

Claude Code always speaks Anthropic's Messages protocol — the JSON message
format (JSON is the text format API calls use) described at
[platform.claude.com](https://platform.claude.com/docs/en/api/messages).
It sends its system prompt, tool definitions and the conversation to
`$ANTHROPIC_BASE_URL/v1/messages` with a bearer token (the token sent as
`Authorization: Bearer`). vLLM answers that route
directly. Two details cause almost all of the pain people hit:

1. **Claude Code adds `/v1/messages` to the base URL itself.** The base URL
   must *not* end in `/v1`. If it does, the CLI requests `/v1/v1/messages`,
   gets HTTP 404, and Claude Code reports every 404 with the same generic
   wrapper: *"There's an issue with the selected model (X). It may not exist
   or you may not have access to it."* — which is why people chase phantom
   model-name and auth bugs. Compare your base URL with the Setup block below
   before believing any model/auth theory.
2. **Unrecognized model IDs get an assumed context window** — recent Claude
   Code builds assume 1M tokens — instead of the server's real one; Claude
   Code never queries the server for it. When a conversation gets long, Claude Code summarizes the
   older part — this is called compaction — and it triggers at a fixed
   percentage of the *assumed* window. On a 256k server, the conversation
   passes the real limit before compaction fires, and requests start failing
   with HTTP 400 "context length exceeded". Set the real window explicitly,
   below.

## Setup

```bash
export ANTHROPIC_BASE_URL="https://models.example.com"      # NO trailing /v1
export ANTHROPIC_AUTH_TOKEN="***"                  # sent as Authorization: Bearer
export ANTHROPIC_MODEL="<your-model-name>"
export ANTHROPIC_DEFAULT_SONNET_MODEL="<your-model-name>"   # pin every role to
export ANTHROPIC_DEFAULT_OPUS_MODEL="<your-model-name>"     # your model — Claude
export ANTHROPIC_DEFAULT_HAIKU_MODEL="<your-model-name>"    # Code also sends
                                                            # background traffic
                                                            # (session titles etc.)
                                                            # to the haiku role
export CLAUDE_CODE_EFFORT_LEVEL=medium                      # accepted values below
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=262144                # = server --max-model-len
export CLAUDE_CODE_AUTO_MODE_MODEL="<your-model-name>"      # pin the auto-mode
export CLAUDE_CODE_BG_CLASSIFIER_MODEL="<your-model-name>"  # safety classifiers too
```

Use `ANTHROPIC_AUTH_TOKEN`: it sends `Authorization: Bearer ...`. Do **not**
use `ANTHROPIC_API_KEY`: it sends `x-api-key` instead and makes Claude Code
start Anthropic account-login flows, which fail without an Anthropic account.

These exports live in the current shell only — reopen them in every new
terminal, or add them to your shell's profile file if you want them always.

Start with plain `claude` — not `claude -c` or `--resume` (these continue the
previous session). An old session replays the requests that failed while your
setup was broken, so old errors keep appearing.

### Why each variable matters

| Variable | What it does | If wrong/missing |
|---|---|---|
| `ANTHROPIC_BASE_URL` | Where Claude Code sends Messages-API calls (the CLI adds `/v1/messages` itself) | trailing `/v1` → misleading "model may not exist" error |
| `ANTHROPIC_AUTH_TOKEN` | Bearer token for the server | 401; using `ANTHROPIC_API_KEY` instead triggers login prompts |
| `ANTHROPIC_MODEL` | The model id, must match `--served-model-name` exactly | generic 404 wrapper |
| `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL` | Claude Code routes some traffic to roles named after Anthropic's model family. That traffic includes background tasks like session titles and `/model` picks. Opus, Sonnet and Haiku are Anthropic model names. Pin all three to your model, or those calls ask for a `claude-haiku-*` model your server does not have | background calls fail |
| `CLAUDE_CODE_EFFORT_LEVEL` | Reasoning effort. Claude Code's own levels are `low/medium/high/xhigh`. vLLM validates the field against its own list (`low`, `medium`, `xhigh`), so `high` is rejected — the qlaude launcher maps `high` to `xhigh` for you. That is a name mismatch between the two products, not a typo on your side | a rejected value fails the request with HTTP 400 listing vLLM's accepted values |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | Declares the real context window for model ids Claude Code does not recognize | compaction triggers at the assumed 1M; requests fail with HTTP 400 past the server's real limit. Never set it above `--max-model-len` |
| `CLAUDE_CODE_AUTO_MODE_MODEL` + `CLAUDE_CODE_BG_CLASSIFIER_MODEL` | Name the model that makes auto-mode safety decisions (main loop + background tasks) — ordinary model calls to your server | unset, the CLI probes Anthropic's default classifier model name on your endpoint and falls back; your server may not have it. See [Auto mode](docs/auto-mode.md) |
| `QLAUDE_AUTO_MODE_SERVER` (config.env / env) | `on` keeps Anthropic's server-side auto-mode checks switched on. The qlaude launcher otherwise exports `CLAUDE_CODE_AUTO_MODE_SERVER=0`: an OpenAI-compatible server can never return `safeguard_results`, the field that carries Anthropic's server-side check results back, so asking for server checks only produces the billing notice | leave unset on self-hosted servers; set `on` only behind a gateway (a proxy in front of your server) that forwards the auto-mode fields to Anthropic unchanged — the [pass-through contract](https://code.claude.com/docs/en/auto-mode-classifier-billing) |
| `QLAUDE_AUTH` (config.env) | Auth header style: `bearer` (default) sends `Authorization: Bearer` via `ANTHROPIC_AUTH_TOKEN`; `api-key` sends `x-api-key` via `ANTHROPIC_API_KEY` instead, for gateways that only accept that header | an unrecognized value fails the launch with "config corrupted — run: qlaude setup" (setup also rejects it at entry) |
| `QLAUDE_CLAUDE_BIN` (config.env / env) | Path to the `claude` binary the launcher execs — for non-PATH installs | a relative value containing a slash is turned into an absolute path from the current directory before exec (an exec that depended on the current directory would be a hijack vector); a missing target fails launch with a plain "install Claude Code, or set QLAUDE_CLAUDE_BIN" message |
| `QLAUDE_DEBUG` (env) | `env` prints the launcher's export list before launching, with the token value redacted — the export names and everything else are shown | anything else (including unset) is silent, which is the normal case |

### Installer coordinates (optional)

`install.sh` reads five optional variables — a normal install sets none:

| Variable | Default | What it does |
|---|---|---|
| `QLAUDE_BASE_URL` | `https://raw.githubusercontent.com/randomm/qlaude` | Fetch root. `http` is accepted **only** for `127.0.0.1`/`localhost` (the offline test suite) and such fetches never follow redirects; every other non-HTTPS source is refused |
| `QLAUDE_REF` | `main` | The path segment appended to the base URL. Pin a known-good version with `QLAUDE_REF=<40-char-commit-sha>` (no releases are tagged yet; CI pins it to the pull-request commit) |
| `QLAUDE_INSTALL_DIR` | `~/.local/bin` | Where `qlaude` lands. Must be an absolute path. A relative entry resolves against each future shell's working directory, which is why it must be absolute |
| `QLAUDE_CONFIG_DIR` | `~/.config/qlaude` | Where `config.env` (mode 0600) and `SYSTEM-PROMPT.md` live |
| `QLAUDE_NO_SETUP` | unset | Any value keeps the installer from running the guided interview even on a terminal (a set `CI` variable does the same); it prints the resume command instead |

These are installer knobs only — the launch-time variables that actually
shape traffic are the ones in [Why each variable matters](#why-each-variable-matters).

## Verify, in this order

Replace every `<angle-bracket>` placeholder before pasting — a literal
`***` or `<your-token>` gets you a bare `authentication_error` 401 that
looks like a server bug but is just the un-substituted placeholder being
rejected.

```bash
# 1. server actually speaks the Anthropic route
curl -X POST <your-endpoint>/v1/messages \
  -H "Authorization: Bearer <your-token>" \
  -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
  -d '{"model":"<your-model-name>","max_tokens":16,"messages":[{"role":"user","content":"say OK"}]}'
# → expect {"content":[{"text":"OK"...}], "stop_reason":"end_turn", ...}

# 2. the CLI wiring
claude -p "Reply with exactly: OK" --max-turns 1
```

If curl passes but `claude` fails, the problem is your environment values, not
the server. Run `env | grep ANTHROPIC | cat -A` and look for stray characters:
curly quotes from chat-pasting, hidden characters, or a mangled token.

## Server-side checklist (vLLM)

- `--enable-auto-tool-choice --tool-call-parser <parser>` — tells vLLM how to
  read this model family's tool-call syntax; the parser must match the model.
  Per [vLLM's tool-calling docs](https://docs.vllm.ai/en/latest/features/tool_calling/):
  `hermes` for Qwen2.5/QwQ-era models, `qwen3_xml` for Qwen3-Coder models
  (`pythonic` is for Llama, not Qwen). Newer Qwen model cards (the model's
  own documentation page, e.g. on Hugging Face) sometimes name their own
  parser flag — follow the card for the version you run and confirm the name
  exists in your vLLM version's docs. Other model families have their
  own parser names in the same page. Without a parser, tool calls come back
  as ordinary text and the agent does nothing useful.
- `--served-model-name <your-model-name>` must exactly match
  `ANTHROPIC_MODEL`. The name must not contain `/`.
- `--max-model-len` sets the context window your server accepts. The
  interview's context answer and `CLAUDE_CODE_MAX_CONTEXT_TOKENS` must
  match that value, never go above it (why: How it works, point 2).
- Anthropic offers **server-side tools** (for example WebSearch), executed
  by Anthropic's API; vLLM does not implement them and returns HTTP 400.
  You hit this when a prompt asks Claude to search the web — the error names
  the server tool. Deny the `WebSearch` tool (set `WebSearch: never` in your
  [Claude Code settings](https://code.claude.com/docs/en/settings)) and use a
  [Model Context Protocol (MCP)](https://modelcontextprotocol.io) search
  server instead ([Claude Code MCP docs](https://code.claude.com/docs/en/mcp)).
- `GET /v1/models` returns the OpenAI format only, and that is fine:
  [Anthropic's gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol)
  makes that list optional and Claude Code works without it. Do not add a shim
  (a small server that fakes the expected answer) for `/v1/models`.

## Go deeper

- [Auto mode and the safety classifier](docs/auto-mode.md) — why the
  launcher exports `CLAUDE_CODE_AUTO_MODE_SERVER=0`, what the two classifier
  pins do, the CI-enforced before/after results (verified November 2026),
  and when to opt back in behind a gateway that implements the pass-through
  contract.
- [Gateways](docs/gateways.md) — direct connection is the default; which
  proxies to add for multi-user keys/quotas, and which to avoid and why.
- [Behavior prompt](docs/behavior-prompt.md) — the optional
  [`SYSTEM-PROMPT.md`](SYSTEM-PROMPT.md) append: what each rule prevents
  (with sources), and what deliberately is NOT in the file.

## Status

This guide was verified November 2026 on Linux and macOS — one gateway,
one model: Claude Code 2.1.325 + vLLM 0.33, Anthropic route with bearer
auth, interactive mode and `-p` mode, tool use included. The installer,
wizard and self-test run in CI on both Linux and macOS runners against a
local stub (a fake server built for the tests, answering with canned
responses); the versions above are from a live OpenAI-compatible server.

`SYSTEM-PROMPT.md` (in this repo) is optional: the setup above works fully
without it. It adds rules that make an open model behave more like
Anthropic's models inside Claude Code — see
[Behavior prompt](docs/behavior-prompt.md).

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
