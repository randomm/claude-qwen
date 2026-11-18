# Contributing to qlaude / claude-qwen

Small fixes are welcome: docs typos, failure modes you hit with the exact
command that triggered them, tests for reported bugs. For anything bigger,
open an issue first so we can agree on scope before you write code.

## Before you open a pull request

Run the checks CI runs:

    sh tests/run_tests.sh        # the offline acceptance suite (local stub server, no network)
    shellcheck -s sh --severity=style install.sh bin/qlaude tools/*.sh tests/*.sh
    dash -n install.sh bin/qlaude tools/*.sh && for f in tests/test_*.sh; do dash -n "$f"; done
    sh tools/gen-checksum.sh --check   # install.sha256 must match the payload
    sh tools/line_budget.sh            # hard caps: install.sh, bin/qlaude, stub, tests

The line budgets are hard limits — if your change needs more, say so in the
pull request and we'll discuss it before merging.

Every shipped script is strict POSIX `sh`: no `[[ ]]`, no arrays, no
`source`, no `echo -e`, no `read -n`. Tests never touch the network — they
run against `tests/stub_server.py`; never point a test at a live endpoint.

## The README is the product

`README.md` is the project's single source of truth for user-facing facts,
and specifically the single source for the variable table — never restate
that table anywhere else; link to it. CI enforces the details
(`tests/test_docs_coords.sh` plus the A6 check in `.github/workflows/ci.yml`):

- every launcher export name must appear in the README;
- the launch-variable table must exist exactly once;
- the installer-coordinates section may not duplicate launch variables;
- documented flows (`token-stdin`, `QLAUDE_NO_SETUP`, `qlaude -- -p`, the
  installer coordinates) must stay documented.

If you change behavior that the README describes, update the README in the
same commit. If a doc pin must move, move it deliberately in the same
commit and say so.

## Style

Write for a developer who has never set an environment variable. Define a
term once, in parentheses, at first use. No superlatives, no exclamation
marks, and no claims that aren't backed by something you verified this
session — CI and tests are the evidence, or a note naming the machine and
date it was verified on. Describe third-party servers generically ("a live
OpenAI-compatible gateway"), never by hostname.

## Working in the open

Maintainer notes for AI agents live in [AGENTS.md](AGENTS.md); read it if
you are contributing with an agent.
