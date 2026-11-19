# How it works

[← Back to the README](../README.md)

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
   model-name and auth bugs. Compare your base URL with the Setup block in
   [Environment variables](environment.md) before believing any model/auth
   theory.
2. **Unrecognized model IDs get an assumed context window** — recent Claude
   Code builds assume 1M tokens — instead of the server's real one; Claude
   Code never queries the server for it. When a conversation gets long, Claude Code summarizes the
   older part — this is called compaction — and it triggers at a fixed
   percentage of the *assumed* window. On a 256k server, the conversation
   passes the real limit before compaction fires, and requests start failing
   with HTTP 400 "context length exceeded". The launcher sets the real
   window for you (`CLAUDE_CODE_MAX_CONTEXT_TOKENS` — see
   [Environment variables](environment.md)).
