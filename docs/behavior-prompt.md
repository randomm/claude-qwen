# Behavior prompt (optional)

[← Back to the README](../README.md)

The setup in the [README](../README.md) works without this file.
[`SYSTEM-PROMPT.md`](../SYSTEM-PROMPT.md)
adds a short set of rules that close gaps we could trace in public reports —
behaviors Claude Code's **own** default prompt already asks for
(report outcomes faithfully, act instead of narrating, prefer dedicated tools)
but that open models demonstrably violate anyway. It only fills those gaps; it
does not restate the defaults.

Load it as an **append**, never a replacement — replacing the system prompt
strips Claude Code's tool discipline and is the usual way people make things
worse:

```bash
claude --append-system-prompt-file SYSTEM-PROMPT.md
```

For every session, wrap it in your shell config:

```bash
claude() { command claude --append-system-prompt-file ~/SYSTEM-PROMPT.md "$@"; }
```

(The qlaude launcher appends the copy in its config directory for you —
this page is for the manual path.)

## What each rule prevents

| Rule in SYSTEM-PROMPT.md | Failure it prevents | Source |
|---|---|---|
| Act, never announce (no ending a turn on "Let me check X") | announce-then-stop: the model narrates a step and ends the turn without calling the tool; the loop treats it as done | [QwenLM/Qwen3.8#150](https://github.com/QwenLM/Qwen3.8/issues/150), [r/LocalLLaMA](https://www.reddit.com/r/LocalLLaMA/comments/1swdjkz/qwen_36_27b_in_claude_code_says_it_will_do) (snippet-level) |
| Never emit an empty tool call to end a turn | same issue: empty tool calls leave tasks half-finished | [QwenLM/Qwen3.8#150](https://github.com/QwenLM/Qwen3.8/issues/150) |
| Tools are a channel, not text | tool-call syntax leaking into prose instead of executing | [r/LocalLLM](https://www.reddit.com/r/LocalLLM/comments/1uiixjz/qwen25coder7b_emits_tool_calls_that_opencode) (snippet-level), [vllm#39056](https://github.com/vllm-project/vllm/issues/39056) |
| Reply in the user's language, never mixed | language drift mid-session | [r/LocalLLaMA](https://www.reddit.com/r/LocalLLaMA/comments/1kad08f/qwen_3_wants_to_respond_in_chinese_even_when_not) (snippet-level), [qwen-code#6943](https://github.com/QwenLM/qwen-code/issues/6943) |
| No preambles/apologies before actions; identity line | over-explaining before tool calls; claiming to be Claude because the default prompt says so | style reports in the threads above; identity: see mod below |

Reddit threads are cited at search-snippet level (full threads were not
fetchable from here); GitHub issues were read in full.

## What deliberately is NOT in the file

- **Tool-call format instructions.** The chat template + `--tool-call-parser`
  decide the wire format; a prompt-level format rule can actively conflict
  with the configured parser ([Qwen function-calling docs](https://qwen.readthedocs.io/en/latest/framework/function_call.html),
  [vLLM qwen3_xml PR](https://github.com/vllm-project/vllm/pull/67164)).
  Fix the parser, not the prompt.
- **Thinking on/off.** Server/request parameters
  (`--reasoning-parser qwen3`, `enable_thinking`), not prompt rules.
- **Repetition loops.** Sampling config (`presence_penalty`) — and note
  Qwen's own card warns raising it *causes* language mixing, so keep the
  language rule above and leave sampling alone.
- **Permission policy.** Harness config (permission modes, allowlists), not
  model behavior.

## Identity, all the way down (optional mod)

Claude Code's default prompt tells the model it is Claude and lists Claude
model versions. The append above overrules that, but if you want it removed
rather than contradicted, [`ruihe774/cc-neutral-system-prompt`](https://github.com/ruihe774/cc-neutral-system-prompt)
(Unlicense, small personal project — evaluate before trusting) is a
reference implementation that strips the Anthropic-specific sections and
swaps in a provider-neutral identity line. Our single identity rule covers
the observed symptom without a harness mod.
