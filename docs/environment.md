# Environment variables

[← Back to the README](../README.md)

This page is the **single source of truth** for the environment variables
qlaude and Claude Code use. It is a reference: in the normal path you set
**none** of them by hand — the launcher exports everything, and `qlaude
setup` stores the few settings it asks about. Nothing else in this repo
restates this table; link here instead.

## Manual setup (the exports the launcher builds for you)

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

## Why each variable matters

| Variable | What it does | If wrong/missing |
|---|---|---|
| `ANTHROPIC_BASE_URL` | Where Claude Code sends Messages-API calls (the CLI adds `/v1/messages` itself) | trailing `/v1` → misleading "model may not exist" error |
| `ANTHROPIC_AUTH_TOKEN` | Bearer token for the server | 401; using `ANTHROPIC_API_KEY` instead triggers login prompts |
| `ANTHROPIC_MODEL` | The model id, must match `--served-model-name` exactly | generic 404 wrapper |
| `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL` | Claude Code routes some traffic to roles named after Anthropic's model family. That traffic includes background tasks like session titles and `/model` picks. Opus, Sonnet and Haiku are Anthropic model names. Pin all three to your model, or those calls ask for a `claude-haiku-*` model your server does not have | background calls fail |
| `CLAUDE_CODE_EFFORT_LEVEL` | Reasoning effort. Claude Code's own levels are `low/medium/high/xhigh`. vLLM validates the field against its own list (`low`, `medium`, `xhigh`), so `high` is rejected — the qlaude launcher maps `high` to `xhigh` for you. That is a name mismatch between the two products, not a typo on your side | a rejected value fails the request with HTTP 400 listing vLLM's accepted values |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | Declares the real context window for model ids Claude Code does not recognize | compaction triggers at the assumed 1M; requests fail with HTTP 400 past the server's real limit. Never set it above `--max-model-len` |
| `CLAUDE_CODE_AUTO_MODE_MODEL` + `CLAUDE_CODE_BG_CLASSIFIER_MODEL` | Name the model that makes auto-mode safety decisions (main loop + background tasks) — ordinary model calls to your server | unset, the CLI probes Anthropic's default classifier model name on your endpoint and falls back; your server may not have it. See [Auto mode](auto-mode.md) |
| `QLAUDE_AUTO_MODE_SERVER` (config.env / env) | `on` keeps Anthropic's server-side auto-mode checks switched on. The qlaude launcher otherwise exports `CLAUDE_CODE_AUTO_MODE_SERVER=0`: an OpenAI-compatible server can never return `safeguard_results`, the field that carries Anthropic's server-side check results back, so asking for server checks only produces the billing notice | leave unset on self-hosted servers; set `on` only behind a gateway (a proxy in front of your server) that forwards the auto-mode fields to Anthropic unchanged — the [pass-through contract](https://code.claude.com/docs/en/auto-mode-classifier-billing) |
| `QLAUDE_AUTH` (config.env) | Auth header style: `bearer` (default) sends `Authorization: Bearer` via `ANTHROPIC_AUTH_TOKEN`; `api-key` sends `x-api-key` via `ANTHROPIC_API_KEY` instead, for gateways that only accept that header | an unrecognized value fails the launch with "config corrupted — run: qlaude setup" (setup also rejects it at entry) |
| `QLAUDE_CLAUDE_BIN` (config.env / env) | Path to the `claude` binary the launcher execs — for non-PATH installs | a relative value containing a slash is turned into an absolute path from the current directory before exec (an exec that depended on the current directory would be a hijack vector); a missing target fails launch with a plain "install Claude Code, or set QLAUDE_CLAUDE_BIN" message |
| `QLAUDE_DEBUG` (env) | `env` prints the launcher's export list before launching, with the token value redacted — the export names and everything else are shown | anything else (including unset) is silent, which is the normal case |

### Installer coordinates (optional)

`install.sh` reads five optional variables — a normal install sets none:

| Variable | Default | What it does |
|---|---|---|
| `QLAUDE_BASE_URL` | `https://raw.githubusercontent.com/trail-openers/qlaude` | Fetch root. `http` is accepted **only** for `127.0.0.1`/`localhost` (the offline test suite) and such fetches never follow redirects; every other non-HTTPS source is refused |
| `QLAUDE_REF` | `main` | The path segment appended to the base URL. Pin a known-good version with `QLAUDE_REF=<40-char-commit-sha>` (no releases are tagged yet; CI pins it to the pull-request commit) |
| `QLAUDE_INSTALL_DIR` | `~/.local/bin` | Where `qlaude` lands. Must be an absolute path. A relative entry resolves against each future shell's working directory, which is why it must be absolute |
| `QLAUDE_CONFIG_DIR` | `~/.config/qlaude` | Where `config.env` (mode 0600) and `SYSTEM-PROMPT.md` live |
| `QLAUDE_NO_SETUP` | unset | Any value keeps the installer from running the guided interview even on a terminal (a set `CI` variable does the same); it prints the resume command instead |

These are installer knobs only — the launch-time variables that actually
shape traffic are the ones in [Why each variable matters](#why-each-variable-matters).
