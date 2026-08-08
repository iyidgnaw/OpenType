# OpenType redesign: system boundaries + memory system v1 (entity dictionary slice)

Status: approved design, not yet implemented. macOS only. This is the first
spec in a larger rewrite — see "Deferred to later specs" for what's
intentionally out of scope here.

## 1. Context

OpenType is being substantially redesigned. The current MVP (documented in
the root `CLAUDE.md`) is a 5-mode voice dictation app; the new design
collapses that into a different shape built around three product ideas the
owner described:

1. **Faithful, context-aware transcription** — speech-to-text that uses
   stored personal/entity context to correct ASR mishears (e.g. a mangled
   pinyin utterance recognized as a colleague's name because that name is
   already known), while remaining strictly a transcription — never a
   generative rewrite, never an answer to a question that was only dictated.
2. **A single voice-triggered Agent entry point** that subsumes today's
   separate `agent`/`xReply` modes and adds "deep polish" (in-place rewrite,
   e.g. "make this sound like a formal email") — but internally splits into
   two different execution shapes, see §3.
3. **A comprehensive local memory/context system** about the user and their
   work — entities, ongoing projects, relationships, and semantic history —
   feeding both (1) and (2), explicitly modeled after OpenClaw's memory
   architecture (see `docs/references/openclaw-context-memory.md`).

Platform scope: **macOS only for now** (the existing SwiftPM/SwiftUI app).
Windows/Linux and the existing iOS/Android clients are out of scope for this
redesign track and stay on roadmap.

This is a from-scratch redesign, not an incremental change: existing
macOS code (`AgentMemoryStore`, `OwnerProfileAutoUpdater`,
`MemoryInsightsAnalyzer`, `LocalMemoryRetriever`, `HistoryStore`,
`ImmutableAuditStore`) is prior art to consult, not a constraint. It is
expected to be replaced, not extended.

Reference material used while designing this: `docs/references/opentypeless-stt.md`
(no ASR-level or automatic context-aware correction exists there — this is
genuinely new ground) and `docs/references/openclaw-context-memory.md` (the
"dreaming" consolidation pattern this design adapts).

Development process for implementing this spec follows the repo-wide
convention in `CLAUDE.md`: strict TDD, four separate agent stages (write
tests → review tests → implement → review implementation), auto-commit once
all four stages pass.

## 2. Scope of this spec

**Covered:**
- The overall module boundary map for the redesigned pipeline (§3).
- A full detailed design for the memory system's first vertical slice: the
  entity/vocabulary dictionary + episodic event capture + "dreaming"-style
  consolidation (§4).

