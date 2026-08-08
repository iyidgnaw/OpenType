# OpenTypeless STT architecture — reference notes

Study of `/Users/diywang/hackathon/opentypeless` (Tauri/Rust + React desktop
dictation app), done to inform OpenType's context-aware ASR-correction design.
Not exhaustive — see "where to look" below to go deeper on any point.

## Where to look (if you need to go deeper)

- `src-tauri/src/stt/mod.rs` — `SttProvider` trait and `SttConfig`; the full
  set of providers (`create_provider`).
- `src-tauri/src/stt/{deepgram,assemblyai,aliyun_qwen3_asr,volcengine,apple_speech,whisper_compat,cloud}.rs`
  — one file per ASR backend.
- `src-tauri/src/llm/prompt.rs` — the single system prompt builder
  (`build_context_system_prompt`, `append_dictionary_prompt`,
  `append_correction_rules_prompt`). This is where "context-aware correction"
  actually lives.
- `src-tauri/src/pipeline.rs` — orchestrates record → STT → LLM polish →
  output; look around line 1090-1140 and 1859-2600 for where dictionary/
  correction data is loaded and threaded into the LLM request.
- `src-tauri/src/storage/mod.rs` — `DictionaryEntry` / `CorrectionRule`
  SQLite schema (`dictionary_entries`, `correction_rules` tables).
- `src-tauri/src/dictionary_io.rs` + `src/components/Settings/DictionaryPane.tsx`
  / `DictionaryImportDialog.tsx` — manual dictionary/correction-rule CRUD and
  txt/csv/json import-export.
