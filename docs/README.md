# Documentation

Start at the [README](../README.md) — it is a short what-it-is + quickstart.
Reference material lives here; [environment.md](environment.md) is the
single source of truth for every environment variable. These pages hold
the deeper explanations the README links to:

- [Prerequisites](prerequisites.md) — Claude Code, your own vLLM or a
  hosted Anthropic-compatible provider, and where the token lives.
- [How it works](how-it-works.md) — the Messages route and the two details
  behind most failures.
- [Environment variables](environment.md) — canonical export/coordinate
  reference; the normal path sets none by hand.
- [Troubleshooting](troubleshooting.md) — symptom → real cause → fix.
- [Verify, in this order](verify.md) — split server problems from
  environment problems.
- [Server-side checklist](server-checklist.md) — the vLLM flags that make
  tools work.

- [Auto mode and the safety classifier](auto-mode.md) — why the launcher
  exports `CLAUDE_CODE_AUTO_MODE_SERVER=0`, and when to opt back in.
- [Gateways](gateways.md) — direct is the default; when a proxy earns its
  keep, and which to avoid.
- [Behavior prompt](behavior-prompt.md) — what each `SYSTEM-PROMPT.md`
  rule prevents, and what deliberately is not in the file.
- [Status](status.md) — exactly what has been verified live, and where.

Design records (specs and plans written during development) live under
[superpowers/](superpowers/) — engineering history, not user docs.
