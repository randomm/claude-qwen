# Verify, in this order

[← Back to the README](../README.md)

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
