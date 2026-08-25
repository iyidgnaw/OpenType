import type { Database } from "bun:sqlite";

export type EventOrigin = "owner" | "agent" | "untrusted" | "system";
export type EntityCategory = "person" | "project" | "term" | "org";

/**
 * Modes whose episodic events are recorded locally but must never be handed to
 * a model.
 *
 * `transcribe` is on this list because "plain dictation never reaches an LLM"
 * is a stated product guarantee, not an implementation detail — it is in the
 * README, in `USER_GUIDE.md` §13, and in `CLAUDE.md`'s mode table. Consolidation
 * is a real model call, so routing dictation through it would break that
 * guarantee no matter how much later the call happens: delayed transmission is
 * still transmission, and "only during consolidation" is not a defence to a
 * user who chose this product because their dictation stays on the machine.
 *
 * Recording is deliberately *not* what gets suppressed. The rows stay, because
 * they are local-only material for the stats panel, and because an explicit
 * opt-in ("use my dictation to improve the dictionary — this sends recent
 * transcripts to your configured model") is the honest way to offer this later.
 * That opt-in only has something to work with if the material is still here.
 *
 * The high-signal half of learning from dictation is already covered without
 * any of this: P0-2 turns every voice correction the user actually makes into a
 * dictionary alias locally, with no model involved. What consolidation would
 * add is discovery of terms the user never corrected — real value, but not
 * worth silently voiding a promise to get it.
 */
export const CONSOLIDATION_EXCLUDED_MODES: readonly string[] = ["transcribe"];

/**
 * The SQL half of the rule above, written once so the gate's count and the
 * consolidation pass's own SELECT cannot disagree.
 *
 * The mode list is a hardcoded constant, never user input, so interpolating it
 * carries no injection risk — and inlining it keeps the predicate usable as a
 * plain string by callers that also bind their own parameters, without forcing
 * every one of them to splice a variable-length parameter list in the right
 * order (the kind of detail that gets a filter dropped during a later edit).
 */
const CONSOLIDATION_CANDIDATE_PREDICATE = `consolidatedAt IS NULL AND mode NOT IN (${CONSOLIDATION_EXCLUDED_MODES.map(
  (mode) => `'${mode}'`
).join(", ")})`;

export interface RecordEpisodicEventInput {
  mode: string;
  rawTranscript: string;
  correctedTranscript: string;
  effectiveInput: string | null;
  selectedContext: string | null;
  result: string | null;
  applicationName: string;
  origin?: EventOrigin;
  conversationId?: number | null;
}

/**
 * The full shape of one `episodic_events` row, as read back by
 * `recentEvents`. Mirrors the table exactly -- including `conversationId`
 * (added alongside `recordEpisodicEvent`'s optional input field) and
 * `consolidatedAt`, which callers of `recentEvents` need to be able to see is
 * irrelevant to that method (see its doc comment) rather than take on faith.
 */
export interface EpisodicEventRow {
  id: number;
  createdAt: number;
  mode: string;
  rawTranscript: string;
  correctedTranscript: string;
  effectiveInput: string | null;
  selectedContext: string | null;
  result: string | null;
  applicationName: string;
  origin: EventOrigin;
  conversationId: number | null;
  consolidatedAt: number | null;
}

export interface EntityTerm {
  id: number;
  canonicalTerm: string;
  aliases: string[];
  category: EntityCategory;
  confidence: number;
  origin: EventOrigin;
  sourceEventIds: number[];
  createdAt: number;
  updatedAt: number;
  supersedes: number | null;
}

/**
 * The editable subset of an `EntityTerm`, as a patch: an omitted field is
 * left exactly as it is. Deliberately narrower than `EntityTerm` — `origin`,
 * `category`, `sourceEventIds` and the timestamps describe where a term came
 * from, and letting the dictionary panel rewrite provenance would make the
 * `origin` badge (P1-12) a client-asserted value.
 */
export interface EntityTermPatch {
  canonicalTerm?: string;
  aliases?: string[];
  confidence?: number;
}

/**
 * A free-text fact remembered about the owner (e.g. "The owner's name is
 * Diyi.", "The owner prefers formal English."), distinct from `entity_terms`
 * which is specifically shaped for term/alias correction. Written either
 * directly via the `remember_fact` built-in tool (category "profile") or,
 * in principle, by future consolidation passes.
 */
export interface OwnerFact {
  id: number;
  content: string;
  createdAt: number;
  origin: EventOrigin;
}

export interface ConsolidationRunSummary {
  id: number;
  ranAt: number;
  eventsConsidered: number;
  candidatesProposed: number;
  candidatesAccepted: number;
  summary: string;
  rolledBackAt: number | null;
}

