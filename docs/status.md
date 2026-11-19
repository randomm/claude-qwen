# Status — what has been verified, and where

[← Back to the README](../README.md)

This guide was verified November 2026 on Linux and macOS — one server,
one model: Claude Code 2.1.325 + vLLM 0.33, Anthropic route with bearer
auth, interactive mode and `-p` mode, tool use included. The installer,
wizard and self-test run in CI on both Linux and macOS runners against a
local stub (a fake server built for the tests, answering with canned
responses); the versions above are from a live OpenAI-compatible server.

A second server class, verified 2026-11-19 on Linux: Claude Code 2.1.327
with this launcher, `-p` mode end to end, against a single-machine
[llama-swap](https://github.com/mostlygeek/llama-swap) v273 fronting a
`llama-server` from a rolling ROCm toolbox container (llama.cpp b11577),
serving the MoE model `gemma-4-26b-a4b` on loopback. Read the fine print
before copying this shape: llama-swap answers the Anthropic route itself
by translating to OpenAI calls (first Anthropic-capable release: its
v175), so the engine never sees Anthropic JSON — and a model whose chat
template rejects the converted shape fails with HTTP 500 (another model
on the same host does exactly that). The engine build is a rolling image,
not a pinned one, and reasoning models spend part of every reply's token
budget on thinking, so very small `max_tokens` can return no text.

`SYSTEM-PROMPT.md` (in this repo) is optional: the setup works fully
without it. It adds rules that make an open model behave more like
Anthropic's models inside Claude Code — see
[Behavior prompt](behavior-prompt.md).
