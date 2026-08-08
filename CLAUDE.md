# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

OpenType is a local-first, cross-platform AI voice-input tool: it turns spontaneous speech into ready-to-use text. It has three independent platform clients (macOS, iOS, Android) that must all conform to one shared behavioral contract — same 5 modes, same prompt/safety rules, same provider semantics, same audit protocol — but each platform uses whatever native input mechanism actually works on that OS.

- macOS (`Sources/OpenType`, SwiftPM) is the reference implementation — most complete, and the baseline for prompts/mode behavior/output safety rules.
- iOS (`Platforms/iOS`, Xcode project) — host app records/processes; a separate custom keyboard extension inserts the most recent result via `textDocumentProxy.insertText`. Apple forbids keyboard extensions from accessing the microphone, so recording can never happen in the keyboard itself.
- Android (`Platforms/Android`, Gradle/Kotlin) — a real `InputMethodService` records via `SpeechRecognizer` and writes with `InputConnection.commitText` directly, no separate host-app round trip needed.

The machine-readable cross-platform contract lives in `Shared/OpenTypeContract.json` (modes, providers, invariants, personalization precedence, pipeline stages) with request/response/audit-event JSON Schemas in `Shared/Schemas/`, and cross-platform acceptance vectors in `Shared/AcceptanceCases.json`. `docs/MULTIPLATFORM_ARCHITECTURE.md` explains the shared product core and per-platform boundaries in prose. When changing product behavior (modes, invariants, providers), update the contract/schemas/docs together with whichever platform's code changed, and check whether the other two platforms need the same change to stay in sync.

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

`scripts/build-app.sh` builds release, compiles the `sidecar/` TypeScript/Bun server into a standalone `opentype-sidecar` binary (requires `bun` on PATH), assembles the `.app` bundle (binary, Info.plist, Sounds, en.lproj, the bundled sidecar binary), strips quarantine, and codesigns with a stable designated requirement (`identifier "ai.rain.opentype"`) so TCC permissions (mic/Accessibility) survive rebuilds.

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

`Sources/OpenType/AppModel.swift` is the central `@MainActor` orchestrator (`ObservableObject`) that every view binds to. It owns the shared pipeline all platforms implement: **capture context → recognize speech → route by mode → transform text → validate output → persist locally → deliver result**. Key collaborators it wires together:

- `AudioRecorder` / `LiveSpeechTranscriber` — recording and on-device live-caption preview (preview only; final recognition always goes through the selected speech provider).
- `GlobalHotKey` — configurable hotkey (hold left Option / double-tap Ctrl·Option·Shift / etc.) that starts/stops a recording session; each recording locks in the active mode for that session.
- `ContextBridge` — Accessibility-based read of the current app's selection and write-back into the focused text field; clipboard is always the fallback delivery path.
- `AIServiceClient` + `DashScopeClient` + `AIProvider` — provider-agnostic request/response layer. `AIProvider` enumerates providers (dashScope, volcengine, openAI, anthropic, elevenLabs) and which of speech-recognition/text-generation each supports; DashScope's Chinese→English mode uses a dedicated Qwen-MT translation protocol, never the general chat prompt.
- `PromptBuilder` — assembles the final prompt per mode: fixed safety rules + mode system instruction (mirrored from `Shared/OpenTypeContract.json`) + current app + personal dictionary + dynamic context, following the personalization precedence: explicit instruction > active mode > current app/source > confirmed profile > learned preferences > product defaults.
- `EnglishOutputPolicy` — validates Chinese→English mode output: rejects leftover Han characters, excessive length expansion, and speech-act drift (a question answered instead of translated, a request executed instead of translated). On failure, retries once with a stricter translation-only model before refusing to insert a bad result — mirrors `englishRepairAttemptsMaximum: 1` in the contract.
- `LightTranscriptionPolicy` — the Transcribe mode's fidelity guard: only removes filler/disfluency/basic punctuation, must never treat dictation as a question to answer.
- `ProviderVault` (`CredentialProvider`, Keychain-backed token storage) — per-provider API tokens, AES-GCM encrypted at rest, never echoed back to the UI once saved, never logged.
- `ImmutableAuditStore` — append-only local audit trail (`audit-events.v1.jsonl`) of `recognized`/`completed`/`cancelled`/`failed` events per request; not affected by history reset or preference relearning. Raw audio itself is ephemeral and deleted after recognition.
- `HistoryStore` / `AgentMemoryStore` / `MemoryInsightsAnalyzer` / `LocalMemoryRetriever` / `OwnerProfileAutoUpdater` — local SQLite-backed history and long-term memory: manually-confirmed "About Me" profile (never auto-rewritten) plus periodically-consolidated "Learned Preferences" (every 100 tasks), injected into Agent-mode context with a budget cap (~12 recent tasks); other text modes only pull in what's relevant to the current task.
- `Views.swift` — all SwiftUI UI (menu bar, settings, Prompt Studio, onboarding, history) driving/observing `AppModel`.

The 5 modes (`smartEdit`, `english`, `agent`, `xReply`, `transcribe`) and their invariants — copy every successful result to the clipboard, never auto-publish/auto-send (`agent`, `xReply` are draft-only), selected-text edits require an explicit spoken instruction, Transcribe must never answer dictation as a question — are defined once in `Shared/OpenTypeContract.json` and reimplemented per platform; `PromptBuilder`/`EnglishOutputPolicy`/`LightTranscriptionPolicy` on macOS are the canonical enforcement of those invariants and are the files to check first when a mode's behavior needs to change on any platform.

iOS and Android mirror this pipeline with platform-native equivalents (Apple Speech vs. Android `SpeechRecognizer`; Keychain vs. Android Keystore for token storage; App Group hand-off vs. direct `InputConnection.commitText`) — see their own `Platforms/*/README.md` for platform-specific constraints and current verification status.

## Reference implementations and design docs

`docs/references/` indexes two sibling projects the current redesign work treats as standing references — OpenTypeless for speech-to-text, OpenClaw for context/memory management — summarizing what's there and pointing at their source paths so they don't need to be re-read from scratch each time. `docs/superpowers/specs/` holds dated design specs produced through the brainstorming process for larger feature work; check both before starting a new design discussion in either area.