- `src-tauri/src/voice_intent/` — command/intent routing for "Ask Anything"
  and voice-triggered actions (closest analog to OpenType's mode system).
- `src-tauri/src/output/mod.rs` — keyboard-simulation vs. clipboard delivery.
- `README.md` (mermaid architecture diagram, "Dictionary" feature row) and
  `docs/2026-06-27-typeless-competitive-roadmap-spec.md` (§ "M4:
  Personalization And Per-App Tone", § "Competitive Gap Matrix") — the
  clearest statement of what dictionary/personalization work is done vs.
  still roadmap.
- `CHANGELOG.md` — "Local correction rules alongside the custom dictionary."

## STT architecture: capture → providers → delivery

Audio capture is native Rust (`audio/capture.rs`, via `cpal`), triggered by
global shortcuts routed through Tauri commands. `pipeline.rs` is the single
orchestrator: it owns the recording session, loads config, fetches the
dictionary/correction rules, streams audio to whichever `SttProvider` is
configured, then hands the raw transcript to an LLM "polish" step, then
delivers the result via `output/` (keyboard simulation or clipboard paste,
Windows has a dedicated `SendInput` path).

Provider abstraction (`stt/mod.rs`) is a `create_provider(name) -> Box<dyn
SttProvider>` factory, structurally similar to OpenType's `AIProvider` enum +
`AIServiceClient`/`DashScopeClient`, but STT-only (a separate `llm/` module
with its own OpenAI-compatible + "cloud" providers handles the polish/
translate/ask step). Supported ASR backends: Deepgram, AssemblyAI, Aliyun
Qwen3 realtime ASR, Volcengine Doubao realtime ASR, Apple Speech (on-device,
macOS only), a generic "Whisper-compatible" HTTP client (covers OpenAI,
Groq, local faster-whisper servers, etc. via shared config), and a "cloud"
provider that proxies through OpenTypeless's own backend for BYOK-less users.
`SttConfig` — the struct passed to every provider — only carries
`api_key`, `language`, `smart_format`, `sample_rate`, `resource_id`,
`operation_id`, `managed_audio`, `provider_region`. There is no field for
vocabulary, hints, keywords, or biasing of any kind.

## Context-aware correction / personal vocabulary: exists, but only as post-hoc LLM prompt injection — not ASR-level biasing

This is the key finding. OpenTypeless does have a "Dictionary" feature
(`storage::DictionaryEntry` — word + optional pronunciation; and
`storage::CorrectionRule` — enabled pattern → replacement pairs), user-editable
in Settings and import/export-able as txt/csv/json
(`dictionary_io.rs`). But:

- It is **never passed to the ASR provider**. Grepping `src-tauri/src/stt/*.rs`
  for "dictionary", "vocabulary", "hint", "keyword", "boost", "hotword" turns
  up nothing. None of the six STT backends have a vocabulary-biasing or
  hotword-list parameter wired up, even where the underlying vendor APIs
  (e.g. Deepgram) support such a thing.
- Instead, correction happens entirely in the **post-ASR LLM polish prompt**
  (`llm/prompt.rs`). The raw STT transcript is wrapped in `<transcription>`
  tags and sent to an LLM with the dictionary words appended as "IMPORTANT:
  The following are the user's custom terms. Always use these exact
  spellings" and enabled correction rules appended as literal `"pattern" ->
  "replacement"` pairs ("USER CORRECTION RULES: When the transcript likely
  contains the left phrase, output the right phrase"). The LLM is trusted to
  fuzzy-match the ASR's garbled output against these known-good strings and
  substitute them — this is functionally close to what OpenType wants (fixing
  a mangled name/term against known context), but it happens as one
  instruction embedded in a general-purpose "polish" prompt, not as a
  dedicated, narrowly-scoped correction pass.
- Correction rules are **user-authored, exact-string, manually maintained**
  (typed in Settings or imported from a file) — there is no automatic
  extraction of names/jargon from history, no phonetic/pinyin-similarity
  matching, and no retrieval of "recently mentioned entities" at
  transcription time.
- The competitive-roadmap doc confirms this is a known gap, not an oversight:
  `docs/2026-06-27-typeless-competitive-roadmap-spec.md` "M4:
  Personalization" lists "Personal dictionary suggestions" (auto-suggest
  terms from repeated user edits, corrected output, or low-confidence
  transcript segments — with mandatory user acceptance before entering the
  dictionary) and "Style learning" as **unimplemented, P2-priority roadmap
  items**. The Competitive Gap Matrix explicitly marks OpenTypeless as
  "manual dictionary" only, versus a competitor's "manual and automatic"
  claims.

## Faithful transcription vs. generative rewrite: no formal mode split like OpenType's

OpenTypeless has no analog to OpenType's `Shared/OpenTypeContract.json` 5-mode
contract (`smartEdit`/`english`/`agent`/`xReply`/`transcribe`) with per-mode
invariants. Instead it has one always-on "polish" system prompt
(`BASE_PROMPT` in `llm/prompt.rs`) that both cleans up disfluency/filler AND
reformats into punctuated prose/lists — i.e., normal dictation already
gets a fair amount of transformation, not pure verbatim transcription. Fidelity
is protected by prompt rules rather than a separate enforcement/validation
layer: rule 5 says "Preserve ... technical terms, and proper nouns exactly.
Do NOT add any words, phrases, or content that were not present," and a
`THOUGHT_AWARE_RULES` block instructs conservative handling of false
starts/self-corrections ("Preserve uncertain names and described terms as
spoken. Do not search, guess, normalize, or invent a likely name" — notably
the opposite of what OpenType wants to do with known-context correction).
On top of that baseline there's a `SELECTED_TEXT_ADDON` (explicit voice
instruction operates on selected text — analogous to OpenType's smartEdit)
and `voice_intent/` (command/intent grammar for search, draft-insert, ask
actions — the closest thing to `agent`/`xReply`). There's no dedicated
"transcribe-only, must never answer as a question" guard comparable to
OpenType's `LightTranscriptionPolicy`, and no output-validation/retry layer
comparable to `EnglishOutputPolicy` — correctness is prompt-instruction only,
with no post-hoc validator or repair pass.

## What OpenType could borrow, and what's still a gap

Borrow:
- The pattern of surfacing a user-editable dictionary/correction-rule store
  (`DictionaryEntry`, `CorrectionRule`) with plain import/export — a good,
  low-risk starting UI/data model for "known terms and names."
- Injecting known terms into the generation prompt as an explicit "always use
  this exact spelling" list plus explicit `pattern -> replacement` pairs is a
  reasonable minimal building block, and the "use context, don't apply
  blindly if it changes meaning" guard language is worth reusing verbatim.

Still a gap (i.e., OpenType would be building genuinely new ground, not
extending OpenTypeless prior art) — none of this exists in OpenTypeless
today:
- Any ASR-level biasing/hotword mechanism (none of the 6 providers wire a
  vocabulary hint even when the vendor API supports one).
- Automatic extraction of names/jargon from conversation history or a
  memory/entity store (OpenTypeless's own roadmap describes this as an
  unimplemented, un-scheduled P2 idea, requiring explicit user acceptance
  before use — they treat it as risky, not solved).
- Phonetic/pinyin-similarity matching of mangled ASR output against known
  entities (the exact "mangled pinyin → known person's name" or "龙虾 →
  OpenClaw" case) — OpenTypeless's correction is a plain string-pattern
  match handed to an LLM to fuzzy-apply, not a structured phonetic-similarity
  ranking against a personal knowledge base.
- A formal, testable "faithful correction, never generative rewrite"
  contract/validator analogous to OpenType's `EnglishOutputPolicy` /
  `LightTranscriptionPolicy`. OpenTypeless relies on prompt wording alone,
  with no automated check that the LLM didn't invent or expand content.

## Tauri/Rust cross-platform note (secondary)

If OpenType ever needs macOS/Windows/Linux desktop parity instead of
staying Swift/macOS-only, OpenTypeless is a working existence proof of the
shape: Rust backend (`src-tauri/src`) owns audio capture, provider calls,
local SQLite storage, and OS-level output (keyboard simulation/clipboard,
with a separate Windows `SendInput` + "modifier guard" path for
Windows-specific quirks — see `output/windows_sendinput.rs`,
`output/windows_modifier_guard.rs`), while a React/TypeScript frontend
(`src/`) is purely UI/state (Zustand stores) talking to Rust via Tauri
commands and events. Platform-specific concerns (active-app detection,
hotkeys, X11 vs. Windows vs. macOS accessibility APIs) are isolated behind
small per-OS modules (`app_detector/platform/{macos,windows,linux}.rs`,
`linux_x11.rs`, `native_hotkey.rs`), which is the same kind of seam
OpenType's contract-driven multi-platform approach (`Shared/OpenTypeContract.json`
+ per-platform native implementations) already uses conceptually, just with
Rust/web instead of three independent native codebases.
