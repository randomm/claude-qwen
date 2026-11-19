# Prerequisites

[← Back to the README](../README.md)

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
     [checklist](server-checklist.md).
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
     vLLM and one self-hosted llama-swap + llama.cpp stack — a hosted
     endpoint is untested here, so follow the provider's own Claude Code
     instructions for base URL and model ids (the `/v1` rule under
     [How it works](how-it-works.md) still applies).
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
