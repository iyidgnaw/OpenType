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
| `ask` | No | Speaks a question; answered directly in a floating popup (`AskPanelController`). The one mode that *answers* rather than preserves/transforms the input. If the Q&A tab has a conversation open (see §9), the question continues that thread instead of starting a fresh one-shot call. | `/asr/transcribe` then `/oneshot/ask` |
| `agent` | No | Speaks a task; dispatched non-blockingly to a tool-calling agent loop. Result + step log shown in the Agent tab (§7/§9) and a completion notification, not a popup the user waits in front of. Same conversation-continuation behavior as `ask` if the Agent tab has a thread open. | `/asr/transcribe` then `/agent/run` |

Every mode's result is always copied to the clipboard (`OutputDeliveryPolicy.retainsClipboardCopy`, unconditionally `true`). Auto-insert into the currently-focused field is a separate, additional delivery step gated on the `automaticallyInsert` setting — never a replacement for the clipboard copy. `agent` is draft-only: its result is never auto-inserted with "press enter" semantics (`OutputDeliveryPolicy.permitsAutomaticEnter` returns `false` for `.agent`), since a tool call inside the loop is itself an external action the instant it runs — this is a policy backstop, not a technical sandbox (see §6).

Mode switching is explicit — mode cycle (hotkey), the menubar popover's `ModeGrid`, or a spoken mid-recording trigger ("agent 模式" / "agent mode" / etc., `VoiceModeRouter`) — never automatic classification of an ambiguous utterance.

## 2. The sidecar

`sidecar/` (TypeScript/Bun) is a separate local process the Swift app spawns and manages (`Sources/OpenType/SidecarClient.swift`), talking to it via `curl` over a Unix socket (not a native HTTP transport — see §7). It owns every actual ASR/text-generation call, plus a separate local memory store the Swift side doesn't share state with directly (see §4). See `sidecar/README.md` for how to run/test it standalone.

Endpoints (`sidecar/src/server.ts`):

| Method + path | Purpose | Backing file(s) |
| --- | --- | --- |
| `GET /health` | Liveness check `SidecarClient.start()` polls before considering the sidecar ready. | `server.ts` |
| `POST /oneshot/ask` | Ask mode: one DeepSeek call with a fixed system prompt + light memory-term context, no fidelity validation (this mode is allowed to answer). Accepts an optional `conversationId` to continue an existing thread (real chat history replayed, not just a context blob); always returns the (possibly newly-created) `conversationId`. | `src/oneshot/routes.ts`, `prompts.ts`, `memoryContext.ts` |
| `POST /agent/run` | Agent mode: the tool-calling loop (see §3), returns `{ result, steps, conversationId }`. Same optional `conversationId` continuation as `/oneshot/ask`, replayed as a short "previous task / previous result" summary rather than the full tool-call step trace. | `src/agent/routes.ts`, `loop.ts` |
| `GET /memory/terms` | Read-only list of the sidecar's entity dictionary, shown in Settings' Memory panel. | `src/memory/routes.ts` |
| `GET /memory/consolidation-runs` | Read-only log of past consolidation ("dreaming") runs, also shown in Settings. | `src/memory/routes.ts` |
| `GET /conversations?kind=ask\|agent` | Lists Q&A/Agent conversations, most-recently-updated first — backs the Q&A/Agent tabs' list view (§9). | `src/memory/conversations.ts`, `conversationRoutes.ts` |
| `GET /conversations/:id` | Fetches one conversation with its full ordered message list — backs the Q&A/Agent tabs' thread view (§9). 404 if unknown. | `src/memory/conversations.ts`, `conversationRoutes.ts` |
| `POST /asr/transcribe` | Local ASR: base64 WAV in, transcript out. Proxies to a persistent local MLX-Whisper python process. | `src/asr/routes.ts`, `whisperClient.ts` |

## 3. Agent Runtime (`/agent/run`)

Loop shape (`sidecar/src/agent/loop.ts`): assemble system prompt + task + context + memory terms → call DeepSeek with the connected MCP tool list attached → if the model requests a tool call, execute it via the MCP client and loop back; otherwise the model's text is the final result. A progress event (`thinking`/`tool_call`/`tool_result`/`done`/`error`) is emitted after every step for the Task List panel. Hard iteration cap: `MAX_ITERATIONS = 10` (`loop.ts`).

