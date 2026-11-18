# Auto mode and the safety classifier

[← Back to the README](../README.md) · variable table:
[Why each variable matters](../README.md#why-each-variable-matters)

Auto mode runs a safety classifier over actions (shell commands, network
calls) before they execute. Anthropic can also run those checks server-side
at no charge — but only where the checks can actually reach the session.
Per
[the official billing doc](https://code.claude.com/docs/en/auto-mode-classifier-billing),
a gateway keeps them alive by forwarding the `anthropic-beta` header and the
`safeguards` request-body field **unchanged, as a pair** (on the Bedrock
InvokeModel format, the `anthropic_beta` body field instead), and by
returning responses and streaming events without dropping fields, rewriting
tool-use ids, or omitting `safeguard_results`.

An OpenAI-compatible server cannot answer `safeguard_results` at all, so
server-side checks are structurally unreachable for qlaude setups. The
documented remedy for exactly that case is to stop asking for them — and the
qlaude launcher does it for you: it exports `CLAUDE_CODE_AUTO_MODE_SERVER=0`
at launch, so you never set it yourself.

With that export the "this session isn't eligible" notice never appears, and
the classifier runs as Claude Code's own model calls through your base URL —
**your server makes the decisions**, billed as ordinary tokens on your box.
Verified November 2026 against the CI-pinned CLI: with server checks switched
on the notice *does* appear on `-p` stderr even against a local stub, and the
qlaude default export suppresses it (CI-enforced differential).
That is why the two classifier pins matter —
`CLAUDE_CODE_AUTO_MODE_MODEL` and `CLAUDE_CODE_BG_CLASSIFIER_MODEL`, both
already in the README's
[Setup block](../README.md#setup) and explained in
[Why each variable matters](../README.md#why-each-variable-matters):
with them set, auto mode's decisions are served by your custom model,
resolving through the same model config as the main loop (verified
November 2026, auto-approved actions).

Behind a gateway that does implement the pass-through contract above, opt
back in so the free server-side checks can reach your session: set
`QLAUDE_AUTO_MODE_SERVER=on` in your environment or in `config.env`
(anything else means off, the default).

Manual-env users (bypassing the launcher): set
`CLAUDE_CODE_AUTO_MODE_SERVER=0` yourself.
`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` also turns the server checks off
while `CLAUDE_CODE_AUTO_MODE_SERVER` is unset, but it disables other beta
features too — prefer the explicit `0`.

Where the notice cannot wait for an answer (`claude -p` prints it to stderr;
stream-json emits a system warning), with qlaude's default it does not
appear at all.

Two caveats:

- The judge and the actor are the same model. Treat auto mode on a
  self-hosted model as convenience, not a security boundary — use plan /
  accept-edits modes for work you'd want an independent judge on.
- To confirm the classifier rides your endpoint: watch the server log for an
  extra `POST /v1/messages` while auto mode holds an action.
