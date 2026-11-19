# If something fails

[← Back to the README](../README.md)

Run `qlaude doctor` first — it repeats the five checks and names the failing
one. Then match the symptom. For a from-scratch check, go through
[Verify, in this order](verify.md).

| Symptom | Real cause | Fix |
|---|---|---|
| "issue with the selected model … may not exist" | almost always a 404: wrong path (`/v1` suffix), wrong served name, or auth | check base URL against the Setup block in [Environment variables](environment.md), then curl `/v1/messages` |
| `Invalid Authorization header value` | corrupted token or quotes introduced by copy-pasting between chat and shell | re-export with plain straight quotes (ASCII); verify with `cat -A` |
| Long sessions die with "context length exceeded" | Claude Code assumed a 1M window; the server's is smaller | `CLAUDE_CODE_MAX_CONTEXT_TOKENS` (≤ `--max-model-len`) |
| `Unexpected reasoning effort ... Supported types are ...` | effort value the server does not accept | `CLAUDE_CODE_EFFORT_LEVEL` to one of the values the error lists |
| Model "writes" files but nothing changes | server has no tool-call parser, so tool calls arrived as text | `--tool-call-parser` at vLLM start |
| "this session isn't eligible … not compatible with this update" | Auto mode is Claude Code screening every action with a safety classifier before it runs. Claude Code asked for Anthropic's server-side version of that check and the endpoint cannot answer it. The message is a billing notice, not a failure. The qlaude launcher normally prevents it entirely. | Launch through `qlaude`; it exports `CLAUDE_CODE_AUTO_MODE_SERVER=0`. If you had set `QLAUDE_AUTO_MODE_SERVER=on` in your config and your gateway (a proxy in front of your server — see [Gateways](gateways.md)) cannot forward those checks, remove that setting (see [Auto mode](auto-mode.md)). |
| ECONNREFUSED through a corporate or container proxy | Claude Code is a Node.js app: it ignores `*_proxy` variables unless `NODE_USE_ENV_PROXY=1`, and proxies can break its streaming responses | If the server is directly reachable: run `claude` with the proxy variables unset. If you must traverse a proxy: set `NODE_USE_ENV_PROXY=1` plus `HTTPS_PROXY`, then test streaming with `claude -p` before trusting it. |
