# Server-side checklist (vLLM)

[← Back to the README](../README.md)

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
  match that value, never go above it (why:
  [How it works](how-it-works.md), point 2).
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
