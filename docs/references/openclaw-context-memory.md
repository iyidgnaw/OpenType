# OpenClaw memory/context architecture — research notes for OpenType

Research pass for the OpenType memory/context subsystem redesign, done by reading
OpenClaw's in-repo docs (reportedly the source of truth for docs.openclaw.ai) and
spot-checking a few claims against `src/` and `extensions/memory-core/src/`.
Not a full code audit — see the OpenType CLAUDE.md instruction to keep this kind
of research doc-first.

## Where to look (index for next time)

Docs (all under `/Users/diywang/hackathon/openclaw/docs/`):

- `concepts/memory.md` — top-level overview: the four memory files, memory
  tools, backends, CLI.
- `concepts/memory-architecture.md` — the real architecture doc: tier model,
  provenance, write path, security model. Read this one first if re-reading
  only one file.
- `concepts/dreaming.md` — the consolidation ("dreaming") mechanism in detail:
  phases, scoring signals, thresholds, scheduling, CLI/slash commands.
- `concepts/active-memory.md` — retrieval-time escalation lane (blocking
  recall sub-agent) and its config surface.
- `concepts/user-model.md` — `USER.md` directive format (the confirmed/stable
  preference layer).
- `concepts/memory-search.md` — hybrid vector+BM25 search, embedding providers.
- `plugins/memory-wiki.md` — the closest thing to an entity/relationship graph
  (see below).
- `reference/memory-config.md`, `cli/memory.md` — full config/CLI reference.

Source (all under `/Users/diywang/hackathon/openclaw/`):

- `extensions/memory-core/src/short-term-promotion-utils.ts` — deterministic
  scoring weights (`DEFAULT_PROMOTION_WEIGHTS`).
- `extensions/memory-core/src/dreaming-consolidation-candidates.ts`,
  `session-backfill.ts` — provenance/origin-class gating (`owner`/`agent`
  pass, `untrusted`/`system` excluded).
- `extensions/memory-core/src/memory/` — the SQLite-backed engine, hybrid
  search, project ranking.
- `src/memory-host-sdk/dreaming.ts` — dreaming config types/defaults shared
  with the plugin SDK (phase names, cron, thresholds).
- `src/memory-host-sdk/` more broadly — the host-side memory SDK contracts
  other memory plugins (QMD, Honcho, LanceDB) implement against.

I did not find a working `docs.openclaw.ai` fetch in this pass (not attempted
beyond noting the in-repo docs are the generation source per `docs/docs_map.md`
and `docs/docs.json`); the in-repo files above are authoritative.

## Synthesis: what's stored, how it's captured, consolidated, retrieved

OpenClaw's memory is **plain Markdown files plus one SQLite index**, not a
database-first design — "no hidden state" is stated as a deliberate principle.
Four workspace files matter: `AGENTS.md`/instructions (human-written only,
always injected), `USER.md` (stable preferences/relationships/active projects,
written as imperative directives, always injected, small budget), `MEMORY.md`
(curated durable facts/decisions, always injected, small budget), and
`memory/YYYY-MM-DD.md` daily notes (large, append-heavy episodic log, searched
on demand but never auto-injected). A fifth file, `DREAMS.md`, is a
human-readable review log, not a memory source.

Capture happens continuously and cheaply: the agent appends observations to
today's daily note during normal work; a "memory flush" silent turn runs right
before context compaction to force anything important into a file before it's
summarized away; and session transcripts are ingested as evidence at session
end. None of this writes to the curated tier directly — it all lands in the
episodic tier first, tagged with **provenance** (origin class `owner` / `agent`
/ `untrusted` / `system`, session kind, observed timestamp, supersession key).
That provenance is stored as SQLite columns the model cannot forge through
prose, and it's the actual security boundary: untrusted/system content is
excluded from promotion *structurally*, before scoring, not filtered after the
fact.

Consolidation ("dreaming," see below) is the only path into `MEMORY.md`/
`USER.md`. Retrieval at use-time has two lanes: a zero-latency deterministic
lane (bootstrap injection of `MEMORY.md`/`USER.md`, hybrid vector+BM25
`memory_search` ranked by relevance × recency-decay × importance, and trigger-
phrase prefiltering that auto-injects at most 3 curated-tier entries per turn),
and an escalation lane — a blocking sub-agent ("Active Memory") that only
fires when a message shows explicit recall intent and lane 1 found nothing
strong. This mirrors the design principle that flat retrieval is weak on
temporal/multi-hop recall, so the expensive path is reserved for where it
actually helps.

