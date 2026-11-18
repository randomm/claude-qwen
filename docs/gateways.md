# If you want a gateway anyway

[← Back to the README](../README.md)

Direct connection is the default — vLLM answers the Anthropic route itself,
so a proxy only earns its keep when you need something a single server
cannot do. Add a gateway for multi-user keys, quotas, per-role model routing
or cost accounting:

| Option | Pick when |
|---|---|
| [LiteLLM Proxy](https://github.com/BerriAI/litellm) | team quotas/keys/costs; a documented Claude Code path; answers `/v1/models` in Anthropic format and can forward `/v1/messages` unchanged |
| [claude-code-router](https://github.com/musistudio/claude-code-router) | route roles to different models (opus→big, haiku→small) without extra infrastructure |
| [new-api](https://github.com/QuantumNous/new-api) | you want a full account/console product (AGPL license) |
| [CliRelay](https://github.com/kittors/CliRelay) | single Go binary, small-team relay |

Avoid `1rgs/claude-code-proxy` and `fuergaosi233/claude-code-proxy`: both
exist to translate Anthropic traffic into OpenAI chat-completion calls —
translation your vLLM already does internally, so they add a hop and a
failure mode for nothing. `1rgs/claude-code-proxy` additionally ships
without a license, which rules it out for company use.

Whichever you pick, the same two rules from the README apply: the base URL
must not end in `/v1`, and it must forward `/v1/messages` (and the
`anthropic-beta` header + `safeguards` field, if you want
[auto-mode](auto-mode.md) server checks) unchanged.