interface EntityTermRow {
  id: number;
  canonicalTerm: string;
  aliases: string;
  category: EntityCategory;
  confidence: number;
  origin: EventOrigin;
  sourceEventIds: string;
  createdAt: number;
  updatedAt: number;
  supersedes: number | null;
}

function rowToEntityTerm(row: EntityTermRow): EntityTerm {
  return {
    id: row.id,
    canonicalTerm: row.canonicalTerm,
    aliases: JSON.parse(row.aliases) as string[],
    category: row.category,
    confidence: row.confidence,
    origin: row.origin,
    sourceEventIds: JSON.parse(row.sourceEventIds) as number[],
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    supersedes: row.supersedes,
  };
}

/**
 * Wraps a bun:sqlite Database handle over the spec §4.2 schema. This is the
 * only write path into episodic_events, and the read interface A/B1/B2 use
 * for entity lookups. It does not know about "modes" beyond the plain string
 * label the caller passes in, and it does not perform phonetic/similarity
 * matching (that belongs to module A) — only exact substring matching.
 */
export class MemoryStore {
  constructor(public readonly db: Database) {}

  recordEpisodicEvent(input: RecordEpisodicEventInput): number {
    const origin: EventOrigin = input.origin ?? "owner";
    const now = Date.now();
    const result = this.db.run(
      `INSERT INTO episodic_events
        (createdAt, mode, rawTranscript, correctedTranscript, effectiveInput, selectedContext, result, applicationName, origin, conversationId)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        now,
        input.mode,
        input.rawTranscript,
        input.correctedTranscript,
        input.effectiveInput,
        input.selectedContext,
        input.result,
        input.applicationName,
        origin,
        input.conversationId ?? null,
      ]
    );
    return Number(result.lastInsertRowid);
  }

  allTerms(): EntityTerm[] {
    const rows = this.db.query("SELECT * FROM entity_terms").all() as EntityTermRow[];
    return rows.map(rowToEntityTerm);
  }

  search(text: string): EntityTerm[] {
    const needle = text.toLowerCase();
    return this.allTerms().filter((term) => {
      if (term.canonicalTerm.toLowerCase().includes(needle)) {
        return true;
      }
      return term.aliases.some((alias) => alias.toLowerCase().includes(needle));
    });
  }

  /**
   * Applies a partial edit to one entity term (the dictionary panel's inline
   * edit, P0-4). Returns the row as it now stands, or `null` when no such id
   * exists — so the route can answer 404 rather than silently succeeding.
   *
   * An out-of-range confidence throws a `RangeError` instead of being clamped:
   * 1.5 is a caller bug, and quietly storing 1.0 for it would hide that bug
   * behind a value the user never chose. `createdAt`, `category`, `origin` and
   * `sourceEventIds` are never touched by an edit.
   */
  updateEntityTerm(id: number, patch: EntityTermPatch): EntityTerm | null {
    if (patch.confidence !== undefined) {
      if (!Number.isFinite(patch.confidence) || patch.confidence < 0 || patch.confidence > 1) {
        throw new RangeError(`confidence must be between 0 and 1, got ${patch.confidence}`);
      }
    }

    const row = this.db
      .query("SELECT * FROM entity_terms WHERE id = ?")
      .get(id) as EntityTermRow | null;
    if (!row) {
      return null;
    }

    const current = rowToEntityTerm(row);
    const next: EntityTerm = {
      ...current,
      canonicalTerm: patch.canonicalTerm ?? current.canonicalTerm,
      aliases: patch.aliases ?? current.aliases,
      confidence: patch.confidence ?? current.confidence,
      updatedAt: Date.now(),
    };

    this.db.run(
      "UPDATE entity_terms SET canonicalTerm = ?, aliases = ?, confidence = ?, updatedAt = ? WHERE id = ?",
      [next.canonicalTerm, JSON.stringify(next.aliases), next.confidence, next.updatedAt, id]
    );

    return next;
  }

  /**
   * Removes a single entity term by id. Returns whether a row was actually
   * removed, so the management endpoint can tell a real delete from a
   * missing id — the same contract as `deleteOwnerFact`.
   */
  deleteEntityTerm(id: number): boolean {
    const result = this.db.run("DELETE FROM entity_terms WHERE id = ?", [id]);
    return result.changes > 0;
  }

  /**
   * Writes a free-text owner fact directly (no gating) into `owner_facts`.
   * The direct-write counterpart to `entity_terms` merges done via
   * `upsertEntityTerm` -- owner facts are never merged/deduplicated, they're
   * simply appended, since they're arbitrary free text rather than a
   * canonical-name-plus-aliases shape.
   */
  recordOwnerFact(content: string, origin: EventOrigin = "owner"): number {
    const result = this.db.run(
      `INSERT INTO owner_facts (content, createdAt, origin) VALUES (?, ?, ?)`,
      [content, Date.now(), origin]
    );
    return Number(result.lastInsertRowid);
  }

  allOwnerFacts(): OwnerFact[] {
    return this.db.query("SELECT * FROM owner_facts").all() as OwnerFact[];
  }

  /**
   * Owner facts of a single origin. Used by prompt-context injection, which
   * must only surface facts the owner actually authored ("owner") and never
   * ones planted through the agent/context flow ("untrusted"/"agent"/"system")
   * -- see `buildOwnerFactsContext`. The management surface still uses
   * `allOwnerFacts()` so a user can review (and delete) poisoned facts.
   */
  ownerFactsByOrigin(origin: EventOrigin): OwnerFact[] {
    return this.db
      .query("SELECT * FROM owner_facts WHERE origin = ?")
      .all(origin) as OwnerFact[];
  }

  /**
   * Removes a single owner fact by id (the delete counterpart to
   * `recordOwnerFact`). Returns whether a row was actually removed, so the
   * management endpoint can distinguish a real delete from a missing id.
   */
  deleteOwnerFact(id: number): boolean {
    const result = this.db.run("DELETE FROM owner_facts WHERE id = ?", [id]);
    return result.changes > 0;
  }

  /**
   * The other half of reviewing a fact: the user read it and vouches for it.
   * Sets `origin` to `"owner"` and returns the row as it now stands, or `null`
   * when no such id exists so the route can answer 404.
   *
   * **One-way, by construction.** There is no target-origin parameter, so this
   * method cannot express a demotion no matter what a caller passes — the same
   * shape as `promoteOrigin` in `consolidator.ts`, which resolves every merge
   * as "incoming `owner` wins, an existing `owner` is never downgraded". The
   * reasoning is the same too, and it is the reason this method exists at all:
   * provenance is here so a user can review what an agent planted from
   * untrusted context (P1-12), and a flag the user cannot clear after
   * reviewing is noise. A user who learns the label never goes away learns to
   * ignore it — which costs exactly the signal it was added for.
   *
   * Every non-owner origin is promotable, not just `"untrusted"`: the panel's
   * "needs attention" dot lights for anything that is not `"owner"`, so an
   * `"agent"` or `"system"` fact the user has read has to be clearable too, or
   * the dot becomes permanent and stops meaning anything.
   *
   * Confirming an already-`"owner"` fact is deliberately a no-op that still
   * returns the row rather than an error. It is the same end state, and a
   * double-click or a stale list should not read as a failure.
   *
   * `content` and `createdAt` are never touched: this records a judgement
   * about a fact, not an edit to it.
   */
  confirmOwnerFact(id: number): OwnerFact | null {
    this.db.run("UPDATE owner_facts SET origin = 'owner' WHERE id = ?", [id]);
    const row = this.db
      .query("SELECT * FROM owner_facts WHERE id = ?")
      .get(id) as OwnerFact | null;
    return row ?? null;
  }

  /**
   * Every event no consolidation run has processed, regardless of whether a run
   * would be *allowed* to read it. Deliberately left as a plain "how many rows
   * are unprocessed" count — that is what the name says, and the stats/debug
   * surfaces that want a row count want this one.
   *
   * The consolidation gate does NOT use this; see
   * `consolidationCandidateCount` for why the distinction matters.
   */
  unconsolidatedEventCount(): number {
    const row = this.db
      .query("SELECT COUNT(*) as count FROM episodic_events WHERE consolidatedAt IS NULL")
      .get() as { count: number };
    return row.count;
  }

  /**
   * The subset of the above that a consolidation pass may actually read, i.e.
   * excluding `CONSOLIDATION_EXCLUDED_MODES`. This is what `shouldConsolidate`
   * counts.
   *
   * Keeping the gate on this number rather than on the raw count is what stops
   * the excluded rows from wedging it permanently open: dictation is never
   * consolidated, so it never gets a `consolidatedAt`, so under the raw count a
   * single busy afternoon would hold the gate open forever and every launch
   * would spend a real LLM call on a set that turns out to be empty once the
   * mode filter is applied.
   */
  consolidationCandidateCount(): number {
    const row = this.db
      .query(
        `SELECT COUNT(*) as count FROM episodic_events WHERE ${CONSOLIDATION_CANDIDATE_PREDICATE}`
      )
      .get() as { count: number };
    return row.count;
  }

  /**
   * The one query that selects consolidation material. It lives here rather
   * than in `consolidator.ts` so that the gate's count above and the pass's
   * actual read can never drift into disagreeing about what is eligible —
   * which is the failure mode that would silently reintroduce excluded text
   * into a model prompt.
   *
   * Returns raw rows; the consolidator casts them to its own row shape exactly
   * as it did when it owned this query.
   */
  consolidationCandidates(limit: number): unknown[] {
    return this.db
      .query(
        `SELECT * FROM episodic_events
         WHERE ${CONSOLIDATION_CANDIDATE_PREDICATE}
         ORDER BY createdAt DESC LIMIT ?`
      )
      .all(limit);
  }

  /**
   * The most recent `limit` episodic events, returned **oldest-first**. This
   * is the read path for immediate context injection (recent activity folded
   * into an `ask`/`agent` prompt, spec §3.4) -- a different consumer from
   * `consolidationCandidates` with a different shape of trust in the result.
   *
   * Oldest-first is deliberate, not incidental: a model reads "the last line
   * in the block is the most recent one" far more reliably than it infers an
   * implicit reverse-chronological order, so the rows are queried
   * newest-first (to get the right *N*) and then reversed before returning,
   * rather than asking SQLite for `ORDER BY createdAt ASC LIMIT ?` directly
   * -- that would hand back the oldest `limit` rows in the whole table, not
   * the most recent ones.
   *
   * Ties in `createdAt` are broken by `id DESC` (in the newest-first query,
   * so still oldest-first once reversed). `Date.now()` only has millisecond
   * resolution and this project's own event volume makes same-millisecond
   * rows an ordinary occurrence, not a rare edge case -- leaving the tie
   * unresolved would make the returned order depend on SQLite's unspecified
   * tie-breaking rather than on insertion order.
   *
   * This is deliberately **its own query**, not `consolidationCandidates`
   * with an extra flag, and does not reuse `CONSOLIDATION_CANDIDATE_PREDICATE`
   * in any form: `consolidationCandidates` selects material for a real LLM
   * call that produces long-term memory, and must keep excluding dictation
   * (`CONSOLIDATION_EXCLUDED_MODES`) no matter what; `recentEvents` selects
   * material for immediate, per-request context injection, with its own
   * (currently empty) set of boundaries. Sharing one query with a flag would
   * let a future change to either caller's needs silently widen the other's
   * scope -- e.g. a tweak meant only to loosen what consolidation reads
   * quietly loosening what gets injected into the next prompt too. Keeping
   * them separate means each can change its own filtering without touching
   * the other's guarantee, and this method is intentionally unaffected by
   * `consolidatedAt` -- a fully consolidated store still returns every row.
   *
   * `excludeModes` is filtered in the SQL `WHERE` clause, before `LIMIT` is
   * applied, not on the result set afterward: filtering after limiting can
   * silently return fewer rows than exist, or none, when the most recent
   * rows happen to be excluded ones. It is not currently used to keep
   * anything out by default (all three modes feed context with no opt-out,
   * per current product decision) -- it exists as the seam a future
   * per-app or time-window narrowing would be built on, so that narrowing
   * doesn't require a new method or a change to this one's contract.
   */
  recentEvents(limit: number, opts?: { excludeModes?: readonly string[] }): EpisodicEventRow[] {
    const excludeModes = opts?.excludeModes ?? [];
    const exclusionClause =
      excludeModes.length > 0
        ? `WHERE mode NOT IN (${excludeModes.map(() => "?").join(", ")})`
        : "";
    const rows = this.db
      .query(
        `SELECT * FROM episodic_events
         ${exclusionClause}
         ORDER BY createdAt DESC, id DESC
         LIMIT ?`
      )
      .all(...excludeModes, limit) as EpisodicEventRow[];
    return rows.reverse();
  }

  hoursSinceLastConsolidation(): number | null {
    const row = this.db
      .query(
        "SELECT ranAt FROM memory_consolidation_runs ORDER BY ranAt DESC LIMIT 1"
      )
      .get() as { ranAt: number } | null;
    if (!row) {
      return null;
    }
    return (Date.now() - row.ranAt) / (1000 * 60 * 60);
  }

  /**
   * Human-review surface for the Settings "Memory" panel (design §4.1): a
   * consolidation run log. Deliberately excludes snapshotBeforeJSON — that's
   * large internal rollback state, not meant for display.
   */
  listConsolidationRuns(): ConsolidationRunSummary[] {
    const rows = this.db
      .query(
        `SELECT id, ranAt, eventsConsidered, candidatesProposed, candidatesAccepted, summary, rolledBackAt
         FROM memory_consolidation_runs
         ORDER BY ranAt DESC`
      )
      .all() as ConsolidationRunSummary[];
    return rows;
  }
}
