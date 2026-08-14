import type { Database } from "bun:sqlite";

export type EventOrigin = "owner" | "agent" | "untrusted" | "system";
export type EntityCategory = "person" | "project" | "term" | "org";

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

  unconsolidatedEventCount(): number {
    const row = this.db
      .query("SELECT COUNT(*) as count FROM episodic_events WHERE consolidatedAt IS NULL")
      .get() as { count: number };
    return row.count;
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
