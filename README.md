# claude-qwen

Run Anthropic's **Claude Code** CLI against your own open-weight model box — no
Anthropic subscription — the supported way.

Target setup: a [vLLM](https://docs.vllm.ai) server exposing its **native
Anthropic Messages API** (`POST /v1/messages`, available since vLLM v0.11.1),
serving one open model (e.g. a Qwen checkpoint) under a name you choose.
This is vLLM's [official Claude Code integration](https://docs.vllm.ai/en/stable/serving/integrations/claude_code/)
— **no proxy, no shim, no translation layer** in the happy path.

> This README is intentionally endpoint-agnostic: `<your-endpoint>` and
> `<your-model-name>` are placeholders for your own server URL and
> `--served-model-name`.

## How it works

Claude Code always speaks the Anthropic Messages protocol: it sends its agent
loop (system prompt, tool definitions, conversation) to
`$ANTHROPIC_BASE_URL/v1/messages` with a bearer token. Modern vLLM answers
that route natively, so the CLI can be pointed straight at your box. Two
details cause almost all of the pain people hit:

1. **Claude Code appends `/v1/messages` to the base URL itself.** The base URL
   must *not* end in `/v1`. If it does, the CLI requests `/v1/v1/messages`,
   gets a 404, and Claude Code reports the 404 with its generic wrapper:
   *"There's an issue with the selected model (X). It may not exist or you may
   not have access to it."* — which is why people chase phantom model-name and
   auth bugs. Diff your base URL against a known-good config before believing
   any model/auth theory.
2. **Unrecognized model IDs get an assumed context window** (1M tokens in
   recent builds). Auto-compaction triggers against the *assumed* window, so
   with a 256k server the session runs past the real limit and the server
   starts rejecting requests, instead of compacting in time. Tell the CLI the
   real window explicitly.

## Setup

```bash
export ANTHROPIC_BASE_URL="https://models.example.com"      # NO trailing /v1
export ANTHROPIC_AUTH_TOKEN="<your-token>"                  # sent as Authorization: Bearer
export ANTHROPIC_MODEL="<your-model-name>"
export ANTHROPIC_DEFAULT_SONNET_MODEL="<your-model-name>"   # pin ALL tiers:
export ANTHROPIC_DEFAULT_OPUS_MODEL="<your-model-name>"     # background/haiku-role
export ANTHROPIC_DEFAULT_HAIKU_MODEL="<your-model-name>"    # tasks otherwise 404
export CLAUDE_CODE_EFFORT_LEVEL=medium                      # server-dependent, see below
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=262144                # = server --max-model-len
```

Use `ANTHROPIC_AUTH_TOKEN` (→ `Authorization: Bearer ...`). Do **not** use
`ANTHROPIC_API_KEY` — it sends `x-api-key` and triggers Anthropic login
flows. On a fresh setup, start `claude` (not `claude -c`/`--resume`): old
sessions replay broken history.

### Why each variable matters

| Variable | What it does | If wrong/missing |
|---|---|---|
| `ANTHROPIC_BASE_URL` | Where Claude Code sends Messages-API calls (CLI adds `/v1/messages` itself) | trailing `/v1` → misleading "model may not exist" error |
| `ANTHROPIC_AUTH_TOKEN` | Bearer token for the box | 401 / login prompts if using `ANTHROPIC_API_KEY` instead |
| `ANTHROPIC_MODEL` | Primary model id (must match `--served-model-name`) | generic 404 wrapper |
| `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` | Tier aliases, incl. background tasks (session titles etc.) | unpinned haiku → background 404s on `claude-haiku-*` |
| `CLAUDE_CODE_EFFORT_LEVEL` | Reasoning effort the server accepts | unsupported value → hard 400 (e.g. vLLM-backed ids accept `low\|medium\|xhigh`, not `high`) |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | Declares the real window for unknown model ids | compaction fires at the assumed 1M; 400s at the real wall |

## Verify, in this order

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
the server: `env | grep ANTHROPIC | cat -A` and look for stray characters
(curly quotes from chat-pasting, hidden characters, mangled `$VARS`).

## Server-side checklist (vLLM)

- `--enable-auto-tool-choice --tool-call-parser <parser>` (e.g.
  `qwen3_coder`, `hermes`, `pythonic`) — without a parser, tool calls come
  back as text and Claude Code does nothing useful.
- `--served-model-name <your-model-name>` must exactly match
  `ANTHROPIC_MODEL` (no `/` allowed in the name).
- Anthropic **server-side tools** (e.g. WebSearch) are rejected with 400 —
  wire an MCP search server instead.
- `GET /v1/models` stays OpenAI-shaped and that's fine: Anthropic's gateway
  protocol makes the model list optional; do not let anyone sell you a
  `/v1/models` shim for this setup.

## Failure-mode cheat sheet

| Symptom | Real cause | Fix |
|---|---|---|
| "issue with the selected model … may not exist" | almost always a 404: wrong path (`/v1` suffix), wrong served name, or auth | check base URL, then curl `/v1/messages` |
| `Invalid Authorization header value` | corrupted token/quotes from copy-pasting between chat and shell | re-export with plain ASCII quotes; verify with `cat -A` |
| Long sessions die with context-length 400 | assumed 1M window, real server window smaller | `CLAUDE_CODE_MAX_CONTEXT_TOKENS` (≤ `--max-model-len`) |
| Effort 400 (`Unexpected reasoning effort ... Supported types are ...`) | effort value not supported by server | set `CLAUDE_CODE_EFFORT_LEVEL` to one of the listed values |
| Model "writes" files but nothing changes | tool call emitted as text (no tool-call parser on server) | server-side `--tool-call-parser` |
| ECONNREFUSED through a corporate/container proxy | Node's fetch ignores `*_proxy` unless `NODE_USE_ENV_PROXY=1`; proxies also break SDK streams | run `claude` with proxy vars unset when the box is directly reachable |

## If you really want a gateway

Direct is the default. Put a gateway in front only for multi-user keys,
quotas, per-model routing or cost accounting:

| Option | Stars | Pick when |
|---|---|---|
| [LiteLLM Proxy](https://github.com/BerriAI/litellm) | ~63k | team quotas/keys/costs; officially documented Claude Code path; serves Anthropic-shaped `/v1/models` and can pass `/v1/messages` through untranslated |
| [claude-code-router](https://github.com/musistudio/claude-code-router) | ~38k | per-role model routing (opus→big, haiku→small) without infra |
| [new-api](https://github.com/QuantumNous/new-api) | ~52k | you want a full console/portal product (AGPL) |
| [CliRelay](https://github.com/kittors/CliRelay) | ~1k | single Go binary, small-team relay |

Avoid the stale `claude-code-proxy` twins (`1rgs/…`, `fuergaosi233/…`):
unmaintained and neither serves `/v1/models` at all.

## Status

- Verified against Claude Code 2.1.325 + vLLM 0.33 (Anthropic route, Bearer
  auth), single custom model, interactive and `-p` modes, tool use included.
- `SYSTEM-PROMPT.md` (this repo): a substitute behavior prompt that makes
  open-weight models behave closer to Anthropic models inside Claude Code.
