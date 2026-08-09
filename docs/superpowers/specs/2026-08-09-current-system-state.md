# OpenType macOS: current system state (as-built reference)

Status: descriptive, not a design doc. This is a snapshot of what the macOS
client actually does as of 2026-08-09, after a from-scratch rewrite (old
6-mode system deleted, then cut to exactly 3 modes, MLX-Whisper added for
local ASR, and the UI split Alfred-style into a menubar popover + a real app
window). It supersedes the mode/architecture *content* of earlier specs in
this directory for "what does the system do right now" purposes — those
specs (`2026-08-08-system-boundaries-and-memory-v1-design.md`,
`2026-08-09-b1-b2-mode-surface-design.md`,
`2026-08-09-b2-agent-runtime-v1-design.md`) are left as-is as a record of how
the design got here, and are still useful for *why* things are shaped this
way, but their mode lists (4-6 modes, Polish/Translate/X Reply, per-provider
tool-calling requirements) are stale. This doc is scoped to macOS only —
iOS/Android/`Shared/OpenTypeContract.json` were not part of this rewrite and
are not covered here; see the root `CLAUDE.md` staleness note.

## 1. The 3 modes

`InputMode` (`Sources/OpenType/Models.swift`) has exactly three cases:

| Mode | Selection needed? | What happens | Sidecar call |
| --- | --- | --- | --- |
| `transcribe` | No | Whatever MLX-Whisper hears is the result, verbatim. No LLM involved at all. | `/asr/transcribe` only |
| `ask` | No | Speaks a question; answered directly in a floating popup (`AskPanelController`). The one mode that *answers* rather than preserves/transforms the input. | `/asr/transcribe` then `/oneshot/ask` |
| `agent` | No | Speaks a task; dispatched non-blockingly to a tool-calling agent loop. Result + step log shown via the Task List panel and a completion notification, not a popup the user waits in front of. | `/asr/transcribe` then `/agent/run` |

Every mode's result is always copied to the clipboard (`OutputDeliveryPolicy.retainsClipboardCopy`, unconditionally `true`). Auto-insert into the currently-focused field is a separate, additional delivery step gated on the `automaticallyInsert` setting — never a replacement for the clipboard copy. `agent` is draft-only: its result is never auto-inserted with "press enter" semantics (`OutputDeliveryPolicy.permitsAutomaticEnter` returns `false` for `.agent`), since a tool call inside the loop is itself an external action the instant it runs — this is a policy backstop, not a technical sandbox (see §6).

Mode switching is explicit — mode cycle (hotkey), the menubar popover's `ModeGrid`, or a spoken mid-recording trigger ("agent 模式" / "agent mode" / etc., `VoiceModeRouter`) — never automatic classification of an ambiguous utterance.

## 2. The sidecar

`sidecar/` (TypeScript/Bun) is a separate local process the Swift app spawns and manages (`Sources/OpenType/SidecarClient.swift`), talking to it via `curl` over a Unix socket (not a native HTTP transport — see §7). It owns every actual ASR/text-generation call, plus a separate local memory store the Swift side doesn't share state with directly (see §4). See `sidecar/README.md` for how to run/test it standalone.

Endpoints (`sidecar/src/server.ts`):

| Method + path | Purpose | Backing file(s) |
| --- | --- | --- |
| `GET /health` | Liveness check `SidecarClient.start()` polls before considering the sidecar ready. | `server.ts` |
| `POST /oneshot/ask` | Ask mode: one DeepSeek call with a fixed system prompt + light memory-term context, no fidelity validation (this mode is allowed to answer). | `src/oneshot/routes.ts`, `prompts.ts`, `memoryContext.ts` |
| `POST /agent/run` | Agent mode: the tool-calling loop (see §3), returns `{ result, steps }`. | `src/agent/routes.ts`, `loop.ts` |
| `GET /memory/terms` | Read-only list of the sidecar's entity dictionary, shown in Settings' Memory panel. | `src/memory/routes.ts` |
| `GET /memory/consolidation-runs` | Read-only log of past consolidation ("dreaming") runs, also shown in Settings. | `src/memory/routes.ts` |
| `POST /asr/transcribe` | Local ASR: base64 WAV in, transcript out. Proxies to a persistent local MLX-Whisper python process. | `src/asr/routes.ts`, `whisperClient.ts` |

