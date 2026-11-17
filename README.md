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

## Quickstart (qlaude)

`qlaude` is the launcher this repo ships: a single POSIX-sh script that
stores your endpoint/model/token in `~/.config/qlaude/config.env` (mode
0600; macOS keeps the token in the keychain instead), runs the checks
below as `qlaude doctor`, and launches Claude Code with every export from
the [Setup](#setup) block set for you. The manual path — the Setup block
itself — still works and is documented below; `qlaude` is not required.

```bash
curl -fsSL https://raw.githubusercontent.com/randomm/claude-qwen/main/install.sh | sh
qlaude setup        # asks: endpoint (NO trailing /v1), token (hidden), model, context, effort
qlaude doctor       # five checks: prereqs, /v1/messages, claude, tools, info
qlaude              # launches claude with the Setup exports + SYSTEM-PROMPT.md
qlaude ensure-path  # optional: add qlaude to PATH in new terminals
```

- The installer verifies a sha256 checksum of every file it fetches
  against `install.sha256` before executing anything — drift and
  corruption protection. It is not first-run authentication: the
  manifest arrives over the same HTTPS channel as the payloads (spec
  §5.6, honest scope).
- The token is never echoed, never printed, never passed in command-line
  arguments; `qlaude config` and `qlaude doctor` show state, not the
  value.
- `qlaude doctor` mirrors [Verify, in this order](#verify-in-this-order)
  plus a real tool-use probe, and is what `qlaude setup` runs at the end.
- `qlaude` obeys the same prerequisites and the same server-side
  [checklist](#server-side-checklist-vllm) as the manual path.
- Design and rationale: [docs/superpowers/specs/2026-11-16-qlaude-design.md](docs/superpowers/specs/2026-11-16-qlaude-design.md).

### Uninstall

No subcommand — three lines (the last is macOS-only, removing the
keychain entry):

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

## Prerequisites

1. Node.js v18+ (ships `npm`), then Claude Code:
   `npm install -g @anthropic-ai/claude-code`. Check `claude --version`
   (this guide was verified against 2.1.325).
2. vLLM ≥ 0.11.1 serving one model — 0.11.1 introduced the Anthropic route,
   and this guide was verified on vLLM 0.33, a much newer release. Install
   the latest; releases between the two have the route but are untested here.
   Any open model works; examples here use a Qwen model. Start it with the
   server flags from the [checklist](#server-side-checklist-vllm).
3. An access token for the server: if vLLM was started with `--api-key`
   (the flag is repeatable), the token must be one of the values passed to
   it; if auth is not enforced, no particular value is checked.

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
2. **Unrecognized model IDs get an assumed context window** — recent Claude
   Code builds assume 1M tokens — instead of the server's real one, which it
   never queries. When a conversation gets long, Claude Code summarizes the
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

Start with plain `claude` — not `claude -c` or `--resume` (these continue the
previous session). An old session replays the requests that failed while your
setup was broken, so old errors keep appearing.

### Why each variable matters

| Variable | What it does | If wrong/missing |
|---|---|---|
| `ANTHROPIC_BASE_URL` | Where Claude Code sends Messages-API calls (the CLI adds `/v1/messages` itself) | trailing `/v1` → misleading "model may not exist" error |
| `ANTHROPIC_AUTH_TOKEN` | Bearer token for the server | 401; using `ANTHROPIC_API_KEY` instead triggers login prompts |
| `ANTHROPIC_MODEL` | The model id, must match `--served-model-name` exactly | generic 404 wrapper |
| `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` | Claude Code routes some traffic (background tasks like session titles, plus `/model` picks) to roles named after Anthropic's model family — Opus, Sonnet and Haiku are Anthropic model names. Pin all three to your model, or those calls ask for a `claude-haiku-*` model your server does not have | background calls fail |
| `CLAUDE_CODE_EFFORT_LEVEL` | Reasoning effort. Claude Code's own levels are `low/medium/high/xhigh`, but vLLM validates the field against its own list — `low`, `medium`, `xhigh` — so `high` is rejected: a name mismatch between the two products, not a typo on your side | a rejected value fails the request with HTTP 400 listing vLLM's accepted values |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | Declares the real context window for model ids Claude Code does not recognize | compaction triggers at the assumed 1M; requests fail with HTTP 400 past the server's real limit. Never set it above `--max-model-len` |
| `CLAUDE_CODE_AUTO_MODE_MODEL` + `CLAUDE_CODE_BG_CLASSIFIER_MODEL` | Name the model that makes auto-mode safety decisions (main loop + background tasks) — ordinary model calls to your server | unset, the CLI probes Anthropic's default classifier model on your endpoint, falls back, and shows the auto-mode eligibility notice once per day. See [Auto mode](#auto-mode-and-the-safety-classifier) |

### Installer coordinates (optional)

`install.sh` reads four optional variables — a normal install sets none:

| Variable | Default | What it does |
|---|---|---|
| `QLAUDE_BASE_URL` | `https://raw.githubusercontent.com/randomm/claude-qwen` | Fetch root. `http` is accepted **only** for `127.0.0.1`/`localhost` (the offline test suite) and such fetches never follow redirects; every other non-HTTPS source is refused |
| `QLAUDE_REF` | `main` | The path segment appended to the base URL. Pin a release with `QLAUDE_REF=v0.1.0` (the CI pins it to the PR commit) |
| `QLAUDE_INSTALL_DIR` | `~/.local/bin` | Where `qlaude` lands. Must be an absolute path (a relative entry in PATH resolves against every future shell's cwd) |
| `QLAUDE_CONFIG_DIR` | `~/.config/qlaude` | Where `config.env` (mode 0600) and `SYSTEM-PROMPT.md` live |

These are installer knobs only — the launch-time variables that actually
shape traffic are the ones in [Why each variable matters](#why-each-variable-matters).

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
  read this model family's tool-call syntax; the parser must match the model.
  Per [vLLM's tool-calling docs](https://docs.vllm.ai/en/latest/features/tool_calling/):
  `hermes` for Qwen2.5/QwQ-era models, `qwen3_xml` for Qwen3-Coder models
  (`pythonic` is for Llama, not Qwen). Newer Qwen model cards sometimes name
  their own parser flag — follow the card for the version you run and confirm
  the name exists in your vLLM version's docs. Other model families have their
  own parser names in the same page. Without a parser, tool calls come back
  as ordinary text and the agent does nothing useful.
- `--served-model-name <your-model-name>` must exactly match
  `ANTHROPIC_MODEL`. The name must not contain `/`.
- Anthropic offers **server-side tools** (for example WebSearch), executed
  by Anthropic's API; vLLM does not implement them and returns HTTP 400.
  You hit this when a prompt asks Claude to search the web — the error names
  the server tool. Deny the `WebSearch` tool (set `WebSearch: never` in
  Claude Code settings) and use a
  [Model Context Protocol (MCP)](https://modelcontextprotocol.io) search
  server instead ([Claude Code MCP docs](https://code.claude.com/docs/en/mcp)).
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
| "this session isn't eligible … not compatible with this update" | Anthropic's server-side auto-mode classifier can't reach a custom endpoint; this is a billing disclosure, not an error | press Enter once, or pin the classifier model (see [Auto mode](#auto-mode-and-the-safety-classifier)) |
| ECONNREFUSED through a corporate or container proxy | Claude Code is a Node.js app: it ignores `*_proxy` variables unless `NODE_USE_ENV_PROXY=1`, and proxies can break its streaming responses | if the server is directly reachable, run `claude` with proxy variables unset; if you must traverse a proxy, set `NODE_USE_ENV_PROXY=1` plus `HTTPS_PROXY`, then test streaming with `claude -p` before trusting it |

## Auto mode and the safety classifier

Auto mode runs a safety classifier over actions (shell commands, network
calls) before they execute. Anthropic's new no-charge *server-side* checks
are a first-party service and never reach a session behind your own endpoint,
so Claude Code shows a notice naming your server as "not compatible with this
update". It is a billing disclosure, not an error: press Enter and the
classifier runs as Claude Code's own model calls through your base URL —
**your server makes the decisions**, billed as ordinary tokens on your box —
and the notice stays dismissed.

The two classifier exports are already in the [Setup](#setup) block; they
name the decision-maker explicitly and skip the notice:

```bash
export CLAUDE_CODE_AUTO_MODE_MODEL="<your-model-name>"      # auto-mode decisions
export CLAUDE_CODE_BG_CLASSIFIER_MODEL="<your-model-name>"  # background tasks
```

Verified November 2026: with these set (and `CLAUDE_CODE_AUTO_MODE_SERVER`
unset), auto mode enabled and actions auto-approved, classifier served by the
custom model. Internally, the classifier model resolves through the same
model config as the main loop and falls back gracefully when the endpoint
can't serve Anthropic's default classifier model.

**Do not** set `CLAUDE_CODE_AUTO_MODE_SERVER=0` to silence the notice: it
turns off the server checks and this build has no local fallback left, so
auto mode quietly degrades to asking approval for every checked action.

Two caveats:

- The judge and the actor are the same model. Treat auto mode on a
  self-hosted model as convenience, not a security boundary — use plan /
  accept-edits modes for work you'd want an independent judge on.
- To confirm the classifier rides your endpoint: watch the server log for an
  extra `POST /v1/messages` while auto mode holds an action.

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
unmaintained (as of November 2026), and both exist to translate Anthropic
traffic into OpenAI chat-completion calls — translation your vLLM already
does internally. `1rgs/claude-code-proxy` additionally has no license, which
rules it out for company use.

## Behavior prompt (optional)

The setup above works without this file. [`SYSTEM-PROMPT.md`](SYSTEM-PROMPT.md)
adds a short set of rules that close gaps we could trace in public reports —
behaviors Claude Code's **own** default prompt already asks for
(report outcomes faithfully, act instead of narrating, prefer dedicated tools)
but that open models demonstrably violate anyway. It only fills those gaps; it
does not restate the defaults.

Load it as an **append**, never a replacement — replacing the system prompt
strips Claude Code's tool discipline and is the usual way people make things
worse:

```bash
claude --append-system-prompt-file SYSTEM-PROMPT.md
```

For every session, wrap it in your shell config:

```bash
claude() { command claude --append-system-prompt-file ~/SYSTEM-PROMPT.md "$@"; }
```

### What each rule prevents

| Rule in SYSTEM-PROMPT.md | Failure it prevents | Source |
|---|---|---|
| Act, never announce (no ending a turn on "Let me check X") | announce-then-stop: the model narrates a step and ends the turn without calling the tool; the loop treats it as done | [QwenLM/Qwen3.8#150](https://github.com/QwenLM/Qwen3.8/issues/150), [r/LocalLLaMA](https://www.reddit.com/r/LocalLLaMA/comments/1swdjkz/qwen_36_27b_in_claude_code_says_it_will_do) (snippet-level) |
| Never emit an empty tool call to end a turn | same issue: empty tool calls leave tasks half-finished | [QwenLM/Qwen3.8#150](https://github.com/QwenLM/Qwen3.8/issues/150) |
| Tools are a channel, not text | tool-call syntax leaking into prose instead of executing | [r/LocalLLM](https://www.reddit.com/r/LocalLLM/comments/1uiixjz/qwen25coder7b_emits_tool_calls_that_opencode) (snippet-level), [vllm#39056](https://github.com/vllm-project/vllm/issues/39056) |
| Reply in the user's language, never mixed | language drift mid-session | [r/LocalLLaMA](https://www.reddit.com/r/LocalLLaMA/comments/1kad08f/qwen_3_wants_to_respond_in_chinese_even_when_not) (snippet-level), [qwen-code#6943](https://github.com/QwenLM/qwen-code/issues/6943) |
| No preambles/apologies before actions; identity line | over-explaining before tool calls; claiming to be Claude because the default prompt says so | style reports in the threads above; identity: see mod below |

Reddit threads are cited at search-snippet level (full threads were not
fetchable from here); GitHub issues were read in full.

### What deliberately is NOT in the file

- **Tool-call format instructions.** The chat template + `--tool-call-parser`
  decide the wire format; a prompt-level format rule can actively conflict
  with the configured parser ([Qwen function-calling docs](https://qwen.readthedocs.io/en/latest/framework/function_call.html),
  [vLLM qwen3_xml PR](https://github.com/vllm-project/vllm/pull/67164)).
  Fix the parser, not the prompt.
- **Thinking on/off.** Server/request parameters
  (`--reasoning-parser qwen3`, `enable_thinking`), not prompt rules.
- **Repetition loops.** Sampling config (`presence_penalty`) — and note
  Qwen's own card warns raising it *causes* language mixing, so keep the
  language rule above and leave sampling alone.
- **Permission policy.** Harness config (permission modes, allowlists), not
  model behavior.

### Identity, all the way down (optional mod)

Claude Code's default prompt tells the model it is Claude and lists Claude
model versions. The append above overrules that, but if you want it removed
rather than contradicted, [`ruihe774/cc-neutral-system-prompt`](https://github.com/ruihe774/cc-neutral-system-prompt)
(Unlicense, last push Oct 2026, small personal project — evaluate before
trusting) is a reference implementation that strips the Anthropic-specific
sections and swaps in a provider-neutral identity line. Our single identity
rule covers the observed symptom without a harness mod.

## Status

This guide was verified on one machine (November 2026): Claude Code 2.1.325 +
vLLM 0.33, Anthropic route with bearer auth, one custom model, interactive
mode and `-p` mode, tool use included.

`SYSTEM-PROMPT.md` (in this repo) is optional: the setup above works fully
without it. It adds rules that make an open model behave more like
Anthropic's models inside Claude Code — see
[Behavior prompt (optional)](#behavior-prompt-optional).
