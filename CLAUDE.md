# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

OpenType is a local-first, cross-platform AI voice-input tool: it turns spontaneous speech into ready-to-use text. It has three independent platform clients (macOS, iOS, Android) that were originally meant to conform to one shared behavioral contract — same modes, same prompt/safety rules, same provider semantics, same audit protocol — but each platform uses whatever native input mechanism actually works on that OS.

- macOS (`Sources/OpenType` for the Swift shell, `sidecar/` for the TypeScript/Bun process it spawns) is the reference implementation — most complete, and the one that went through a from-scratch rewrite most recently. See "Architecture (macOS reference implementation)" below for its current shape.
- iOS (`Platforms/iOS`, Xcode project) — host app records/processes; a separate custom keyboard extension inserts the most recent result via `textDocumentProxy.insertText`. Apple forbids keyboard extensions from accessing the microphone, so recording can never happen in the keyboard itself.
- Android (`Platforms/Android`, Gradle/Kotlin) — a real `InputMethodService` records via `SpeechRecognizer` and writes with `InputConnection.commitText` directly, no separate host-app round trip needed.

The machine-readable cross-platform contract lives in `Shared/OpenTypeContract.json` (modes, providers, invariants, personalization precedence, pipeline stages) with request/response/audit-event JSON Schemas in `Shared/Schemas/`, and cross-platform acceptance vectors in `Shared/AcceptanceCases.json`. `docs/MULTIPLATFORM_ARCHITECTURE.md` explains the shared product core and per-platform boundaries in prose.

**This contract is currently stale relative to macOS.** The macOS client went through a from-scratch rewrite (old 6-mode system deleted, then cut down to exactly 3 modes, plus a sidecar-owned memory/LLM/agent layer — see "Architecture" below) that `Shared/OpenTypeContract.json` and iOS/Android were **not** updated to match: the contract file still describes the old 5-mode set (`smartEdit`/`english`/`agent`/`xReply`/`transcribe`) and per-platform cloud-provider selection, neither of which reflects what macOS actually does anymore. Treat the contract/iOS/Android as historical/aspirational until someone does the (explicitly out-of-scope-for-now) work of reconciling them with the macOS rewrite — don't assume they're in sync, and don't update macOS behavior by reading the contract as ground truth. When changing product behavior going forward, update the contract/schemas/docs together with whichever platform's code changed if you're touching more than macOS; if you're only touching macOS, it's fine (for now) to leave the contract as-is and note the growing gap rather than block on reconciling all three platforms.

## Development workflow

This repo is mid-rewrite. The new product design (comprehensive local memory/context management, a unified voice-triggered Agent entry point with a product-owned Agent runtime, context-aware speech-to-text correction — see `docs/references/` and `docs/superpowers/specs/`) differs enough from the current MVP that the existing code should be treated as prior art to consult, not as a constraint on the new design.

All feature implementation follows a strict TDD red/green cycle, run as an explicit 4-stage pipeline across separate agents rather than one agent doing everything end to end:

1. **Write tests** — one agent writes the test(s) for the behavior, nothing else.
2. **Review tests** — a separate agent reviews the tests for correctness and confirms they currently fail (red) for the right reason.
3. **Implement** — a separate agent writes the implementation to make the reviewed tests pass, without weakening or rewriting them.
4. **Review implementation** — a separate agent reviews the implementation. If it passes, commit immediately — auto-commit is pre-authorized specifically for this 4-stage pipeline once all stages pass; no need to check back in per change.

Dispatch each stage manually (one Agent tool call per stage) rather than via a saved Workflow script for now — revisit automating the whole pipeline once its shape feels stable.

Treat this project's own documentation (`docs/`) as equally important as the code it describes: update the relevant spec/reference doc as part of finishing a piece of work, not as a follow-up. `docs/references/` is the entry point for OpenTypeless/OpenClaw research (read it before re-exploring either repo from scratch); `docs/superpowers/specs/` holds the dated design specs this rewrite produces.

## Commands

### macOS (SwiftPM)

```bash
swift build                                   # debug build
swift test                                    # run all tests
swift test --filter <TestClassOrMethodName>   # run a single test
./scripts/build-app.sh                        # release build -> dist/OpenType.app, ad-hoc codesigned
open dist/OpenType.app
```