MCP tools are configured via the `OPENTYPE_MCP_SERVERS` env var (JSON; see `sidecar/src/agent/mcpClient.ts`) — no tools connected if unset, and Agent mode still runs (it just won't call anything). **Safety boundary is policy, not enforcement**: only no-side-effect tools (search/read/lookup/compute) are the intended use; the runtime does not inspect, allowlist, or block tools by capability. Nothing technical stops a write-capable MCP tool from being connected.

On the Swift side, an Agent dispatch is non-blocking: `AppModel.dispatchAgentRun` records a `.running` `AgentRunRecord` immediately and hands the actual `/agent/run` HTTP call to a detached, un-awaited `Task`, so a slow multi-step run never blocks a second recording (including a second Agent task) from starting. `agentRuns` (`AgentRunTracking.swift`) is an in-memory-only bounded history, capacity 50, oldest evicted first — not persisted to disk, distinct from the sidecar's own durable audit trail. It now also carries an optional `conversationId`, filled in once the run's response comes back, linking the in-memory record to its persisted conversation (see §9) — `/agent/run` is still a single blocking call, so a run in flight has no persisted conversation entry to show yet.

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

`/oneshot/ask` and `/agent/run` both pull a light "known terms mentioned in this input" context from the sidecar-side store (`sidecar/src/oneshot/memoryContext.ts`) before calling DeepSeek — a plain "Known terms: ..." line, not the fuller structured memory-profile prompt the old Swift-native `PromptBuilder` used to assemble (that file no longer exists). A third, separate table pair (`conversations`/`conversation_messages`, `sidecar/src/memory/conversations.ts`) holds Q&A/Agent multi-turn conversation history — see §9; it shares the same sqlite file as the entity dictionary but is conceptually distinct from both memory systems above (it's turn-by-turn chat history, not a fact/term store).

## 7. UI: Alfred-style menubar + window split

- **Menubar `NSPopover`** (`MenuBarPopoverView.swift`): compact mode-switcher only — pick transcribe/ask/agent, glance at sidecar/shortcut status. Opened from the status-bar icon.
- **Real app window** (`RootView` in `Views.swift`, opened via the popover's gear button, a tapped Agent-completion notification, or `AppTab` selection): Home (setup checklist, last result), History, **Q&A** and **Agent** (past conversations + continuation, §9 — replaces the old Settings "Task List" section), and Settings — appearance, transcription-language picker, personal dictionary, connection/permissions, the read-only Memory panel, and local data management (reset history / relearn preferences).

There is no cloud-provider setup step anywhere in this UI. The old "Setup" checklist used to gate readiness on a connected cloud provider (a DashScope API key); that gate and its Settings "Provider Vault" token-entry UI were dead — the pipeline hasn't used a user-configured cloud provider since ASR/text-generation moved to the sidecar — and were removed in this cleanup pass, along with the underlying `AIServiceClient`/`AIProvider`/`ProviderVault`/`CredentialProvider` Swift types (see git history around this doc's date for the diff). Setup readiness is now just microphone + Accessibility + (optionally) Speech Recognition permissions, plus the global hotkey registering successfully.

Settings' old "关于我" ("About Me") free-text profile editor — three `TextEditor` fields (identity/work, communication style, important terms) plus a default-output-language picker, all bound to `AgentMemoryStore.ownerProfile` — was removed as dead pre-rewrite UI: the sidecar's own `owner_facts`/`entity_terms` (§6, written via the `remember_fact` agent tool) is what the current design actually uses for personalization. `AgentMemoryStore` itself was **not** deleted — it's still the backing store for local task history, "Learned Preferences" auto-analysis, and the Agent-mode Swift-side prompt context (§6), all genuinely still in use; only the free-text editing UI and its `OwnerProfileField` binding plumbing in `Views.swift` were removed. `updateOwnerProfile`/`ownerProfile` remain on `AgentMemoryStore` itself (used internally for legacy-data sanitization and still covered by tests) — there is just no longer any Settings UI that calls them.

## 8. Known gaps / explicitly deferred

Carried forward from the overnight build log and design specs, still true as of this doc:

- **No cloud-provider picker.** Deliberate, not a regression — see §5/§7. If a pluggable-provider design comes back, it needs new product decisions, not a revert of this cleanup.
- **Agent conversation history is now sidecar-persisted** (`GET /conversations?kind=agent`, §9) and survives relaunch; only the "still running this session" indicator in the Agent tab remains in-memory-only (`agentRuns`, capacity 50, lost on quit) — not the durable audit trail (`ImmutableAuditStore` is durable but is a flat append-only log, not a queryable run history).
- **Agent conversation continuation replays a summary, not the full step trace** — a follow-up in the Agent tab knows what was previously asked and delivered, but not the intermediate tool calls from an earlier turn in the same thread.
- **MCP tool-calling has no real server tested against it** — `sidecar/test/agent/mcpClient.test.ts` covers `connectConfiguredMcpServers`/tool-call routing against fakes only; nobody has run Agent mode against a real, running MCP server end-to-end yet.
- **No technical enforcement of the no-side-effect-tools policy** (§3) — policy-only, by design, for v1.
- **`SidecarClient`'s transport is `curl` per request over a Unix socket**, not a native HTTP client — a known simplification flagged for a future pass, not a currently-planned fix.
- **No Memory-panel rollback UI** — `/memory/consolidation-runs` is read-only; a bad consolidation pass can't be undone from the UI yet (the sidecar's DB may support it internally; not exposed).
- **iOS/Android are untouched by this rewrite** — see the root `CLAUDE.md` staleness note; don't treat anything in this doc as describing their current behavior.

## 9. Conversation continuation (Q&A / Agent tabs)

Ask and Agent mode are one-shot by default (a fresh `/oneshot/ask` or `/agent/run` call with no history) but can continue a specific past exchange: the Q&A tab lists past Ask conversations (`GET /conversations?kind=ask`, most-recently-updated first); tapping one fetches its full thread (`GET /conversations/:id`) and marks it as `AppModel.focusedAskConversationId`. The next time Ask mode is dispatched by voice while that id is set, the request includes `conversationId`, and the sidecar replays the conversation's prior messages as real chat history (not a squashed context blob) before the new question — genuine multi-turn continuation, verified against a real DeepSeek call by asking a question that only resolves given the prior turn (e.g. "why do I like it?" after "my favorite language is Rust"). The Agent tab (`AppModel.focusedAgentConversationId`) works the same way, except prior turns are folded into the loop's `context` as a short "previous task / previous result" summary rather than a full message-array replay (Agent's loop message shape doesn't carry arbitrary history the same way).

Leaving the thread view or using the tab's "new conversation" affordance (`AppModel.startNewAskConversation()`/`startNewAgentConversation()`) clears the focused id, so the next dispatch starts fresh again. A tapped Agent-completion notification (`focusAgentRun(_:)`) now selects the Agent tab and opens that run's conversation thread directly, using the `conversationId` recorded onto its `AgentRunRecord` once the run completes (§3).
