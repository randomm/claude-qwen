# claude-qwen

Connect [Claude Code](https://code.claude.com) — Anthropic's terminal coding
agent, a CLI that reads your code, edits files and runs commands — to your own
model server, so you do not need an Anthropic subscription.

The target server is [vLLM](https://docs.vllm.ai), the open-source LLM
inference server. Since vLLM v0.11.1 it answers Anthropic's Messages API
(`POST /v1/messages`) itself, so Claude Code connects **directly — no
translation server between them**. This is vLLM's
[official Claude Code integration](https://docs.vllm.ai/en/stable/serving/integrations/claude_code/).

This README is endpoint-agnostic: `<your-endpoint>`, `<your-model-name>` and
`<your-token>` are placeholders — replace them with your server URL, your
`--served-model-name`, and your server's access token.

## Prerequisites

1. Claude Code: `npm install -g @anthropic-ai/claude-code`, then check
   `claude --version` (this guide was verified against 2.1.325).
2. vLLM ≥ 0.11.1 serving one model (this guide was verified against vLLM
   0.33). Any open model works; examples here use a Qwen model. Start it with
   the server flags from the [checklist](#server-side-checklist-vllm).
3. An access token for the server: vLLM checks tokens from its `--api-key`
   list when configured; when auth is disabled, any non-empty string works.

## How it works

Claude Code always speaks Anthropic's Messages protocol — the JSON API format
described at [platform.claude.com](https://platform.claude.com/docs/en/api/messages).
It sends its system prompt, tool definitions and the conversation to
`$ANTHROPIC_BASE_URL/v1/messages` with a bearer token. vLLM answers that route
directly. Two details cause almost all of the pain people hit:

1. **Claude Code adds `/v1/messages` to the base URL itself.** The base URL
   must *not* end in `/v1`. If it does, the CLI requests `/v1/v1/messages`,
   gets HTTP 404, and Claude Code reports every 404 with the same generic
   wrapper: *"There's an issue with the selected model (X). It may not exist
   or you may not have access to it."* — which is why people chase phantom
   model-name and auth bugs. Compare your base URL with the Setup block below
   before believing any model/auth theory.
2. **Unrecognized model IDs get an assumed context window** (1M tokens in
   recent builds) instead of the server's real one. When a conversation gets
   long, Claude Code summarizes the older part — this is called compaction —
   and it triggers at a fraction of the *assumed* window. With a 256k server,
   the conversation passes the real limit without compacting, and requests
   start failing with HTTP 400 "context length exceeded". Set the real window
   explicitly, below.

## Setup

```bash
export ANTHROPIC_BASE_URL="https://models.example.com"      # NO trailing /v1
export ANTHROPIC_AUTH_TOKEN="***"                  # sent as Authorization: Bearer
export ANTHROPIC_MODEL="<your-model-name>"
export ANTHROPIC_DEFAULT_SONNET_MODEL="<your-model-name>"   # pin all four roles:
export ANTHROPIC_DEFAULT_OPUS_MODEL="<your-model-name>"     # Claude Code sends some
export ANTHROPIC_DEFAULT_HAIKU_MODEL="<your-model-name>"    # traffic (e.g. session
                                                            # titles) to the haiku
                                                            # role by default
export CLAUDE_CODE_EFFORT_LEVEL=medium                      # accepted values below
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=262144                # = server --max-model-len
```

Use `ANTHROPIC_AUTH_TOKEN`: it sends `Authorization: Bearer ...`. Do **not**
use `ANTHROPIC_API_KEY`: it sends `x-api-key` instead and makes Claude Code
start Anthropic account-login flows, which fail without an Anthropic account.

Start with plain `claude` — not `claude -c` or `--resume` (these continue the
previous session). An old session replays the requests that failed while your
setup was broken, so old errors keep appearing.

### Why each variable matters

| Variable | What it does | If wrong/missing |
|---|---|---|
| `ANTHROPIC_BASE_URL` | Where Claude Code sends Messages-API calls (the CLI adds `/v1/messages` itself) | trailing `/v1` → misleading "model may not exist" error |
| `ANTHROPIC_AUTH_TOKEN` | Bearer token for the server | 401; using `ANTHROPIC_API_KEY` instead triggers login prompts |
| `ANTHROPIC_MODEL` | The model id, must match `--served-model-name` exactly | generic 404 wrapper |
| `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` | Claude Code splits its traffic into roles named after Anthropic's model tiers (main loop, background tasks). One model must serve every role, or background calls ask for a `claude-haiku-*` model your server does not have | background calls fail |
| `CLAUDE_CODE_EFFORT_LEVEL` | Reasoning effort. The vLLM Anthropic route accepts `low`, `medium` and `xhigh` — note that `high` is **not** one of them | a rejected value fails the request with HTTP 400 |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | Declares the real context window for model ids Claude Code does not recognize | compaction triggers at the assumed 1M; requests fail with HTTP 400 past the server's real limit. Never set it above `--max-model-len` |

## Verify, in this order

```bash
# 1. server actually speaks the Anthropic route
curl -X POST <your-endpoint>/v1/messages \
  -H "Authorization: Bearer ***" \
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
  read this model family's tool-call syntax; the parser must match the model
  (for example `qwen3_coder` or `hermes` for Qwen agent models). Other model
  families have their own parser names — see
  [vLLM's tool-choice docs](https://docs.vllm.ai/en/latest/features/tool_choice.html).
  Without a parser, tool calls come back as ordinary text and the agent does
  nothing useful.
- `--served-model-name <your-model-name>` must exactly match
  `ANTHROPIC_MODEL`. The name must not contain `/`.
- Anthropic offers **server-side tools** (for example WebSearch), which
  Anthropic's API executes for you; vLLM does not implement them and returns
  HTTP 400. Use a [Model Context Protocol (MCP)](https://modelcontextprotocol.io)
  search server instead.
- `GET /v1/models` returns the OpenAI format only, and that is fine:
  [Anthropic's gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol)
  makes that list optional and Claude Code works without it. Do not add a shim
  (a small server that fakes the expected answer) for `/v1/models`.

## Failure-mode cheat sheet

| Symptom | Real cause | Fix |
|---|---|---|
| "issue with the selected model … may not exist" | almost always a 404: wrong path (`/v1` suffix), wrong served name, or auth | check base URL against the Setup block, then curl `/v1/messages` |
| `Invalid Authorization header value` | corrupted token or quotes introduced by copy-pasting between chat and shell | re-export with plain ASCII quotes; verify with `cat -A` |
| Long sessions die with "context length exceeded" | Claude Code assumed a 1M window; the server's is smaller | `CLAUDE_CODE_MAX_CONTEXT_TOKENS` (≤ `--max-model-len`) |
| `Unexpected reasoning effort ... Supported types are ...` | effort value the server does not accept | `CLAUDE_CODE_EFFORT_LEVEL` to one of the values the error lists |
| Model "writes" files but nothing changes | server has no tool-call parser, so tool calls arrived as text | `--tool-call-parser` at vLLM start |
| ECONNREFUSED through a corporate or container proxy | Claude Code is a Node.js app: it ignores `*_proxy` variables unless `NODE_USE_ENV_PROXY=1`, and proxies break its streaming responses | when the server is directly reachable, run `claude` with proxy variables unset |

## If you want a gateway anyway

Direct connection is the default. Add a gateway only for multi-user keys,
quotas, per-role model routing or cost accounting:

| Option | Stars (Nov 2026) | Pick when |
|---|---|---|
| [LiteLLM Proxy](https://github.com/BerriAI/litellm) | ~63k | team quotas/keys/costs; a documented Claude Code path; answers `/v1/models` in Anthropic format and can forward `/v1/messages` unchanged |
| [claude-code-router](https://github.com/musistudio/claude-code-router) | ~38k | route roles to different models (opus→big, haiku→small) without extra infrastructure |
| [new-api](https://github.com/QuantumNous/new-api) | ~52k | you want a full account/console product (AGPL license) |
| [CliRelay](https://github.com/kittors/CliRelay) | ~1k | single Go binary, small-team relay |

Avoid `1rgs/claude-code-proxy` and `fuergaosi233/claude-code-proxy`: both are
unmaintained, both exist to translate Anthropic traffic into OpenAI
chat-completion calls — work your server already does — and
`1rgs/claude-code-proxy` has no license, which rules it out for company use.

## Status

We verified this guide against Claude Code 2.1.325 + vLLM 0.33 (November 2026):
Anthropic route with bearer auth, one custom model, interactive mode and `-p`
mode, tool use included.

`SYSTEM-PROMPT.md` (in this repo, landing with the next commit): rules that
make an open model behave closer to Anthropic's models inside Claude Code.