There is no first-class "entity graph" or "org chart" data model. The closest
analog is the optional `memory-wiki` plugin, which compiles curated memory
into deterministic wiki pages under `entities/` — person/team/system/project
pages with `entityType`, a `canonicalId` for alias resolution, relations to
other entity pages, and structured `claims` (each with confidence, status,
and evidence citations back to source memory). It's explicitly a layer
*beside* the active memory plugin, not a replacement — memory-core still owns
recall/promotion/dreaming; memory-wiki adds provenance-rich synthesis on top.
There's also no dedicated "vocabulary correction" concept (e.g., a homophone
list); that's a genuine gap relative to what OpenType needs (see below).

## The "dreaming" consolidation mechanism

The feature the user was recalling really is called **dreaming** in OpenClaw
— confirmed both in docs (`concepts/dreaming.md`) and in code
(`src/memory-host-sdk/dreaming.ts`, `extensions/memory-core/src/dreaming-*`).
It's enabled by default, and is explicitly framed as implementing "sleep-time
compute" (cites arXiv:2504.13171) plus the Generative Agents reflection
pattern (arXiv:2304.03442).

- **Trigger:** a scheduled cron sweep, default `0 3 * * *` (once nightly),
  configurable via `plugins.entries.memory-core.config.dreaming.frequency`.
  There's also a manual CLI path (`openclaw memory promote`, `memory
  rem-harness`, `memory rem-backfill`) for preview/backfill without waiting
  for the schedule.
- **What it reads:** short-term recall signals from `memory/.dreams/`
  (recall-store, phase signals), recent daily notes, and redacted interactive-
  session transcripts. Cron/heartbeat/sub-agent sessions are excluded from
  candidacy entirely (session-kind gating) — only interactive sessions
  contribute durable candidates.
- **Mechanism — three phases per sweep:**
  1. **Light** — dedupes and stages recent signals, records reinforcement.
     No durable write.
  2. **REM** — builds theme/reflection summaries across recent traces,
     records reinforcement. No durable write.
  3. **Deep** — scores staged candidates with six weighted signals
     (relevance 0.30, frequency 0.24, query-diversity 0.15, recency 0.15,
     multi-day consolidation 0.10, conceptual richness 0.06 — verified
     against `DEFAULT_PROMOTION_WEIGHTS` in
     `extensions/memory-core/src/short-term-promotion-utils.ts`), gates on
     minimum score/recall-count/query-diversity thresholds, strips any
     `untrusted`/`system`-origin candidate before a prompt is ever built,
     then sends the survivors plus the current `MEMORY.md` to a bounded
     consolidation model turn.
- **What it produces:** a rewritten `MEMORY.md` (and/or `USER.md`) that
  merges duplicates, supersedes stale entries via supersession keys, and
  keeps a `Source: path#Lx-Ly` citation per promoted fact. The rewrite is
  validated (must preserve ≥75% of prior entries by default, must fit the
  bootstrap token budget, must parse structurally) before being accepted; a
  failed validation falls back to simple append-only promotion for that
  sweep. Each promoted line also gets machine-readable metadata comments for
  future recall (`<!-- trigger: ... -->`, `<!-- importance: N -->`).
- **Where results land:** `MEMORY.md`/`USER.md` (the only durable write
  targets), a pre-image of the replaced file kept in SQLite for rollback,
  and a narrative summary + diff-style highlights appended to `DREAMS.md`
  for human review (surfaced in a Control-UI "Dreams" tab). A separate
  "grounded backfill" lane can replay historical daily notes into `DREAMS.md`
  and stage candidates without ever touching `MEMORY.md` directly — useful
  for retroactively priming the system or auditing what it would have kept.

Net effect: dreaming is the single writer into the curated/injected tier, it
runs off the interactive/hot path (no user-facing latency), and every
promotion is explainable after the fact.

## Trust model: confirmed vs. auto-consolidated

OpenClaw's split maps closely to OpenType's existing "About Me" (manual,
never auto-rewritten) vs. "Learned Preferences" (auto-consolidated every 100
tasks) pattern, though it's organized slightly differently:

- **`USER.md`** is the nearest analog to OpenType's "About Me": stable
  preferences/relationships/active-project directives. It's *not* purely
  manual, though — dreaming can also write here, but only through the same
  gated consolidation pass as `MEMORY.md` (or via direct user request/edit).
  There's no separate "confirmed-only, agent can never touch it" tier the way
  OpenType's About Me is described — the boundary OpenClaw actually enforces
  is provenance-based (`owner`-typed content vs. `agent`-derived content vs.
  `untrusted`), not "user-edited file vs. auto-edited file."
