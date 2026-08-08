# OpenType redesign: B2 Agent Runtime v1

Status: approved design, not yet implemented. macOS only. Builds on
`docs/superpowers/specs/2026-08-09-b1-b2-mode-surface-design.md` ("spec 2"),
which named Agent mode as a standalone entry point but deferred the runtime
itself. This spec covers a deliberately minimal v1: it does work, supports
external tools via MCP, lets the user configure their own LLM provider,
integrates with C, and reports progress — nothing beyond that. The owner
was explicit this will keep evolving; this is not meant to be the final
shape.

## 1. Safety boundary: no-side-effect tools only, policy not enforcement

Connecting arbitrary MCP tools is in tension with the existing
`neverAutoSendModes` invariant (agent/xReply output must stay a draft,
never auto-execute externally) — a tool call itself is an external action
the instant it runs, not a draft. Resolved for v1:

- Only **no-side-effect tools** are in scope — search, read, lookup,
  compute. Tools that send, write, delete, or otherwise mutate external
  state are out of scope for v1's intended use.
- This is **policy, not a technical control** in v1: the app does not
  inspect, allowlist, or block tools by capability. The user is trusted to
  only connect read-only MCP servers. Nothing stops a user from wiring up
  a write-capable tool today — that's an accepted v1 gap, not an oversight,
  and should be revisited before this is anything other than a
  single-user, self-configured tool (e.g. before any shared/multi-user
  context, or before the product recommends specific third-party MCP
  servers to install).

## 2. Provider requirement: native tool-calling only

Agent mode requires a text provider with native tool-calling support. Of
the four existing text providers, OpenAI and Anthropic are confirmed
compatible with this shape; DashScope's OpenAI-compatible endpoint needs
verification during implementation (if not tool-calling, it's simply
unavailable for Agent mode, with a clear message in Settings) — Volcengine
is not expected to qualify. There is no prompted/simulated tool-calling
fallback in v1 for non-supporting providers; if the user's configured text
provider doesn't support it, Agent mode is unavailable until they switch
providers.

## 3. Loop shape

```
task + context (selection/clipboard) + C's memory read (entity terms, FTS search)
  -> assemble messages: product-owned system prompt (not user-editable,
     unlike Prompt Studio for other modes) + task + context + memory
  -> call model, with the tool list from connected MCP servers attached
  -> model requests a tool call?
       yes -> execute via MCP client -> append tool result to the
              conversation -> loop back to "call model"
       no  -> model's text is the final result, stop
  -> a progress event is emitted after every step ("thinking", "calling
     tool X", "got a result", "done") for the Task List panel (spec 2 §4)
  -> hard iteration cap (defer exact number to implementation; something
     in the 8-12 range is a reasonable starting default) to prevent a
     runaway loop
```

## 4. Integration with C

- Reads through the same interfaces already defined for B1 in spec 1 §4.5
  (`allTerms()`/`search(text:)` over `entity_terms`, FTS over
  `episodic_events`) — no Agent-specific read interface.
- Writes back: the final result, and optionally a summary of the tool-call
  trace, get recorded as an `episodic_events` row with `origin = agent`
  (distinct from the user's own dictation, which is `origin = owner`).
  This is the first real use of the `origin` column added in spec 1 §4.2 —
  it exists specifically so agent-produced content can be told apart from
  the owner's own words once it flows back through the same consolidation
  pipeline.

## 5. Deferred

- Whether/how the Swift app implements an MCP client — no research has
  been done on Swift MCP SDK availability; this is an implementation-time
  spike, not a product decision, and doesn't block this design.
- Any technical enforcement of the no-side-effect-tools policy (§1) —
  policy-only for v1, deliberately.
- Exact iteration cap and any wall-clock timeout.
- Behavior with more than one Agent task in flight at once (queueing,
  concurrency limits) — v1 assumes this isn't yet a pressing case.
