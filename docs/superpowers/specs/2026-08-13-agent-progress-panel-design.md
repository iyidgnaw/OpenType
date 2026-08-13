# OpenType: Agent progress panel (top-right live feedback)

Status: approved design (owner request, 2026-08-13 session — "说完话 agent
就去执行,我还得点开主程序才能看到结果,这不太对;现在反馈很少").

## 0. Problem

Agent mode today gives almost no feedback: after ASR the HUD flashes a
transient "已下发给 Agent" toast and hides; the run's steps and result are
only visible via a completion notification or by opening the main window's
Agent tab. `/agent/run` is a single blocking call that returns the full
step log only at the end, so nothing *could* show live progress.

## 1. Decision: a standalone top-right floating panel

Two options were considered — (a) a standalone top-right popup, (b) a
panel that "grows out of" the bottom-center live-caption HUD. **(a) wins**:
the HUD is owned by the recording lifecycle and an agent run outlives it
(the user can start new recordings — including new agent tasks — while a
run is in flight), so reusing the HUD surface would make the next
recording's HUD fight the still-running panel. Top-right also matches the
macOS notification convention.

- New `AgentProgressPanelController` (`Sources/OpenType/`), following the
  `AskPanelController` NSPanel + NSHostingView pattern (borderless,
  `.nonactivatingPanel`, floating, canJoinAllSpaces), but positioned at
  the **top-right of the screen's `visibleFrame`** (≈16pt margin) and with
  **no click-outside dismiss** — the user keeps working elsewhere during a
  long run; dismissal is the close button or Escape only.
- The panel appears the moment `/agent/run` is dispatched (task text known,
  right after ASR). The HUD's existing "已下发给 Agent" toast is unchanged.
- Content: mode badge, the spoken task, a live auto-following step feed
  (`thinking` / `tool_call` with tool name+args / `tool_result` / `error`,
  each detail truncated for display), a status line (执行中/完成/失败),
  and — once done — the final result (selectable, scrollable) with the
  已复制到剪贴板 note. Buttons: 关闭, 打开主窗口 (jumps to the Agent tab).
- Dismissing the panel never cancels the run; delivery semantics
  (clipboard + notification + Agent tab/conversation) are unchanged.
- Concurrent runs: the panel always shows the **most recently dispatched**
  run; older runs keep running and remain visible in the Agent tab.

## 2. Live progress transport: polling, not streaming

`SidecarClient` is curl-over-unix-socket; streaming through it is not
practical. Polling a local socket at sub-second intervals is cheap.

### Sidecar side

- `sidecar/src/agent/progressRegistry.ts`: in-memory
  `AgentProgressRegistry` — `runId → { status: "running"|"done"|"failed",
  events: [{type, detail}] }`. Per-event `detail` truncated to ~400 chars
  on append (display feed, not the durable step log). Caps: ≤200 events
  per run, ≤20 retained finished runs (oldest finished evicted first).
- `/agent/run` request body gains an optional client-generated `runId`
  string. When present the handler registers the run, wires `runAgentLoop`'s
  existing (previously unused) `onProgress` hook to append events, and
  marks the run `done`/`failed` when the loop resolves/throws. Absent →
  behavior exactly as before.
- New `GET /agent/progress/:runId` → `{ status, events }`;
  unknown id → `{ status: "unknown", events: [] }` with 200 (simpler
  client; an unknown id is not an error, it's "nothing to show").

### Swift side

- `AgentProgressPanelState` (Models.swift): `runId`, `task`,
  `steps: [AgentProgressStep]` (`kind` + `detail`), `phase`
  (`running`/`succeeded`/`failed`), `result: String?`.
  `AppModel.agentPanelState: AgentProgressPanelState?` drives the panel
  exactly the way `askPanelState` drives `AskPanelController` (nil =
  hidden; AppModel owns truth, controller mirrors).
- `dispatchAgentRun` generates a `runId` UUID, includes it in the request
  body, sets `agentPanelState` (phase `.running`, empty steps)
  immediately, and starts a polling task (~0.7s interval) that calls the
  new `SidecarClient.agentProgress(runId:)` and replaces `steps` each
  tick. When the blocking `/agent/run` response (or error) arrives:
  stop polling, set `result` + final phase. The panel stays until the
  user closes it or a newer run replaces it.
- Panel geometry (top-right frame from a screen rect) is a pure static
  function, unit-tested like `OverlayHideBehavior`.

## 3. Out of scope

- Cancelling a run from the panel (the loop has no cancellation path yet).
- Streaming transport; per-token output.
- Showing multiple concurrent runs in the panel (Agent tab covers that).
- Any change to ask-mode's center-screen panel.