- **`MEMORY.md`** is the analog to "Learned Preferences" — durable, but only
  ever written by the dreaming consolidation pass (or manual `memory
  promote --apply`), gated on recall-frequency/diversity thresholds rather
  than a fixed task-count cadence.
- The deeper trust primitive is **origin class**, tracked per memory row:
  `owner` (typed by the human in a trusted channel), `agent` (the agent's own
  derivation from owner content), `untrusted` (from external/non-owner
  content), `system` (scaffolding). Only `owner`/`agent`-origin candidates are
  eligible for promotion or auto-injection; `untrusted`/`system` content can
  be stored and explicitly searched but never silently surfaces or graduates.
  This is a finer-grained and more adversarial-content-aware model than a
  simple confirmed/inferred split — it's designed against prompt-injection-
  via-memory (cites OWASP ASI06, MINJA arXiv:2503.03704), which is a
  consideration OpenType hasn't needed yet but might, once memory can absorb
  content from arbitrary dictated text or app context.

## What OpenType could borrow

**(a) Context-aware speech-to-text correction (homophone/mishear
disambiguation).** OpenClaw doesn't have a dedicated entity/vocabulary
correction feature to copy directly, but two pieces are directly reusable
patterns:
- The `memory-wiki` **entity page** shape (`entityType`, `canonicalId`,
  aliases, relations, provenance-linked claims) is a good starting schema
  for OpenType's planned entity/org graph — a `people`/`projects`/`terms`
  vault keyed by canonical ID with known aliases is exactly what a homophone
  corrector needs (e.g., resolve "Kubernetes" vs. "Kubernetees" by matching
  against a canonical entity + alias list, then re-rank ASR n-best output).
- The **trigger-phrase + importance metadata pattern** (`<!-- trigger: ...
  --> <!-- importance: N -->` as trailing comments, matched via a fast
  lexical/vector prefilter before each turn, capped at 3 injected entries)
  is a cheap, zero-extra-model-call way to surface "this vocabulary term is
  relevant right now" context into a correction pass without adding
  latency — worth mirroring for OpenType's real-time dictation path, where
  latency budget is tight.

**(b) A future in-house Agent runtime.** The tier model (instructions →
curated core → episodic → prospective → review) and the "writing is the hard
part, not indexing" principle are the most portable ideas: cheap continuous
capture into an episodic log, a single gated background consolidation writer
into a small always-injected curated file, and a two-lane retrieval split
(cheap deterministic default, expensive escalation only on demonstrated
recall intent) would translate directly to OpenType's Agent mode, which
today has an ad hoc "~12 recent tasks" budget cap and a 100-task
consolidation cadence (`OwnerProfileAutoUpdater`/`MemoryInsightsAnalyzer`).
OpenClaw's provenance/origin-class gating is also worth adopting once Agent
mode starts ingesting anything besides the user's own dictation (e.g., app
context, web content, other people's messages) — that's exactly the
injection surface the origin-class model defends against.

## Gaps / things that seemed undocumented or stale

- No entity/vocabulary correction feature exists in OpenClaw akin to what
  OpenType needs for ASR disambiguation; `memory-wiki` entity pages are
  adjacent but built for durable knowledge synthesis, not real-time
  transcription correction.
- Docs claim the write path only crosses into `MEMORY.md`/`USER.md` through
  dreaming (or direct request); this held up against
  `dreaming-consolidation-candidates.ts` and `short-term-promotion-utils.ts`
  in code — no discrepancy found there.
- The docs note an explicit **known limitation**, not a doc/code mismatch:
  "the current runtime does not propagate content origin within an owner
  turn" — assistant text derived from tool/web output inherits the turn's
  sender class rather than carrying its own provenance. The docs call this
  out themselves as a followup, so it's not something I'm flagging as stale,
  just worth knowing if OpenType adopts the provenance model and cares about
  that specific edge case (agent quoting untrusted web content inside an
  otherwise-owner turn).
- I did not verify the `active-memory` cold-start/timeout behavior or the
  `memory-wiki` bridge-mode internals against code — those sections are
  detailed enough in docs and far enough from OpenType's stated needs
  (ASR correction, future agent runtime) that a code check didn't seem
  warranted for this pass.