**Deferred to later specs** (explicitly out of scope here, to keep this spec
focused and avoid designing ahead of what's actually needed next):
- The phonetic/similarity matching algorithm inside module A that actually
  performs correction against the entity dictionary.
- B1 (OneShot transform/ask) detailed design, including the router that
  classifies a voice command as transcribe-only, B1, or B2.
- B2 (Agent Runtime) detailed design: the agent loop itself, MCP/skill
  integration, safety model for tool use.
- Memory system phase 2 and 3: `project_status` and `relationships` tables
  (same consolidation pipeline, new tables — see §4.6).
- Any UI/UX mockups beyond the minimal Settings surface named in §4.5.

## 3. System boundary map

### 3.1 Pipeline shape

```
capture context -> recognize speech (ASR) -> [A: correct transcript]
  -> route (transcribe-only | one-shot | agent task)
  -> [nothing further | B1 one-shot | B2 agent runtime]
  -> validate output -> [C: record episodic event] -> deliver result
```

Routing after A is three-way, not a forced hand-off to B1/B2: a plain
dictation request ships A's corrected transcript directly as the result
(today's `transcribe` mode collapses into this branch — it never needed
B1/B2 to begin with, since "clean up filler/punctuation" is not a
generative step). Only requests that need a rewrite/answer (B1) or an
open-ended task (B2) continue past routing.

Compared to the current contract pipeline (`captureContext -> recognizeSpeech
-> routeMode -> transformText -> validateOutput -> persistResult ->
deliverResult`): correction (A) is inserted between ASR and mode routing and
applies regardless of which downstream path is chosen; "persist locally"
becomes C's episodic-event write, replacing separate `HistoryStore`/
`ImmutableAuditStore` writes with one write path.

### 3.2 Module responsibilities, interfaces, dependencies

**Unchanged platform plumbing:** `AudioRecorder`, `LiveSpeechTranscriber`
(live-caption preview only), `GlobalHotKey`, `ContextBridge` (selection
read/write), `ProviderVault` (BYOK credential storage), and result delivery
(Accessibility insert / clipboard fallback) keep their current
responsibilities and are not part of this redesign.

**A — Context-aware transcript correction**
- Responsibility: given the raw ASR transcript, return a corrected
  transcript that is still 100% faithful to what was said. Never generative,
  never expands or answers — only fixes mishears against known entities.
- Input: raw ASR string.
- Output: corrected string, plus a record of what changed and why (for
  future debugging/undo).
- Depends on: C's entity-lookup read interface only. Does not depend on B1,
  B2, or any notion of "mode."
- Independently testable: fixed (rawText, entity-dictionary fixture) pairs
  in, asserted correctedText out — no audio, no live provider required.

**B1 — OneShot transform/ask**
- Responsibility: everything that is one request in, one model call, one
  text result out — deep polish/rewrite, translation (today's `english`
  mode), X Reply, and general ask-anything questions.
- Input: (corrected) transcript, optional context (selection/clipboard/
  original post), a task-framing hint.
- Output: final text.
- Depends on: the provider layer (BYOK, same `ProviderVault`/`AIServiceClient`
  model as today) and C's context/search read interface. Does not depend on
  A or the audio layer — text in, text out only.
- Independently testable: transcript + mocked provider/memory responses in,
  asserted draft text out.

**B2 — Agent Runtime**
- Responsibility: genuine task dispatch — multi-step, tool/MCP-using,
  potentially long-running. "Give it a task, it goes and does it," as
  opposed to B1's single-shot answer.
- Input: a task description, optional context, memory hints from C.
- Output: an agent run result/trace. Still draft-only — never auto-executes
  an irreversible external action without the existing product invariant
  being satisfied (mirrors `neverAutoSendModes` in `Shared/OpenTypeContract.json`).
- Depends on: the provider layer, C, and (once built) a tool/MCP registry.
  Does not depend on A or the audio layer.
- Independently testable: same shape as B1 but with a mockable tool-call
  loop instead of a single call.

**C — Memory/context system**
- Responsibility: capture every completed task as an episodic event;
  periodically consolidate into a small, fast, queryable curated tier
  (entity dictionary now; project status and relationships in later
  phases); expose read interfaces to A and B1/B2; expose a review/rollback
  surface in Settings.
- Input: episodic events (the only write path), and an app-lifecycle
  "should I consolidate now" trigger.
- Output (read interfaces): to A, a fast/generic entity-term lookup with no
  model call; to B1/B2, a keyword search over episodic events (FTS now,
  embeddings later); to Settings, list/edit/rollback of entity terms and
  the consolidation run log.
- Depends on: the provider layer only, for its own consolidation model
  call. **Does not depend on A or B1/B2** — it has no concept of
  "correction" or "agent task," only "an event happened, here is its text."
  This is the key isolation boundary: C must not import any A/B-specific
  type.
- Independently testable: pure data plus a mockable "call the provider"
  protocol — no audio, UI, or ASR needed. The easiest of the three to TDD.

### 3.3 Why this boundary

A and B1/B2 never call each other directly, and none of them touch storage
except through C's read interfaces. `AppModel` remains the orchestrator that
wires the sequence together, but each module's public surface is small
enough to fake in tests (an `EntityLookup` protocol for A, a
`MemoryContextProviding` protocol for B1/B2, a `ProviderCalling` protocol for
C's consolidator) — so A, B1, B2, and C can each go through the write
tests -> review tests -> implement -> review implementation -> commit
pipeline independently, without waiting on the others to exist.

## 4. Memory system v1: entity dictionary slice

This is the only module given a full implementation-ready design in this
spec. It replaces `AgentMemoryStore`, `OwnerProfileAutoUpdater`,
`MemoryInsightsAnalyzer`, and `LocalMemoryRetriever` entirely.

### 4.1 Components

- **`MemoryStore`** — new SQLite-backed type. Owns the schema in §4.2 and
  exposes: recording an episodic event, reading entity terms (for A and
  B1/B2), and checking/running consolidation.
- **`MemoryConsolidator`** — the "dreaming" logic described in §4.4. Takes a
  `ProviderCalling` dependency (protocol, satisfied by the existing
  provider-call layer) so it can be tested without network access.
- **Settings "Memory" panel** — lists current entity terms (user can edit or
  delete any entry) and a consolidation run log (each run shows its diff
  summary and an "undo" action per run).

### 4.2 Data model (SQLite, all new tables)

**`episodic_events`** — unifies today's `HistoryStore` + `ImmutableAuditStore`
raw material into one write path:

| column | type | notes |
| --- | --- | --- |
| id | integer PK | |
| createdAt | timestamp | |
| mode | text | plain string label passed in by the caller — C does not import `AppModel`'s mode type |
| rawTranscript | text | pre-correction ASR output, kept for audit |
| correctedTranscript | text | what A actually produced and downstream acted on |
| effectiveInput | text | nullable | after any command-prefix parsing |
| selectedContext | text | nullable |
| result | text | nullable | final output, if any |
| applicationName | text | |
| origin | text | enum: `owner` \| `agent` \| `untrusted` \| `system`. Everything today is `owner`; the column exists now so B2's future external-content ingestion doesn't need a schema migration. |
| consolidatedAt | timestamp | nullable | null = not yet processed by a consolidation run |

The user-facing History view becomes a read-only query over this table
(ordered by `createdAt desc`). The existing "clear history" setting and any
future "disable memory" setting are the same underlying toggle — there is
one on/off switch, not two, since it's the same data.

**`entity_terms`** — the curated tier A and B1/B2 read from:

| column | type | notes |
| --- | --- | --- |
| id | integer PK | |
| canonicalTerm | text | |
| aliases | json array of text | includes observed mis-transcriptions |
| category | text | enum: `person` \| `project` \| `term` \| `org` |
| confidence | real | 0.0-1.0, from consolidation scoring |
| origin | text | same enum as above |
| sourceEventIds | json array of integer | citations back to `episodic_events`, for "why does the system think this" transparency |
| createdAt / updatedAt | timestamp | |
| supersedes | integer | nullable, FK to another `entity_terms.id`, set when consolidation merges two entries |

**`memory_consolidation_runs`** — the review/rollback log (OpenClaw's
`DREAMS.md` analog):

| column | type | notes |
| --- | --- | --- |
| id | integer PK | |
| ranAt | timestamp | |
| eventsConsidered | integer | count |
| candidatesProposed / candidatesAccepted | integer | counts |
| summary | text | human-readable diff, e.g. "+ added 天润 (aliases: tianrun, 添润) from 3 mentions" |
| snapshotBeforeJSON | text | full `entity_terms` table dump before this run, for rollback |
| rolledBackAt | timestamp | nullable |

An FTS5 virtual table over `episodic_events(rawTranscript,
correctedTranscript, result)` is created for B1/B2's future keyword search.
It is not used by A (see §4.3).

### 4.3 Capture flow

After `AppModel` produces the final `result` for a completed task (the
existing point in the pipeline where `HistoryStore.append`/`auditStore.append`
are called today), it calls a single
`memoryStore.recordEpisodicEvent(mode:rawTranscript:correctedTranscript:
effectiveInput:selectedContext:result:applicationName:origin:)`. This is the
only write path into `episodic_events`. If the user has history/memory
disabled, this call is skipped entirely — no event is recorded.

### 4.4 Consolidation ("dreaming") mechanism

OpenClaw's three-phase, six-weighted-signal scoring model is tuned for a
high-volume chat agent processing many turns per day. OpenType's volume is
far lower (dictation tasks, likely tens per day at most), so this design
simplifies to a single-phase, deterministically-gated pass:

- **Trigger**: checked at app launch and app quit. Runs (in the background,
  non-blocking) if both hold: at least 12 hours since the last run, and at
  least 5 unconsolidated events exist. No persistent daemon or cron — this
  is a menu-bar app, not a long-running service.
- **Candidate extraction**: the unconsolidated events (capped at the 200
  most recent, to bound prompt size) plus the current `entity_terms` table
  are sent to the user's configured text provider with a dedicated
  consolidation prompt, asking for structured output: candidate canonical
  term, aliases (including any mis-transcription variants visible in
  `rawTranscript`), category, a 0.0-1.0 confidence, and which event ids
  support the candidate.
- **Gating** (deterministic code, not trusted to the model): a candidate is
  accepted only if confidence >= 0.6 with support from >= 2 distinct
  events, OR confidence >= 0.9 from even a single event (e.g. the user
  manually corrected a name once in a way the model is highly sure about).
  A candidate that collides with an existing high-confidence entry can only
  be accepted as an alias-merge, never as a silent overwrite.
- **Write**: the current `entity_terms` table is snapshotted into
  `snapshotBeforeJSON` before any change; accepted candidates are applied
  (insert new terms, or merge aliases/update confidence on existing terms
  matched by canonical term or alias); processed events get
  `consolidatedAt` set; a `memory_consolidation_runs` row is written with
  the diff summary.
- **Rollback**: each run in the Settings "整理记录" list has an "撤销" (undo)
  action that restores `entity_terms` from `snapshotBeforeJSON`, sets
  `rolledBackAt`, and clears `consolidatedAt` on the associated events so
  they're reconsidered on the next run.
- **Failure handling**: if the provider call fails or returns output that
  doesn't parse against the expected structure, the run is skipped
  silently (logged, not surfaced as an error to the user) — no events are
  marked consolidated and `entity_terms` is left untouched, so the next
  scheduled attempt retries the same material.

### 4.5 Read interfaces

`entity_terms` is expected to stay small (tens to a few hundred rows for a
single user), so `MemoryStore` exposes a generic, cheap read — either
`allTerms() -> [EntityTerm]` or a plain substring/alias `search(text:) ->
[EntityTerm]`. **C does not perform phonetic or similarity matching** — that
logic belongs to module A (see §2, deferred), which owns the concept of
"correction." Keeping C's read interface generic also means B1/B2 can use
the exact same call for their own context needs, without C needing to know
anything about what "correction" means.

### 4.6 Future phases (not in this spec)

`project_status` and `relationships` tables are added later, using the same
`episodic_events` capture and the same `MemoryConsolidator` pipeline
(additional extraction prompts, additional gating rules per table) — not a
separate mechanism. This spec's schema and consolidation design should not
need to change shape to accommodate them, only grow additional tables and
additional candidate-extraction prompts.

### 4.7 Testing approach

C is the most straightforwardly testable of the four modules: fixtures of
`episodic_events` rows, a mocked `ProviderCalling` response, and assertions
on the resulting `entity_terms` rows, the gating decisions, and rollback
exactly restoring prior state. No audio, UI, or live network access is
needed for any of it, which fits the repo's TDD-first, four-stage-pipeline
convention (`CLAUDE.md`) well as the first module built under that process.

## 5. Open questions / risks

- The consolidation prompt's structured-output contract (exact JSON shape
  requested from the model) is not yet defined — this is small enough to
  settle during implementation (stage 1 of the TDD pipeline, when tests are
  written) rather than needing its own design discussion.
- Confidence thresholds (0.6 / 2 events, 0.9 / 1 event) are initial
  guesses, not validated against real usage — expect to tune them once the
  slice is running against real dictation history.
