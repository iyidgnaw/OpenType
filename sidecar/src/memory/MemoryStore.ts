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
        (createdAt, mode, rawTranscript, correctedTranscript, effectiveInput, selectedContext, result, applicationName, origin)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
