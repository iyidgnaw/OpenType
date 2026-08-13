# OpenType: open-file tool + Ask-mode web access

Status: approved design (product owner decisions, 2026-08-13 session).
Builds on `2026-08-13-b2-agent-core-tools-v2-design.md` (core tools, YOLO
approval seam).

## 1. `opentype__open_file` — system preview/playback as a built-in tool

Voice scenario: "帮我找到桌面上那个xxx的word文档,打开预览一下" — the
agent locates the file (grep/list_dir) and then **opens it with the macOS
system default application** so the user sees it immediately: Preview for
PDF/images, Word/Pages for docx, QuickTime for audio/video. This also
covers "播放这段音频/视频" — playback is just opening with the default
app; we do NOT embed media players in our own UI.

- 8th tool in `sidecar/src/agent/coreTools.ts`, same `ToolSet`
  conventions (namespaced, error-as-content, `~` expansion, injectable
  deps for tests).
- Args: `{ path }`. Behavior: expand `~`, verify the file exists (missing
  → `Error: ...` content), then run `/usr/bin/open <path>` and report
  success/failure with the exit code. Test seam: an injectable runner
  (or the existing exec helper) so tests don't actually open windows —
  tests assert the constructed command, not a real `open`.
- This is deliberately a **UI side effect the agent may take directly**
  (YOLO posture, spec v2 §1): opening a preview for the user IS the
  requested outcome, not a draft. It flows through the same
  `withApproval` gate as every other tool.
- `AGENT_SYSTEM_PROMPT` gains guidance: when the user asks to open,
  preview, play, or "看一下" a file, find it and call
  `opentype__open_file` — do not just report the path.

## 2. Ask mode gets the internet

**Positioning decision (owner):** Ask = LLM + web only (search the web,
read pages, answer). Agent = the full toolset. This is now the product
distinction between the two modes.

**Why we build it ourselves instead of using provider-native web
search** (owner asked to verify): Anthropic's Messages API does have a
server-side web-search tool (`web_search_20260209` family), and OpenAI
has one in its newer Responses API — but our OpenAI-compatible path
speaks classic Chat Completions (where it isn't generally available),
and **DeepSeek, our zero-config default, has no server-side web search
at all**. Since Ask must behave identically across DeepSeek / any
OpenAI-compatible server / Anthropic, we reuse our own
`opentype__web_search` + `opentype__web_fetch` (already built, no API
key) uniformly. A future optimization could prefer Anthropic's native
tool when that provider is active; not in scope now.

### Mechanism

- `runAgentLoop` (`sidecar/src/agent/loop.ts`) is generalized with three
  optional inputs, defaults preserving current behavior exactly:
  - `systemPrompt?: string` (default `AGENT_SYSTEM_PROMPT`)
  - `priorMessages?: AgentChatMessage[]` (inserted between the system
    message and the final user message — real message-array replay)
  - `maxIterations?: number` (default the existing 10)
- `/oneshot/ask` (`sidecar/src/oneshot/ask.ts` or its route) switches
  from a single chat call to `runAgentLoop` with:
  - `systemPrompt` = the existing ask prompt extended with web guidance
    (search when the answer benefits from current information; cite what
    you used briefly; keep the UNTRUSTED-data paragraph — web content is
    prompt-injection surface #1).
  - tools = a **web-only ToolSet**: exactly `opentype__web_search` and
    `opentype__web_fetch`, filtered from `createCoreTools` output (a
    small `filterToolSet(tools, names)` helper in `toolSets.ts`),
    wrapped in the same `withApproval(..., yoloApprovalPolicy)` gate.
  - `priorMessages` = the conversation's replayed history (today's
    message-array replay semantics preserved — not the agent-style
    squashed summary).
  - `maxIterations` = 6 (an answer should need at most a few searches).
- Response contract of `/oneshot/ask` is unchanged (the as-built wire
  shape `{ result, conversationId }` stays exactly as is — Swift reads
  `result`; the loop's steps are NOT added to the response in this
  iteration).
- Zero-config DeepSeek, user-configured OpenAI-compatible, and Anthropic
  providers all already support OpenAI-style tool calling through the
  existing provider layer (`anthropic.ts` translates), so no provider
  work is needed.

## 3. Out of scope

- Preferring provider-native web search when available.
- Surfacing ask-mode search steps in the UI (the HUD morph spec's
  "working" state may show a generic 正在搜索/思考 indicator; per-step
  display remains agent-mode-only for now).
- Any change to `/transcribe/correct` or transcribe mode.