`scripts/build-app.sh` builds release, compiles the `sidecar/` TypeScript/Bun server into a standalone `opentype-sidecar` binary (requires `bun` on PATH), assembles the `.app` bundle (binary, Info.plist, Sounds, en.lproj, the bundled sidecar binary, the bundled MLX-Whisper Python venv + script), strips quarantine, and codesigns the sidecar binary standalone *before* folding it into the app (a `bun build --compile` binary's non-standard Mach-O format breaks under `codesign --deep` on the outer app — sign inner-then-outer, outer without `--deep`), then codesigns the outer `.app` with a stable designated requirement (`identifier "ai.rain.opentype"`) so TCC permissions (mic/Accessibility) survive rebuilds.

### macOS sidecar (TypeScript/Bun, `sidecar/`)

```bash
cd sidecar
bun install
bun test                  # run all sidecar tests
bun run src/server.ts     # run standalone (dev mode), listens on a Unix socket
bun run build              # -> dist/opentype-sidecar, the standalone binary build-app.sh bundles
```

See `sidecar/README.md` for env vars (`DEEPSEEK_API_KEY` etc.), endpoint list, and directory layout. The Swift app spawns this as a child process (`Sources/OpenType/SidecarClient.swift`) rather than talking to any of the old cloud speech/text providers directly.

### iOS (Xcode project, no CocoaPods/SPM deps)

```bash
open Platforms/iOS/OpenTypeiOS.xcodeproj

# unsigned build verification (no device needed)
xcodebuild -project Platforms/iOS/OpenTypeiOS.xcodeproj -scheme OpenTypeiOS \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/OpenTypeiOSDerivedData CODE_SIGNING_ALLOWED=NO build

# compile the test target
xcodebuild -project Platforms/iOS/OpenTypeiOS.xcodeproj -scheme OpenTypeiOS \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/OpenTypeiOSTestDerivedData CODE_SIGNING_ALLOWED=NO build-for-testing
```

Two targets (`OpenTypeiOS` host app, `OpenTypeKeyboard` extension) must share one Development Team and the App Group `group.ai.opentype.shared` in Signing & Capabilities. If that App Group id isn't available on your account, mint your own and replace it consistently in both `.entitlements` files, `OpenTypeiOS/SharedResultStore.swift`, and `OpenTypeKeyboard/KeyboardViewController.swift`. Full XCTest execution needs a real device/runtime — the build-for-testing step above only proves it compiles and links.

### Android (Gradle/Kotlin + Jetpack Compose)

```bash
cd Platforms/Android
zsh ./gradlew :app:testDebugUnitTest :app:assembleDebug   # unit tests + debug APK
# or, if Gradle 8.9 is already installed:
gradle :app:testDebugUnitTest :app:assembleDebug
```

Needs JDK 17, Android SDK Platform 35, Build Tools. Debug APK lands at `Platforms/Android/app/build/outputs/apk/debug/app-debug.apk`. Requires Android Studio for interactive dev; command line is enough for CI-style verification.

## Architecture (macOS reference implementation)

macOS is a **Swift shell + TypeScript sidecar** split, not a pure Swift app. `Sources/OpenType/AppModel.swift` is still the central `@MainActor` orchestrator (`ObservableObject`) every view binds to, but it no longer talks to any cloud speech/text provider directly — the Swift side owns recording, hotkeys, Accessibility, delivery, and local history/memory bookkeeping, and hands every actual ASR/text-generation call off to a local `sidecar/` (TypeScript/Bun) child process it spawns and manages over a Unix socket. See `sidecar/README.md` for the sidecar's own layout and standalone run/test instructions, and `docs/superpowers/specs/2026-08-09-current-system-state.md` for the full as-built reference (endpoints, request/response shapes, known gaps).

**The pipeline**: capture context → record → local ASR (sidecar `/asr/transcribe`, MLX-Whisper) → route by mode → (for `ask`/`agent`) sidecar text generation (DeepSeek) → deliver result (clipboard always; auto-insert into the focused field when enabled).

**The 3 modes** (`InputMode` in `Models.swift`) — down from an original 6-mode set, cut in two rounds tonight (6→5, then 5→3):

- `transcribe` — pure ASR passthrough, no sidecar/LLM call at all: whatever MLX-Whisper hears is the result.
- `ask` — no selection needed; speaks a question, sidecar's `/oneshot/ask` (DeepSeek) answers it directly in a floating popup (`AskPanelController`). The one mode that answers rather than preserves/transforms the input.
- `agent` — speaks a task; dispatched non-blockingly to the sidecar's `/agent/run`, which runs a tool-calling loop (MCP) and returns a result plus a step log. Draft-only like every mode (copied to clipboard, never auto-sent/auto-executed) — this is a policy backstop for agentic side effects specifically, since a tool call is an external action the instant it runs.

Every mode's result is copied to the clipboard; auto-insert into the focused field is an additional delivery step, gated on the `automaticallyInsert` setting, never a replacement for the clipboard copy. There is no PromptBuilder/EnglishOutputPolicy/LightTranscriptionPolicy layer anymore — those belonged to the old 5/6-mode Swift-native pipeline and were deleted along with it; mode-specific system prompts now live in the sidecar (`sidecar/src/oneshot/prompts.ts`, `sidecar/src/agent/loop.ts`), not in Swift, and are not user-editable (no Prompt Studio in the current design).

Key Swift-side collaborators `AppModel` wires together:

- `AudioRecorder` / `LiveSpeechTranscriber` — recording and on-device live-caption preview only (Apple's on-device recognizer, gated on the `liveCaptionsEnabled` setting); final recognition always goes through the sidecar's local MLX-Whisper, never this preview transcript.
- `GlobalHotKey` — configurable hotkey (hold left Option / double-tap Ctrl·Option·Shift / etc.) that starts/stops a recording session; each recording locks in the active mode for that session.
- `ContextBridge` — Accessibility-based read of the current app's selection and write-back into the focused text field; clipboard is always the fallback delivery path.
- `SidecarClient` — spawns and health-checks the `sidecar/` child process, then issues every request to it (`curl` over the Unix socket, not a native HTTP transport — a known simplification, see the current-state spec's gaps list). Also resolves `sidecar.env` (bundled by `build-app.sh` into the packaged app's Resources) so the DeepSeek API key reaches the sidecar at runtime even from a `bun build --compile` binary that can't find `sidecar/.env.local` on its own.
- `ImmutableAuditStore` — append-only local audit trail (`audit-events.v1.jsonl`) of `recognized`/`completed`/`cancelled`/`failed` events per request; not affected by history reset or preference relearning. Raw audio itself is ephemeral and deleted after recognition. `provider`/`model` fields now record fixed labels (`"mlx-whisper"`, `"deepseek"`/`deepseek-v4-flash`) rather than a user-configured provider, since there's no provider selection left to record.
- `HistoryStore` / `AgentMemoryStore` / `MemoryInsightsAnalyzer` / `LocalMemoryRetriever` / `OwnerProfileAutoUpdater` — local SQLite-backed history and long-term memory: manually-confirmed "About Me" profile (never auto-rewritten) plus periodically-consolidated "Learned Preferences" (every 100 tasks), injected into Agent-mode context with a budget cap (~12 recent tasks); other text modes only pull in what's relevant to the current task. This sits alongside (not instead of) the sidecar's own separate entity-dictionary memory (`sidecar/src/memory/`), read-only-visible in Settings via `/memory/terms` and `/memory/consolidation-runs`.
- `Views.swift` / `MenuBarPopoverView.swift` — the UI, split Alfred-style: the menubar `NSPopover` (`MenuBarPopoverView`) is a compact mode-switcher only (pick transcribe/ask/agent, glance at status); Settings, History, the Memory panel, and the Agent Task List all live in a separate real, resizable app window (`RootView` in `Views.swift`, opened via the popover's gear button), not in the popover. There is no cloud-provider setup UI anymore — Settings' "转写" section only exposes the live-caption preview's locale (`TranscriptionLanguage`), since ASR/text-generation have no user-facing provider choice left to configure.

There's no `ProviderVault`/`AIServiceClient`/`AIProvider`/`CredentialProvider` layer anymore (removed as dead code once the sidecar took over ASR and text generation) — if you're looking for where a provider/model gets chosen, it isn't chosen on the Swift side at all; check `sidecar/src/env.ts` (`DEEPSEEK_API_KEY`/`DEEPSEEK_MODEL`) and `sidecar/whisper/serve.py` (`OPENTYPE_WHISPER_MODEL`) instead.

iOS and Android were **not** part of tonight's rewrite and still reflect the old 5/6-mode, per-platform-cloud-provider design described by `Shared/OpenTypeContract.json` — see the staleness note under "What this repo is" above. Don't use this section as a guide to iOS/Android's current behavior.

## Reference implementations and design docs

`docs/references/` indexes two sibling projects the current redesign work treats as standing references — OpenTypeless for speech-to-text, OpenClaw for context/memory management — summarizing what's there and pointing at their source paths so they don't need to be re-read from scratch each time. `docs/superpowers/specs/` holds dated design specs produced through the brainstorming process for larger feature work; check both before starting a new design discussion in either area.