## 3. Agent Runtime (`/agent/run`)

Loop shape (`sidecar/src/agent/loop.ts`): assemble system prompt + task + context + memory terms → call DeepSeek with the connected MCP tool list attached → if the model requests a tool call, execute it via the MCP client and loop back; otherwise the model's text is the final result. A progress event (`thinking`/`tool_call`/`tool_result`/`done`/`error`) is emitted after every step for the Task List panel. Hard iteration cap: `MAX_ITERATIONS = 10` (`loop.ts`).

MCP tools are configured via the `OPENTYPE_MCP_SERVERS` env var (JSON; see `sidecar/src/agent/mcpClient.ts`) — no tools connected if unset, and Agent mode still runs (it just won't call anything). **Safety boundary is policy, not enforcement**: only no-side-effect tools (search/read/lookup/compute) are the intended use; the runtime does not inspect, allowlist, or block tools by capability. Nothing technical stops a write-capable MCP tool from being connected.

On the Swift side, an Agent dispatch is non-blocking: `AppModel.dispatchAgentRun` records a `.running` `AgentRunRecord` immediately and hands the actual `/agent/run` HTTP call to a detached, un-awaited `Task`, so a slow multi-step run never blocks a second recording (including a second Agent task) from starting. `agentRuns` (`AgentRunTracking.swift`) is an in-memory-only bounded history, capacity 50, oldest evicted first — not persisted to disk, distinct from the sidecar's own durable audit trail.

## 4. ASR: local MLX-Whisper

`sidecar/whisper/serve.py` runs a persistent local Python process (default model `mlx-community/whisper-small-mlx`, overridable via `OPENTYPE_WHISPER_MODEL`) that `sidecar/src/asr/whisperClient.ts` spawns once at sidecar startup and reuses for every `/asr/transcribe` request over its own Unix socket. Model loading has real multi-second latency; the sidecar doesn't block its own `/health` on it — only the first actual transcription request waits for the model to finish loading. There is no cloud ASR fallback and no per-request language hint sent to Whisper (it auto-detects); `TranscriptionLanguage` (`Models.swift`) survives only as the Apple on-device live-caption *preview's* locale, unrelated to the real transcription.

For a packaged `.app`, `build-app.sh` bundles `sidecar/whisper-env/` (the Python venv) and `sidecar/whisper/` into the app's Resources, and `SidecarClient` points the sidecar at those absolute bundled paths via `OPENTYPE_WHISPER_PYTHON_BIN`/`OPENTYPE_WHISPER_SCRIPT_PATH` — a `bun build --compile` binary has no reliable way to locate the original source checkout at an arbitrary launch-time cwd.

## 5. Text generation: DeepSeek

`sidecar/src/provider/deepseek.ts` is the only text-generation provider client — no pluggable provider selection, no user-facing "choose your model" UI anywhere in the current design (Settings' old Provider Vault / speech-provider / text-provider pickers were removed as dead code in this cleanup pass; see the audit-trail note below). Configured via `DEEPSEEK_API_KEY` / `DEEPSEEK_MODEL` (default `deepseek-v4-flash`) / `DEEPSEEK_BASE_URL` env vars (`sidecar/src/env.ts`). For a packaged app, `build-app.sh` copies the sidecar's `.env.local` into `Contents/Resources/sidecar.env`, and `SidecarClient.loadBundledEnvironment` reads it back at runtime — the only way the bundled binary learns the API key, since a compiled binary can't find the source checkout's `.env.local` on its own.

`Sources/OpenType/ImmutableAuditStore.swift` audit events (`recognized`/`completed`/`cancelled`/`failed`, one JSONL file, append-only, never rewritten) now record fixed `provider`/`model` labels reflecting this fixed pipeline (`"mlx-whisper"` for ASR, `"deepseek"` / `deepseek-v4-flash` for text generation) rather than a resolved user-configured provider — there is no longer a provider configuration to resolve.

## 6. Memory: two separate systems

These do **not** share storage and should not be confused:

- **Swift-side** (`Sources/OpenType/AgentMemoryStore.swift`, `HistoryStore.swift`, `OwnerProfileAutoUpdater.swift`, `MemoryInsightsAnalyzer.swift`, `LocalMemoryRetriever.swift`): local SQLite-backed task history plus a manually-confirmed "About Me" profile (never auto-rewritten by the app) and periodically-consolidated "Learned Preferences" (recomputed every 100 recorded tasks). Injected into Agent-mode's *Swift-side* context assembly with a budget cap of roughly the 12 most recent tasks.
- **Sidecar-side** (`sidecar/src/memory/`): a separate SQLite entity dictionary (`MemoryStore.ts`) built from episodic events, with its own periodic consolidation ("dreaming") pass (`consolidator.ts`, gated on at least 12 hours since the last run) that proposes/accepts canonical terms + aliases. Read-only visible in the macOS Settings "Memory" panel via `/memory/terms` and `/memory/consolidation-runs` — no rollback UI, view-only.

`/oneshot/ask` and `/agent/run` both pull a light "known terms mentioned in this input" context from the sidecar-side store (`sidecar/src/oneshot/memoryContext.ts`) before calling DeepSeek — a plain "Known terms: ..." line, not the fuller structured memory-profile prompt the old Swift-native `PromptBuilder` used to assemble (that file no longer exists).

## 7. UI: Alfred-style menubar + window split

- **Menubar `NSPopover`** (`MenuBarPopoverView.swift`): compact mode-switcher only — pick transcribe/ask/agent, glance at sidecar/shortcut status. Opened from the status-bar icon.
- **Real app window** (`RootView` in `Views.swift`, opened via the popover's gear button or a tapped Agent-completion notification): Home (setup checklist, last result), History, and all of Settings — appearance, transcription-language picker, personal dictionary, connection/permissions, the read-only Memory panel, the Agent Task List, and local data management (reset history / relearn preferences).

There is no cloud-provider setup step anywhere in this UI. The old "Setup" checklist used to gate readiness on a connected cloud provider (a DashScope API key); that gate and its Settings "Provider Vault" token-entry UI were dead — the pipeline hasn't used a user-configured cloud provider since ASR/text-generation moved to the sidecar — and were removed in this cleanup pass, along with the underlying `AIServiceClient`/`AIProvider`/`ProviderVault`/`CredentialProvider` Swift types (see git history around this doc's date for the diff). Setup readiness is now just microphone + Accessibility + (optionally) Speech Recognition permissions, plus the global hotkey registering successfully.

Two presentation bugs in this split were fixed after the doc's first pass:

- **`.dispatched` overlay never auto-hid.** `OverlayController.show(state:mode:)`'s dismiss switch had no `.dispatched` case, so the "已下发给 Agent" toast fell through to `default: break` and stayed on screen until the next overlay replaced it. Now dismissed after 1.6s — longer than the 0.9s `.success`/`.copied` case because it carries a second line of copy.
- **No Dock icon / Cmd-Tab, and activation could surface the wrong surface.** The app pinned `.accessory` for its whole lifetime and `applicationDidBecomeActive` unconditionally called `showPopover()`. Opening the main window now switches to `.regular` (Dock icon, Cmd-Tab-able) and `MainWindowController`'s new `NSWindowDelegate` reverts to `.accessory` on close. Activation is funnelled through one `handleReactivation()`: a status-item click (timestamped in `togglePopover`) only ever shows the popover, a Dock/Cmd-Tab activation with the main window open just brings that window forward, and only an accessory-mode reopen shows the popover — which keeps the macOS 26 `applicationShouldHandleReopen` workaround intact.

- **No discoverable way to quit.** The popover had no quit action at all, and the main window's only one was an unlabelled `xmark` circle in `HeaderView` that reads as "close this window" — especially now that closing the window really does just drop the app back to menu-bar-only. Both surfaces now carry a labelled "退出 OpenType" / "Quit OpenType" action (`power` glyph) calling `AppModel.quit()`; the popover's is the one that always works, since with the window closed there is no Dock icon and no app menu to quit from.

## 8. Direct vs. Review transcribe mode

`transcribe` mode now has two variants, chosen by a persistent Settings toggle (`AppConfiguration.transcribeVariant`, `TranscribeVariant` in `Models.swift`, Settings' "转写" section) that applies to every `transcribe`-mode recording until changed — not a per-recording choice:

- **Direct** (default, unchanged behavior): hotkey → speech → the transcript is delivered immediately via the existing pipeline (clipboard + optional auto-insert). This is exactly the pre-existing `.transcribe` code path; nothing about it changed.
- **Review**: hotkey → speech → the transcript is stashed in a floating, editable Review panel (`ReviewPanelController.swift`) instead of being delivered anywhere. Nothing is inserted or copied until the user explicitly commits.

### Why a Settings toggle, not a new `InputMode`

Review is a delivery-timing variant of `transcribe` (same ASR, same "preserve verbatim" semantics, same no-LLM-by-default character), not a new mode with its own prompt/behavior contract — so it's a second axis (`TranscribeVariant`) crossed with the existing mode enum, not a 4th `InputMode` case. This keeps `InputMode.visibleModes` (and everything keyed off it — the mode-cycle hotkey chord, `VoiceModeRouter`, the menubar `ModeGrid`) unchanged.

A per-invocation trigger (e.g. a hotkey chord meaning "this one recording, review it") was considered and deliberately not added: `GlobalHotKey`'s existing chord surface (left-Option hold/double-tap presets, Option+Shift to cycle mode, Tab to mode-switch mid-chord) is already dense, and every remaining unclaimed combination would either conflict with a preset or need its own discoverability affordance. The Settings toggle is simple, discoverable, and — per the task brief — required to work standalone regardless, so it was built as the only mechanism rather than half-building a second one.

### The correction flow, end to end

1. **Original dictation** (Review variant active): `AppModel.process(audioURL:)`'s `.transcribe` branch transcribes as normal, appends the usual `.recognized` audit event, then calls `beginReviewSession(...)` instead of delivering — this shows the panel (`reviewPanelState`) and records session bookkeeping (`ReviewSession`: `requestId`, the originally-captured `CapturedContext`, and the last audit event id for chaining). The panel is an `NSPanel` with `.nonactivatingPanel` + a `canBecomeKey` override — the same pattern `AskPanelController` and `OverlayController` already establish — so the app that was focused when dictation started stays frontmost the whole time the panel is open.
2. **Editing**: the panel wraps a real `NSTextView` (`ReviewTextView`, an `NSViewRepresentable` — SwiftUI's `TextEditor` selection-binding API needs macOS 14 and this app targets macOS 13) rather than mirroring text through `@Published` SwiftUI state on every keystroke. The user can type directly; the text view is the sole source of truth for "current text" once shown.
3. **Voice correction**: with the panel open, a second hotkey press means "correction for the panel's current selection," not "start a new dictation" — `AppModel.hotKeyPressed()` checks `reviewPanelState != nil` first and, if the panel has no text selected, gives immediate feedback (no wasted recording) rather than proceeding. Selection existence is checked *before* recording starts; the recording itself only captures the spoken instruction (ASR only — no `VoiceModeRouter`/mode-switch parsing applies to a correction recording). `processCorrection(audioURL:)` then calls the sidecar's new `POST /transcribe/correct` with the panel's full current text, the selection as a UTF-16 offset range, and the transcribed instruction; the response's `replacement` is spliced back into the `NSTextView` at the same offsets (`ReviewPanelController.applyCorrection`, via `TextSpanCorrection`) and the new span is re-selected so a follow-up correction can immediately target it again. Selecting the entire text and speaking a rewrite instruction (e.g. "rewrite this more formally") uses the identical mechanism with no special-casing — the endpoint doesn't distinguish "small span" from "whole text."
4. **Commit** (Enter button / **Cmd+Return**, not bare Return — see below) or **Cancel** (Escape / Cancel button / click outside the panel): commit inserts the panel's current text via the same `ContextBridge.insert(...)` Direct mode uses (always copies to clipboard too), records a `HistoryEntry`, and appends the session's final `.completed` audit event; cancel discards everything and appends a `.cancelled` event with no result.

**Why Cmd+Return, not bare Enter, for commit**: the panel is a real editable multi-line text view, where bare Return is expected to insert a newline (the user may want a multi-line corrected result). Overloading bare Return as "commit" would make it impossible to type a newline. Cmd+Return is the standard macOS resolution for exactly this conflict (Mail/Slack-style compose-and-send) and is shown next to a visible "写入 (⌘↩)" button; Escape is unambiguous (text views don't use it for anything) and is bound directly, both as a button and via `.onExitCommand`. This is a deliberate refinement of the task brief's "Enter to commit" framing, not a literal implementation of it.

### Audit chain, not a single event

Per session, `ImmutableAuditStore` now records more than one linked event, all sharing one `requestId` and chained via the (previously-scaffolded-but-unused) `supersedesEventId` field rather than a parallel logging structure:

- `.recognized` — the original dictation (already existed; reused as the chain's first link).
- `.corrected` (new `AuditEventStatus` case) — one per correction round. `rawTranscript` = the spoken instruction, `selectedContext` = the substring that was replaced, `effectiveInput` = the model's replacement, `result` = the full text after splicing — all existing fields, repurposed for this event kind rather than new ones being added.
- `.completed` (commit) or `.cancelled` (discard) — the session's final outcome, `supersedesEventId` pointing at the last correction (or the original `.recognized` event if there were no corrections).

A reader can replay the whole session — original text, every correction instruction and its result, and the final outcome — by following `supersedesEventId` from the terminal event backward, not just see the last state.

### Sidecar: `POST /transcribe/correct`

New endpoint, `sidecar/src/transcribe/{routes,prompts}.ts`, TDD'd (`sidecar/test/transcribe/correct.test.ts`, 8 tests, confirmed red — `Cannot find module` — before implementation, green after). Takes `{ fullText, selectionStart, selectionEnd, instruction }` (offsets, not the selected substring alone, per the task brief's own reasoning: unambiguous even when the target phrase repeats elsewhere in the text) and returns `{ replacement }` only — the caller splices it back in, the endpoint never sees or returns the rest of the document. Deliberately takes a bare `chat` function (same DI shape as `buildOneShotRoutes`) with no `MemoryStore`/entity-dictionary dependency, keeping it pure, dependency-light logic; validates the selection range (400 on `start >= end`, out-of-bounds, or a blank instruction) before ever calling the LLM.

Offsets are UTF-16 code units on both ends of the wire — `NSTextView.selectedRange()`/`NSRange`/`NSString` on the Swift side and native JS string indexing (`.slice`) on the sidecar side use the exact same representation, so raw integers pass through with no re-encoding step that could introduce an off-by-N bug for text outside the Basic Multilingual Plane. `TextSpanCorrection.swift` (Swift) documents and unit-tests this; a sidecar test (`"uses UTF-16 code unit offsets..."`) checks the same contract from the other end.

### What was drawn from OpenTypeless, and what wasn't

Per `docs/references/opentypeless-stt.md`: OpenTypeless has no panel-based review/stash step and no voice-scoped span-correction endpoint — its closest analog is `SELECTED_TEXT_ADDON`, a prompt fragment appended when text is already selected in the *target app* at request time, always going through its single always-on "polish" LLM pass. Nothing here was ported directly. What *was* useful as a reference:

- The reference notes' framing of "faithful correction, not generative rewrite" as something OpenTypeless leaves to prompt wording alone, with no structural guard — this is exactly why `CORRECTION_SYSTEM_PROMPT` is scoped hard ("Return ONLY the replacement text for the selected span... Never change or repeat anything outside the selected span") and why the Swift side splices only the returned span back in by offset rather than trusting the model to return a whole corrected document — a structural guard OpenTypeless doesn't have anywhere in its pipeline.
- Confirms this feature is new ground, not an adaptation of existing prior art: OpenTypeless's own roadmap treats automatic/voice-driven personal-vocabulary correction as an unscheduled, unimplemented gap (see that doc's "Still a gap" section) — this feature's whole mechanism (select a span inside a *stashed, not-yet-delivered* result, speak a correction, splice in place) has no OpenTypeless equivalent to diverge from or borrow beyond the general "faithful, narrowly-scoped correction" principle above.

### Verification status (as of this doc)

- **Sidecar**: `bun test` — 135/135 pass (127 pre-existing + 8 new), confirmed genuinely red (`Cannot find module`) before implementation.
- **Swift**: `swift build` (debug) and `swift test` — 64/64 pass (58 pre-existing + 6 new: `TranscribeVariant` persistence, `TextSpanCorrection` splicing including the exact "呸泡→PayPal" example, `.corrected`/`.cancelled` audit-event round-trip and `supersedesEventId` chaining).
- **Real packaged app, backend pipeline**: `./scripts/build-app.sh` succeeded; the compiled `dist/OpenType.app` was launched fresh (quit any prior instance, `open`'d cold) and its bundled sidecar (real MLX-Whisper + real DeepSeek, not mocks) was driven directly over its Unix socket with `say`-synthesized speech audio (not typed text) end to end: `/asr/transcribe` on a spoken "请把这笔钱通过呸泡转给他" and a spoken correction instruction, then `POST /transcribe/correct` with the mangled span and the (itself imperfectly-ASR'd, realistically noisy) instruction correctly returned `{"replacement":"PayPal"}` — the task brief's own motivating example, reproduced against the real compiled binary and a real LLM call, not a fake. A whole-text rewrite call and a 400-on-invalid-selection call were also verified against the real binary.
- **Real packaged app, GUI/hotkey/mic-capture loop**: **not verified via an actual physical microphone or global-hotkey keypresses.** As a non-interactive coding agent this session has no mechanism to produce live microphone input or drive `GlobalHotKey`'s system-wide event tap the way a person would, so the Review-panel-appears → select-a-word → speak-a-correction → commit loop was verified by code review, the unit tests above, and the backend pipeline proof above, not by a literal end-to-end mic-driven run. The packaged app was confirmed to launch cleanly (health check OK, MLX-Whisper model loaded, no crash reports) under the new code. This gap is called out explicitly rather than glossed over — see the report for this work for the same caveat.
- **Shared-runtime-resource discovery** (process hygiene note, not a regression from this feature): `SidecarClient`'s Unix socket, the sidecar's SQLite DB, and `ImmutableAuditStore`'s JSONL file all live under a fixed path keyed only by the app's bundle identifier (`~/Library/Application Support/OpenType/...`, `defaults` domain `ai.rain.opentype`) with no per-checkout/per-worktree namespacing. Running the packaged app from two worktrees (or a worktree and the main checkout) concurrently means whichever instance's sidecar binds the socket path *last* silently wins routing for both — observed firsthand during this session's verification (a concurrently-running main-tree instance's older sidecar briefly intercepted this worktree's `/transcribe/correct` requests as `not_found` until isolated via a standalone instance with overridden `OPENTYPE_SIDECAR_SOCKET`/`OPENTYPE_WHISPER_SOCKET`/`OPENTYPE_SIDECAR_DB_PATH` env vars). Not fixed as part of this feature (out of scope), but worth a future hardening pass — see also §9's existing note that quitting the app doesn't reliably clean up the sidecar's own child processes (whisper), which compounds this.

## 9. Known gaps / explicitly deferred

Carried forward from the overnight build log and design specs, still true as of this doc:

- **No cloud-provider picker.** Deliberate, not a regression — see §5/§7. If a pluggable-provider design comes back, it needs new product decisions, not a revert of this cleanup.
- **Agent Task List history is in-memory only**, capacity 50, lost on quit — not the durable audit trail (`ImmutableAuditStore` is durable but is a flat append-only log, not a queryable run history).
- **MCP tool-calling has no real server tested against it** — `sidecar/test/agent/mcpClient.test.ts` covers `connectConfiguredMcpServers`/tool-call routing against fakes only; nobody has run Agent mode against a real, running MCP server end-to-end yet.
- **No technical enforcement of the no-side-effect-tools policy** (§3) — policy-only, by design, for v1.
- **`SidecarClient`'s transport is `curl` per request over a Unix socket**, not a native HTTP client — a known simplification flagged for a future pass, not a currently-planned fix.
- **No Memory-panel rollback UI** — `/memory/consolidation-runs` is read-only; a bad consolidation pass can't be undone from the UI yet (the sidecar's DB may support it internally; not exposed).
- **iOS/Android are untouched by this rewrite** — see the root `CLAUDE.md` staleness note; don't treat anything in this doc as describing their current behavior.
- **Review-mode voice correction is unverified against a real microphone/hotkey** — see §8's verification note; the backend (`/transcribe/correct`) and all pure logic are proven, but no agent session has yet driven the full mic-capture loop live.
- **Sidecar/history/audit runtime paths are not per-worktree-scoped** — see §8's "shared-runtime-resource discovery" note; concurrent packaged-app runs across worktrees/checkouts can silently steal each other's socket/DB.
