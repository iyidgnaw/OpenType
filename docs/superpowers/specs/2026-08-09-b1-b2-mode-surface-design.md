# OpenType redesign: B1/B2 mode surface (explicit switching, no router)

Status: approved design, not yet implemented. macOS only. Builds on
`docs/superpowers/specs/2026-08-08-system-boundaries-and-memory-v1-design.md`
("spec 1"), which defined the A/B1/B2/C module boundaries but explicitly
deferred "the router that classifies a voice command as transcribe-only,
B1, or B2." This spec resolves that: **there is no router**. This spec
covers only the external interaction shape of B1/B2 — not B2's internal
Agent Runtime design (loop shape, MCP/skill integration, safety
boundaries), which stays deferred to a future spec.

## 1. Decision: explicit mode switching, not automatic classification

Spec 1 left open whether a voice command gets classified (transcribe vs.
B1 vs. B2) automatically or by explicit user action. Decided: **explicit
only**, matching the existing product's mode-cycling UX (today's
left-Option+Shift mode cycle) rather than introducing a new classifier
model or heuristic. The user always knows which capability they're
invoking before they speak, because they just selected it.

This also resolves where module A's scope stops: per a separate decision
(recorded in memory, not repeated here), **A is deliberately scoped to
match OpenTypeless's existing approach** (inject the entity dictionary into
the correction/polish prompt, let the model apply it) rather than a
bespoke phonetic-matching algorithm. A is not being treated as a design
priority going forward.

## 2. The mode surface

Four ways to trigger the app, each explicitly selected (mode cycle, hotkey,
or a UI action on already-produced/selected text):

| Trigger | Path | Behavior |
| --- | --- | --- |
| Transcribe mode | A only, bypasses B1/B2 | Unchanged from spec 1 §3.1: dictation, cleaned up, shipped as-is. |
| Select text -> "Polish" action | B1 | Same shape as today's `smartEdit` selection branch: user selects text, then must speak an explicit instruction (e.g. "make this sound like a formal email"); no instruction spoken means nothing happens, matching the existing "must hear an explicit edit intent" invariant. This is a promotion of an existing behavior to a standalone, explicitly-triggered action rather than an implicit branch of a 5-way mode. |
| Translate / X Reply modes | B1 | Unchanged in shape from today's `english`/`xReply` modes — folded into B1 as two more one-shot cases, not given new behavior here. |
| "Ask Anything" mode (new) | B1 | No selection needed. User switches to this mode and speaks a question; gets an answer. This is new — none of today's modes answer a spoken question (transcribe and smartEdit-without-selection both deliberately preserve a question as a question rather than answering it). Opentypeless has a similar `voice_intent` "Ask Anything" concept worth reviewing when this is implemented (see `docs/references/opentypeless-stt.md`). |
| Agent mode (new) | B2 | Standalone mode. User switches to it and speaks a task description; it is dispatched directly, no confirmation step (see §3). |

## 3. B2 dispatch: send-then-show, not confirm-then-send

Decided: once the user finishes speaking in Agent mode, the corrected
transcript is dispatched to the Agent Runtime immediately — there is no
pre-send confirmation/edit step. What was sent is then shown transparently
(non-blocking) so the user can see exactly what their agent received. This
matches the low-friction "say it and it's done" feel of every other mode
in the product, at the cost of an occasional misheard task getting
dispatched before the user notices — accepted trade-off, not treated as a
safety problem, since B2's own draft-only/never-auto-execute invariant
(spec 1 §3.2) is the actual backstop against consequential mistakes, not
this transparency step.

## 4. Agent task visibility: a Task List panel

Because B2 tasks can run far longer than B1's near-instant one-shot calls,
and more than one can plausibly be in flight, the menu bar app gets a new
**Task List panel**: shows in-flight and completed Agent runs, each
expandable to see its dispatched input and current progress/result.
Completion is signaled the same way other modes already signal completion
(the existing OpenType Air sound cue / icon state change) rather than
inventing a new notification mechanism.

## 5. What's still deferred

- The Agent Runtime itself: loop shape, how it calls tools/MCP servers,
  what safety boundaries wrap tool execution, how a run reads from C's
  memory/context interfaces, which provider/model it uses and how that's
  configured.
- "Ask Anything" mode's exact system prompt and any output-fidelity rules
  (analogous to `EnglishOutputPolicy`/`LightTranscriptionPolicy` for the
  existing modes).
- The Task List panel's exact data model, persistence, and cancellation
  semantics for an in-flight run.
- Whether/how a dispatched-but-misheard Agent task can be cancelled after
  the fact, given there's no pre-send confirmation step.
