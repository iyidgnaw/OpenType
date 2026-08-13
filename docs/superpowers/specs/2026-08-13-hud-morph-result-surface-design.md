# OpenType: unified voice surface — HUD morphs into the result card

Status: approved design (product owner decisions, 2026-08-13 session).
**Supersedes the presentation layer** of
`2026-08-13-agent-progress-panel-design.md` (the top-right panel); that
spec's transport/state infrastructure (progress registry, polling,
`AgentProgressPanelState`, step mapping) is **retained and reused**.

## 0. Owner's requirement (verbatim intent)

After the user finishes speaking in ask/agent mode there must be
continuous, in-place feedback: the live-caption HUD should show a
"received, processing" animation (bouncing dots), keep indicating while
the LLM thinks / the agent works, and when the result arrives the same
window should **resize with a gradual animation into a temporary result
card** containing the answer. All assistant-text surfaces must render
**Markdown**. Agent-mode "effects" (previewing a file, playing media)
are delivered by the system-default app via `opentype__open_file` (see
the open-file spec) — the card shows text; media opens in real apps.

## 1. One window, one state machine

`OverlayController` (the existing bottom-center HUD panel) becomes the
single surface for the whole ask/agent interaction lifecycle. One
NSPanel whose size and content are driven by a state enum; **no separate
Ask popup and no top-right agent panel anymore.**

States (transcribe mode's existing behavior — listening pill, toasts,
Review panel — is unchanged):

| State | Visual | Size (approx) |
|---|---|---|
| `listening` | existing live-caption pill | 388×96 (existing) |
| `processing` | pill stays; waveform crossfades into three breathing/bouncing dots + "正在整理…" (ASR running) | 388×96 |
| `working` | dots continue; ask: "正在思考/搜索…"; agent: one-line live step ticker under the dots ("正在调用 web_search…"), fed by the existing progress polling | 388×~120 |
| `result` | the panel frame **animates** (`setFrame(_, display: true, animate: true)`) from the pill into a bottom-center card growing upward; content crossfades to: mode badge, the spoken task/question, **Markdown-rendered** answer/result (scrollable, selectable), collapsible step list for agent, buttons 复制 / 打开主窗口 / 关闭 | up to ~620×480, content-driven |
| `failed` | same card, error text | card |

Transition rules:
- Dismissal: Escape and the 关闭 button always; **click-outside
  dismisses only in `result`/`failed`** (never while `working` — the
  user must be able to click away and keep working during a long agent
  run without killing the surface).
- Dismiss during ask `working` cancels the ask task (today's
  `dismissAskPanel` ghost-answer semantics move here). Dismiss during
  agent `working` hides the surface but **never cancels the run**
  (result still lands in clipboard/notification/Agent tab).
- A new recording resets the surface to `listening`; an in-flight agent
  run continues in the background, an in-flight ask is cancelled (same
  as dismissing it).
- The transient toast states (`modeChanged`, `success`, `copied`,
  `dispatched`) keep their current behavior for transcribe; ask/agent no
  longer route through the `dispatched` toast — they go `processing →
  working` instead.
- One window, two owners, so a transient toast that would otherwise be
  swallowed by a live surface **preempts** it for its usual duration and
  the surface (as it stands *then*) comes back afterwards —
  `OverlayController.presentToast`. Two cases use it: a pipeline
  **failure** (`AppModel.fail(_:)`, which must never be silent just
  because a stale card or a still-ticking agent owns the panel, and must
  not tear that run's surface down either) and the **mode-changed**
  toast. A new recording (`.listening`) cancels any live preemption.
- The surface is derived from a *mode*, and the mode it belongs to is the
  active recording's, else the mode of the run still on the surface
  (`AppModel.surfaceRunMode`), else the selected mode. A dispatched run
  outlives `activeMode` and need not match the selected mode at all
  (`VoiceModeRouter` can route into `.agent` from any mode; the practice
  flow forces `.ask`), and switching modes retires a *settled* card
  outright rather than leaving it live-but-invisible.

Pure-logic seams (unit-testable, `OverlayHideBehavior` precedent):
- A reducer mapping (mode, ProcessingState, ask/agent panel state) →
  surface state + target panel size.
- Bottom-center-anchored frame math: given screen `visibleFrame`, a
  target size, and the fixed bottom margin (54pt, as today), the frame
  keeps the bottom edge fixed and grows upward/centered.
- Reuse `AgentProgressPanelState.steps(fromProgressEvents:)` and
  `shouldContinuePolling(for:)` unchanged.

## 2. What gets replaced

- `AskPanelController` (center-screen popup): ask answers now render in
  the unified surface. The controller and its `askPanelState` plumbing
  are removed once the surface covers ask (keep `AskPanelState` only if
  still useful as the ask-side state model; otherwise fold into the
  surface state).
- `AgentProgressPanelController` (top-right, committed `746d25d`): the
  SwiftUI step-feed/result content is adapted into the card; the
  separate top-right window is removed. `AgentProgressPanelState`,
  `SidecarClient.agentProgress`, the polling task in `AppModel`, and the
  sidecar progress registry/endpoint are all reused as-is.

## 3. Markdown everywhere

Add the **MarkdownUI** SwiftPM dependency
(`https://github.com/gonzalezreal/swift-markdown-ui`, 2.x) to
`Package.swift` and render assistant text with it (GitHub-flavored:
code blocks, lists, tables) in:
- the result card (ask answers, agent results),
- the Q&A tab conversation thread,
- the Agent tab conversation thread.

User-spoken text stays plain. A small shared wrapper view (e.g.
`AssistantMarkdownView`) keeps styling consistent (theme-aware, selectable
where the container allows). `build-app.sh` needs no change (SwiftPM
static linking); note the release build now needs network on first
resolve.

## 4. Out of scope

- Embedded media players in the card (system apps via open_file cover it).
- Per-step display for ask mode (generic thinking/searching indicator only).
- Changing transcribe/Review-panel behavior.
- Streaming per-token answer text (polling/blocking transport unchanged).
